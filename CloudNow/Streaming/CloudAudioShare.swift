import AudioToolbox
import Foundation
import os
import Synchronization

private nonisolated let audioShareLog = Logger(subsystem: "com.owenselles.CloudNow2", category: "AudioShare")

/// The sound that goes with Share Video: what the TV plays, exactly as it plays it (48 kHz
/// interleaved 16-bit PCM, every channel of the playout format), passed on to the same server
/// at `/audio` while a page there listens. The encoded Opus never leaves WebRTC, so this is
/// the closest to the original there is: nothing is resampled, mixed down or re-encoded.
///
/// Like `CloudVideoShare`, the app keeps a connection open while the stream plays and sends only
/// while the server says someone listens: `{"watch": <listeners>}`. First comes
/// `{"start": {"sampleRate": 48000, "channels": <n>, "source": "CloudNow"}}` (again whenever the
/// channel count changes), then binary blocks of interleaved little-endian Int16 samples, a few
/// milliseconds each. Audio never waits for anything: if the network falls behind, the oldest
/// sound is dropped, so a listener hears the game at most a moment late, and the delay never builds up.
nonisolated final class CloudAudioShare: @unchecked Sendable {
    static let shared = CloudAudioShare()

    static let sampleRate = 48000
    private static let maxChannels = 8
    /// 100 ms of sound waiting to be sent: more is dropped, oldest first.
    private static let ringFrames = sampleRate / 10
    /// Blocks handed to the socket but not sent yet (about 150 ms): beyond that, blocks are dropped.
    private static let maxInFlight = 15
    private static let sendInterval: DispatchTimeInterval = .milliseconds(10)
    private static let retryInterval: TimeInterval = 2

    private nonisolated struct Ring {
        var samples = [Int16](repeating: 0, count: CloudAudioShare.ringFrames * CloudAudioShare.maxChannels)
        var channels = 2
        /// Frames, not samples.
        var start = 0
        var count = 0
    }

    private let isWatched = Atomic<Bool>(false)
    private let inFlight = Atomic<Int>(0)
    private let ring = OSAllocatedUnfairLock(initialState: Ring())
    private let queue = DispatchQueue(label: "com.owenselles.CloudNow2.audio-share", qos: .userInteractive)
    private let session = URLSession(configuration: .ephemeral)
    /// Only used on `queue`.
    private var timer: DispatchSourceTimer?
    private var socket: URLSessionWebSocketTask?
    private var socketEndpoint: URL?
    private var sentChannels = 0
    private var retryAfter: TimeInterval = 0

    private init() {}

    /// Share Video's address with `/audio` as its last path component; nil while Share Video is off.
    static var endpoint: URL? {
        CloudVideoShare.endpoint?.deletingLastPathComponent().appendingPathComponent("audio")
    }

    /// For the playout render closure of a `channels`-channel interleaved Int16 48 kHz format.
    func makeTap(channels: Int) -> Tap {
        Tap(share: self, channels: min(channels, Self.maxChannels))
    }

    /// Playout started: keep a connection open while Share Video is on (checked on every tick).
    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: Self.sendInterval)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Playout stopped: the stream ended or paused; the server sees the connection close.
    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            closeSocket()
        }
    }

    // MARK: Render thread

    /// Lives in the render closure: copies each rendered buffer into the ring while someone listens.
    nonisolated final class Tap: @unchecked Sendable {
        private let share: CloudAudioShare
        private let channels: Int

        fileprivate init(share: CloudAudioShare, channels: Int) {
            self.share = share
            self.channels = channels
        }

        func write(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
            guard share.isWatched.load(ordering: .relaxed),
                  let data = bufferList.pointee.mBuffers.mData
            else { return }
            let input = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: Int(frameCount) * channels)
            let channels = channels
            share.ring.withLock { ring in
                if ring.channels != channels {
                    ring.channels = channels
                    ring.start = 0
                    ring.count = 0
                }
                let frames = min(input.count / channels, CloudAudioShare.ringFrames)
                let dropped = max(0, ring.count + frames - CloudAudioShare.ringFrames)
                ring.start = (ring.start + dropped) % CloudAudioShare.ringFrames
                ring.count -= dropped
                guard let source = input.baseAddress else { return }
                ring.samples.withUnsafeMutableBufferPointer { samples in
                    guard let target = samples.baseAddress else { return }
                    var end = (ring.start + ring.count) % CloudAudioShare.ringFrames
                    var copied = 0
                    while copied < frames {   // at most twice: up to the ring's end, then from its start
                        let run = min(frames - copied, CloudAudioShare.ringFrames - end)
                        (target + end * channels).update(from: source + copied * channels, count: run * channels)
                        copied += run
                        end = (end + run) % CloudAudioShare.ringFrames
                    }
                }
                ring.count += frames
            }
        }
    }

    // MARK: Sending (on `queue`)

    private func tick() {
        guard let endpoint = Self.endpoint else {
            closeSocket()
            return
        }
        if socketEndpoint != endpoint {
            closeSocket()
        }
        if socket == nil {
            guard Self.now >= retryAfter else { return }
            openSocket(to: endpoint)
        }
        let taken = ring.withLock { ring -> (Data, Int)? in
            guard ring.count > 0 else { return nil }
            let channels = ring.channels
            var data = Data(count: ring.count * channels * 2)
            data.withUnsafeMutableBytes { bytes in
                let output = bytes.bindMemory(to: Int16.self)
                for frame in 0 ..< ring.count {
                    let base = ((ring.start + frame) % CloudAudioShare.ringFrames) * channels
                    for channel in 0 ..< channels {
                        output[frame * channels + channel] = ring.samples[base + channel].littleEndian
                    }
                }
            }
            ring.start = (ring.start + ring.count) % CloudAudioShare.ringFrames
            ring.count = 0
            return (data, channels)
        }
        guard let socket, let taken else { return }
        let (block, channels) = taken
        guard inFlight.load(ordering: .relaxed) < Self.maxInFlight else {
            return   // the network fell behind: this sound is dropped rather than heard late
        }
        if channels != sentChannels {
            sentChannels = channels
            send(.string("{\"start\": {\"sampleRate\": \(Self.sampleRate), \"channels\": \(channels), \"source\": \"CloudNow\"}}"), on: socket)
        }
        send(.data(block), on: socket)
    }

    private func openSocket(to endpoint: URL) {
        let socket = session.webSocketTask(with: endpoint)
        socket.resume()
        self.socket = socket
        socketEndpoint = endpoint
        sentChannels = 0
        receive(on: socket)
        audioShareLog.info("Sharing audio with \(endpoint.absoluteString, privacy: .public)")
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self else { return }
            queue.async {
                guard self.socket === socket else { return }
                switch result {
                case let .success(.string(text)):
                    if let message = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                       let listeners = message["watch"] as? Int {
                        self.setWatched(listeners > 0)
                    }
                    self.receive(on: socket)
                case .success:
                    self.receive(on: socket)
                case let .failure(error):
                    audioShareLog.debug("Audio share closed: \(error.localizedDescription, privacy: .public)")
                    self.closeSocket()
                    self.retryAfter = Self.now + Self.retryInterval
                }
            }
        }
    }

    private func send(_ message: URLSessionWebSocketTask.Message, on socket: URLSessionWebSocketTask) {
        _ = inFlight.wrappingAdd(1, ordering: .relaxed)
        socket.send(message) { [weak self] error in
            guard let self else { return }
            _ = inFlight.wrappingSubtract(1, ordering: .relaxed)
            guard let error else { return }
            queue.async {
                guard self.socket === socket else { return }
                audioShareLog.debug("Audio not delivered: \(error.localizedDescription, privacy: .public)")
                self.closeSocket()
                self.retryAfter = Self.now + Self.retryInterval
            }
        }
    }

    /// A new listener starts from what plays now, not from sound left over from the last one.
    private func setWatched(_ watched: Bool) {
        if watched, !isWatched.load(ordering: .relaxed) {
            ring.withLock { $0.count = 0 }
        }
        isWatched.store(watched, ordering: .relaxed)
    }

    private func closeSocket() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        socketEndpoint = nil
        setWatched(false)
    }

    private static var now: TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
