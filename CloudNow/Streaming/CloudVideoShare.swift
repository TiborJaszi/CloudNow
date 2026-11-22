import Foundation
import os
import Synchronization

private nonisolated let videoShareLog = Logger(subsystem: "com.owenselles.CloudNow2", category: "VideoShare")

/// The "Share Video" setting: the stream exactly as GeForce NOW sends it (H.265, Annex B), passed
/// on over a WebSocket to a server on the local network that relays it to web pages (e.g. a
/// phone controller that shows the game behind its buttons). Nothing is decoded or encoded for
/// it: `CloudVideoDecoderH265` hands over each access unit it decodes.
///
/// While frames arrive the app keeps a connection open (the server knows the Apple TV by its
/// address) and sends frames only while the server says someone watches: `{"watch": <viewers>}`.
/// `{"key": 1}` (a new viewer) makes the decoder ask GeForce NOW for a key frame, which the TV's
/// own picture doesn't notice. Before every key frame comes `{"config": {"codec": "hevc"}}`,
/// then each frame is a binary message: 1 byte (1 = key frame), the frame's time in microseconds
/// (8 bytes, big-endian: GeForce NOW's RTP timestamp, unwrapped, so a page can pace the frames
/// as they were captured rather than as they arrived) and the Annex-B access unit (VPS/SPS/PPS
/// included in key frames). If the network falls behind, frames are dropped until the next key
/// frame.
nonisolated final class CloudVideoShare: @unchecked Sendable {
    static let shared = CloudVideoShare()

    static let enabledDefaultsKey = "videoShare.enabled"
    static let addressDefaultsKey = "videoShare.address"
    static let defaultAddress = "ws://192.168.31.204:8796/video"

    /// Frames handed to the socket but not sent yet (about half a second at 60 fps): enough to
    /// ride out a network hiccup at GeForce NOW's bitrate; more and the network can't keep up.
    private static let maxInFlight = 30
    /// Key frames are the largest: asked for at most this often.
    private static let keyFrameRequestInterval: TimeInterval = 0.5
    private static let idleTimeout: TimeInterval = 3
    private static let retryInterval: TimeInterval = 2
    private static let configMessage = "{\"config\": {\"codec\": \"hevc\"}}"
    /// An RTP timestamp step larger than this (90 kHz ticks: 10 s) is a new stream, not time passing.
    private static let maxRTPStep: UInt32 = 900_000

    private nonisolated struct State {
        var lastFrameTime: TimeInterval = 0
        var isWatched = false
        var wantsKeyFrame = false
        var waitsForKeyFrame = true
        var inFlight = 0
        var lastKeyFrameRequest: TimeInterval = 0
        var lastRTPTimestamp: UInt32?
        /// 90 kHz ticks since the first frame, across the 32-bit wrap.
        var rtpTicks: UInt64 = 0
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

    private init() {}

    static var endpoint: URL? {
        let defaults = UserDefaults.standard
        // On unless turned off in Settings.
        guard defaults.object(forKey: enabledDefaultsKey) as? Bool ?? true else { return nil }
        let address = defaults.string(forKey: addressDefaultsKey) ?? defaultAddress
        return URL(string: address.trimmingCharacters(in: .whitespaces))
    }

    /// Called by the decoder for every access unit it decoded (`rtpTimestamp`: its 90 kHz RTP
    /// time): only bookkeeping unless someone watches. Returns whether the decoder should ask
    /// GeForce NOW for a key frame.
    func offer(_ accessUnit: Data, isKeyFrame: Bool, rtpTimestamp: UInt32) -> Bool {
        let now = Self.now
        let (isDue, wantsKeyFrame, ticks) = state.withLock { state -> (Bool, Bool, UInt64) in
            state.lastFrameTime = now
            if let last = state.lastRTPTimestamp {
                let step = rtpTimestamp &- last
                if step <= Self.maxRTPStep {
                    state.rtpTicks &+= UInt64(step)
                }
            }
            state.lastRTPTimestamp = rtpTimestamp
            let ticks = state.rtpTicks
            guard state.isWatched else { return (false, false, ticks) }
            if isKeyFrame {   // what was asked for (or came anyway)
                state.waitsForKeyFrame = false
                state.wantsKeyFrame = false
            }
            let wantsKeyFrame = state.wantsKeyFrame
            state.wantsKeyFrame = false
            if state.waitsForKeyFrame {
                return (false, wantsKeyFrame, ticks)
            }
            guard state.inFlight < Self.maxInFlight else {
                // The network fell behind: skip to the next key frame, and ask for one.
                state.waitsForKeyFrame = true
                state.wantsKeyFrame = true
                return (false, false, ticks)
            }
            state.inFlight += 1
            return (true, wantsKeyFrame, ticks)
        }
        let requestsKeyFrame = wantsKeyFrame && state.withLock { state -> Bool in
            guard now - state.lastKeyFrameRequest >= Self.keyFrameRequestInterval else {
                state.wantsKeyFrame = true   // asked again on a later frame
                return false
            }
            state.lastKeyFrameRequest = now
            return true
        }
        if timerStarted.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged {
            queue.async { [self] in startTimer() }
        }
        if isDue {
            // The decoder's buffer belongs to WebRTC once decode returns: one copy, while watched.
            var message = Data(capacity: accessUnit.count + 9)
            message.append(isKeyFrame ? 1 : 0)
            withUnsafeBytes(of: (ticks * 100 / 9).bigEndian) { message.append(contentsOf: $0) }   // µs
            message.append(accessUnit)
            queue.async { [self] in deliver(message, isKeyFrame: isKeyFrame) }
        }
        return requestsKeyFrame
    }

    // MARK: Connection (on `queue`)

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// Keeps a connection open while frames are decoded and the setting is on.
    private func tick() {
        let isStreaming = Self.now - state.withLock { $0.lastFrameTime } < Self.idleTimeout
        guard isStreaming, let endpoint = Self.endpoint else {
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
                    self.closeSocket()
                    self.retryAfter = Self.now + Self.retryInterval
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let message = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        if let viewers = message["watch"] as? Int {
            state.withLock { state in
                if viewers > 0, !state.isWatched {
                    state.waitsForKeyFrame = true
                    state.wantsKeyFrame = true
                }
                state.isWatched = viewers > 0
            }
        }
        if message["key"] != nil {
            state.withLock { state in
                state.waitsForKeyFrame = true
                state.wantsKeyFrame = true
            }
        }
    }

    private func deliver(_ message: Data, isKeyFrame: Bool) {
        guard let socket else {
            frameSent()
            return
        }
        if isKeyFrame {
            send(.string(Self.configMessage), on: socket)
        }
        send(.data(message), on: socket, isFrame: true)
    }

    private func send(_ message: URLSessionWebSocketTask.Message, on socket: URLSessionWebSocketTask, isFrame: Bool = false) {
        socket.send(message) { [weak self] error in
            guard let self else { return }
            if isFrame {
                frameSent()
            }
            guard let error else { return }
            queue.async {
                guard self.socket === socket else { return }
                videoShareLog.debug("Video not delivered: \(error.localizedDescription, privacy: .public)")
                self.closeSocket()
                self.retryAfter = Self.now + Self.retryInterval
            }
        }
    }

    private func closeSocket() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        socketEndpoint = nil
        state.withLock { $0.isWatched = false }
    }

    private func frameSent() {
        state.withLock { $0.inFlight = max(0, $0.inFlight - 1) }
    }

    private static var now: TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
