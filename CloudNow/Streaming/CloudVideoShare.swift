import CoreMedia
@preconcurrency import CoreVideo
import Foundation
import os
import Synchronization
@preconcurrency import VideoToolbox

private nonisolated let videoShareLog = Logger(subsystem: "com.owenselles.CloudNow2", category: "VideoShare")

/// The "Share Video" setting: the stream, re-encoded as low-latency H.264 by the hardware
/// encoder, sent over a WebSocket to a server on the local network that passes it on to web
/// pages (e.g. a phone controller that shows the game behind its buttons).
///
/// While frames are rendered the app keeps a connection open (the server knows the Apple TV by
/// its address). It encodes only while the server says someone watches:
/// `{"watch": <viewers>}`; `{"key": 1}` asks for a key frame (a new viewer). Before every key
/// frame comes `{"config": {"codec": "avc1.PPCCLL", "description": "<base64 avcC>", "width",
/// "height"}}` (what a WebCodecs `VideoDecoder` needs), then each frame is a binary message:
/// 1 byte (1 = key frame), the presentation time in microseconds (8 bytes, big-endian), and the
/// frame in AVCC form (4-byte lengths). If the network falls behind, frames are dropped until
/// the next key frame, so the stream itself never waits.
nonisolated final class CloudVideoShare: @unchecked Sendable {
    static let shared = CloudVideoShare()

    static let enabledDefaultsKey = "videoShare.enabled"
    static let addressDefaultsKey = "videoShare.address"
    static let defaultAddress = "ws://192.168.31.204:8796/video"

    private static let maxWidth = 1920
    private static let maxHeight = 1080
    private static let bitRate = 10_000_000
    private static let minFrameInterval: TimeInterval = 1.0 / 62
    private static let keyFrameSeconds = 2
    /// Frames being encoded or sent; more than this and the network can't keep up.
    private static let maxInFlight = 8
    private static let idleTimeout: TimeInterval = 3
    private static let retryInterval: TimeInterval = 2

    private nonisolated struct State {
        var lastFrameTime: TimeInterval = 0
        var lastEncodeTime: TimeInterval = 0
        var isWatched = false
        var needsKeyFrame = true
        var inFlight = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let timerStarted = Atomic<Bool>(false)
    private let queue = DispatchQueue(label: "com.owenselles.CloudNow2.video-share", qos: .userInitiated)
    private let session = URLSession(configuration: .ephemeral)
    /// Only used on `queue`.
    private var timer: DispatchSourceTimer?
    private var socket: URLSessionWebSocketTask?
    private var socketEndpoint: URL?
    private var retryAfter: TimeInterval = 0
    private var compressionSession: VTCompressionSession?
    private var compressionSize = (width: 0, height: 0)
    private var transferSession: VTPixelTransferSession?

    private init() {}

    static var endpoint: URL? {
        let defaults = UserDefaults.standard
        // On unless turned off in Settings.
        guard defaults.object(forKey: enabledDefaultsKey) as? Bool ?? true else { return nil }
        let address = defaults.string(forKey: addressDefaultsKey) ?? defaultAddress
        return URL(string: address.trimmingCharacters(in: .whitespaces))
    }

    /// Called for every decoded frame, on the render queue: cheap unless someone watches.
    func offer(_ pixelBuffer: CVPixelBuffer) {
        let now = Self.now
        let isDue = state.withLock { state -> Bool in
            state.lastFrameTime = now
            guard state.isWatched, now - state.lastEncodeTime >= Self.minFrameInterval else { return false }
            guard state.inFlight < Self.maxInFlight else {
                state.needsKeyFrame = true
                return false
            }
            state.lastEncodeTime = now
            state.inFlight += 1
            return true
        }
        if timerStarted.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged {
            queue.async { [self] in startTimer() }
        }
        guard isDue else { return }
        queue.async { [self] in
            if !encode(pixelBuffer, at: now) {
                frameDone()
            }
        }
    }

    // MARK: Connection (on `queue`)

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// Keeps a connection open while frames are rendered and the setting is on.
    private func tick() {
        let isRendering = Self.now - state.withLock { $0.lastFrameTime } < Self.idleTimeout
        guard isRendering, let endpoint = Self.endpoint else {
            if socket != nil {
                closeSocket()
            }
            return
        }
        if socketEndpoint != endpoint {
            closeSocket()
        }
        if socket == nil, Self.now >= retryAfter {
            openSocket(to: endpoint)
        }
    }

    private func openSocket(to endpoint: URL) {
        let socket = session.webSocketTask(with: endpoint)
        socket.maximumMessageSize = 1 << 20
        socket.resume()
        self.socket = socket
        socketEndpoint = endpoint
        receive(on: socket)
        videoShareLog.info("Sharing video with \(endpoint.absoluteString, privacy: .public)")
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self else { return }
            queue.async {
                guard self.socket === socket else { return }
                switch result {
                case let .success(.string(text)):
                    self.handle(text)
                    self.receive(on: socket)
                case .success:
                    self.receive(on: socket)
                case let .failure(error):
                    videoShareLog.debug("Video share closed: \(error.localizedDescription, privacy: .public)")
                    self.dropSocket()
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let message = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        if let viewers = message["watch"] as? Int {
            let isWatched = viewers > 0
            state.withLock { state in
                if isWatched, !state.isWatched {
                    state.needsKeyFrame = true
                }
                state.isWatched = isWatched
            }
            if !isWatched {
                endCompression()
            }
        }
        if message["key"] != nil {
            state.withLock { $0.needsKeyFrame = true }
        }
    }

    private func send(_ message: URLSessionWebSocketTask.Message, on socket: URLSessionWebSocketTask, isFrame: Bool = false) {
        socket.send(message) { [weak self] error in
            guard let self else { return }
            if isFrame {
                frameDone()
            }
            guard let error else { return }
            queue.async {
                guard self.socket === socket else { return }
                videoShareLog.debug("Video not delivered: \(error.localizedDescription, privacy: .public)")
                self.dropSocket()
            }
        }
    }

    /// The connection failed: try again in a moment.
    private func dropSocket() {
        closeSocket()
        retryAfter = Self.now + Self.retryInterval
    }

    private func closeSocket() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        socketEndpoint = nil
        state.withLock { $0.isWatched = false }
        endCompression()
    }

    private func frameDone() {
        state.withLock { $0.inFlight = max(0, $0.inFlight - 1) }
    }

    // MARK: Encoding (on `queue`)

    private func encode(_ source: CVPixelBuffer, at time: TimeInterval) -> Bool {
        guard socket != nil else { return false }
        let size = Self.outputSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
        guard let compressionSession = encoder(for: size),
              let pool = VTCompressionSessionGetPixelBufferPool(compressionSession),
              let transferSession = transferSession ?? makeTransferSession()
        else { return false }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output,
              VTPixelTransferSessionTransferImage(transferSession, from: source, to: output) == noErr
        else { return false }

        let forceKeyFrame = state.withLock { state -> Bool in
            defer { state.needsKeyFrame = false }
            return state.needsKeyFrame
        }
        let properties: CFDictionary? = forceKeyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
        let presentationTime = CMTime(value: CMTimeValue(time * 1_000_000), timescale: 1_000_000)
        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: output,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] encodeStatus, _, sampleBuffer in
            guard let self else { return }
            guard encodeStatus == noErr, let sampleBuffer, let frame = Self.frame(from: sampleBuffer) else {
                frameDone()
                return
            }
            queue.async { self.deliver(frame) }
        }
        if status != noErr {
            videoShareLog.debug("Encoding failed: \(status)")
            state.withLock { $0.needsKeyFrame = true }
            return false
        }
        return true
    }

    private func deliver(_ frame: EncodedFrame) {
        guard let socket else {
            frameDone()
            return
        }
        if let config = frame.config {
            send(.string(config), on: socket)
        }
        send(.data(frame.data), on: socket, isFrame: true)
    }

    private func encoder(for size: (width: Int, height: Int)) -> VTCompressionSession? {
        if let compressionSession, compressionSize == size {
            return compressionSession
        }
        endCompression()
        var created: VTCompressionSession?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(size.width),
            height: Int32(size.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            videoShareLog.error("No H.264 encoder: \(status)")
            return nil
        }
        let properties: [CFString: CFTypeRef] = [
            kVTCompressionPropertyKey_RealTime: NSNumber(value: true),
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: NSNumber(value: false),
            kVTCompressionPropertyKey_AverageBitRate: NSNumber(value: Self.bitRate),
            kVTCompressionPropertyKey_DataRateLimits: [NSNumber(value: Self.bitRate / 4), NSNumber(value: 0.5)] as CFArray,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: NSNumber(value: Self.keyFrameSeconds),
            kVTCompressionPropertyKey_ExpectedFrameRate: NSNumber(value: 60),
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        for (key, value) in properties {
            VTSessionSetProperty(created, key: key, value: value)
        }
        VTCompressionSessionPrepareToEncodeFrames(created)
        compressionSession = created
        compressionSize = size
        state.withLock { $0.needsKeyFrame = true }
        videoShareLog.info("Encoding \(size.width)x\(size.height) H.264")
        return created
    }

    private func endCompression() {
        guard let compressionSession else { return }
        VTCompressionSessionInvalidate(compressionSession)
        self.compressionSession = nil
        compressionSize = (0, 0)
    }

    /// The decoder's own format (10-bit for H.265 Main10) as 8-bit BT.709, scaled for the encoder.
    private func makeTransferSession() -> VTPixelTransferSession? {
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == noErr,
              let session
        else { return nil }
        VTSessionSetProperty(
            session,
            key: kVTPixelTransferPropertyKey_DestinationColorPrimaries,
            value: kCVImageBufferColorPrimaries_ITU_R_709_2
        )
        VTSessionSetProperty(
            session,
            key: kVTPixelTransferPropertyKey_DestinationTransferFunction,
            value: kCVImageBufferTransferFunction_ITU_R_709_2
        )
        VTSessionSetProperty(
            session,
            key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
            value: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        )
        transferSession = session
        return session
    }

    // MARK: Wire format

    private nonisolated struct EncodedFrame: @unchecked Sendable {
        let config: String?
        let data: Data
    }

    /// The stream's size within `maxWidth` x `maxHeight`, even (as H.264 needs), aspect kept.
    static func outputSize(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (maxWidth, maxHeight) }
        let scale = min(1, Double(maxWidth) / Double(width), Double(maxHeight) / Double(height))
        let even = { (value: Double) in max(2, Int(value.rounded()) & ~1) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    private static func frame(from sampleBuffer: CMSampleBuffer) -> EncodedFrame? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var payload = Data(count: length)
        let copied = payload.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        let isKeyFrame = Self.isKeyFrame(sampleBuffer)
        var config: String?
        if isKeyFrame {
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let parameterSets = parameterSets(of: format)
            else { return nil }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            config = configMessage(
                sps: parameterSets.sps,
                pps: parameterSets.pps,
                width: Int(dimensions.width),
                height: Int(dimensions.height)
            )
        }

        let micros = UInt64(max(0, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds * 1_000_000))
        var data = Data([isKeyFrame ? 1 : 0])
        withUnsafeBytes(of: micros.bigEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return EncodedFrame(config: config, data: data)
    }

    private static func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[String: Any]],
            let first = attachments.first
        else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false)
    }

    private static func parameterSets(of format: CMFormatDescription) -> (sps: Data, pps: Data)? {
        func parameterSet(at index: Int) -> Data? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
        guard let sps = parameterSet(at: 0), let pps = parameterSet(at: 1), sps.count >= 4 else { return nil }
        return (sps, pps)
    }

    /// `{"config": …}` for a WebCodecs decoder: the RFC 6381 codec name and an avcC record.
    static func configMessage(sps: Data, pps: Data, width: Int, height: Int) -> String? {
        let spsBytes = [UInt8](sps), ppsBytes = [UInt8](pps)
        guard spsBytes.count >= 4 else { return nil }
        var avcC: [UInt8] = [1, spsBytes[1], spsBytes[2], spsBytes[3], 0xFF, 0xE1]
        avcC += [UInt8(spsBytes.count >> 8), UInt8(spsBytes.count & 0xFF)] + spsBytes
        avcC += [1, UInt8(ppsBytes.count >> 8), UInt8(ppsBytes.count & 0xFF)] + ppsBytes
        let codec = "avc1." + spsBytes[1 ... 3].map { String(format: "%02x", $0) }.joined()
        let message: [String: Any] = ["config": [
            "codec": codec,
            "description": Data(avcC).base64EncodedString(),
            "width": width,
            "height": height,
        ]]
        guard let json = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        return String(decoding: json, as: UTF8.self)
    }

    private static var now: TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
