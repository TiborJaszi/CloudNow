import AudioToolbox
import Foundation
import os
import Synchronization

private nonisolated let soundShareLog = Logger(subsystem: "com.owenselles.CloudNow2", category: "SoundShare")

/// The "Share Sound" setting: the stream's sound, as it is played, sent over a WebSocket to a
/// server on the local network (e.g. one that listens to the game). Mono 16-bit PCM at 24 kHz:
/// first a text message `{"start": {"sampleRate": 24000, "source": "CloudNow"}}`, then binary
/// blocks, one connection per stream.
///
/// The playout render closure (`CloudAudioDevice`) hands each rendered buffer to a `Tap`, which
/// downmixes and halves the rate into a ring buffer without allocating; a timer on a utility
/// queue drains the ring to the socket. If the socket can't keep up, the oldest sound is dropped.
nonisolated final class CloudSoundShare: @unchecked Sendable {
    static let shared = CloudSoundShare()

    static let enabledDefaultsKey = "soundShare.enabled"
    static let addressDefaultsKey = "soundShare.address"
    static let defaultAddress = "ws://192.168.31.95:8796/sound"

    static let sampleRate = 24000
    private static let ringCapacity = sampleRate                 // 1 s
    private static let sendInterval: DispatchTimeInterval = .milliseconds(40)
    private static let retryInterval: TimeInterval = 2

    private nonisolated struct Ring {
        var samples = [Int16](repeating: 0, count: CloudSoundShare.ringCapacity)
        var start = 0
        var count = 0
    }

    private let isSharing = Atomic<Bool>(false)
    private let ring = OSAllocatedUnfairLock(initialState: Ring())
    private let queue = DispatchQueue(label: "com.owenselles.CloudNow2.sound-share", qos: .utility)
    private let session = URLSession(configuration: .ephemeral)
    /// Only used on `queue`.
    private var timer: DispatchSourceTimer?
    private var socket: URLSessionWebSocketTask?
    private var socketEndpoint: URL?
    private var retryAfter: TimeInterval = 0

    private init() {}

    static var endpoint: URL? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: enabledDefaultsKey) else { return nil }
        let address = defaults.string(forKey: addressDefaultsKey) ?? defaultAddress
        return URL(string: address.trimmingCharacters(in: .whitespaces))
    }

    /// For the playout render closure of a `channels`-channel interleaved Int16 48 kHz format.
    func makeTap(channels: Int) -> Tap {
        Tap(share: self, channels: channels)
    }

    /// Playout started: send while the setting is on (checked on every send tick).
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
            isSharing.store(false, ordering: .relaxed)
            closeSocket()
            ring.withLock { $0.count = 0 }
        }
    }

    // MARK: Render thread

    /// Lives in the render closure; `pending` carries an odd sample to the next buffer.
    nonisolated final class Tap: @unchecked Sendable {
        private let share: CloudSoundShare
        private let channels: Int
        private var pending: Int32?

        fileprivate init(share: CloudSoundShare, channels: Int) {
            self.share = share
            self.channels = channels
        }

        func write(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
            guard share.isSharing.load(ordering: .relaxed),
                  let data = bufferList.pointee.mBuffers.mData
            else { return }
            let frames = Int(frameCount)
            let input = data.assumingMemoryBound(to: Int16.self)
            let right = min(1, channels - 1)
            share.ring.withLock { ring in
                for frame in 0 ..< frames {
                    let base = frame * channels
                    let mono = (Int32(input[base]) + Int32(input[base + right])) / 2
                    guard let first = pending else {
                        pending = mono
                        continue
                    }
                    pending = nil
                    let index = (ring.start + ring.count) % CloudSoundShare.ringCapacity
                    ring.samples[index] = Int16((first + mono) / 2)
                    if ring.count == CloudSoundShare.ringCapacity {
                        ring.start = (ring.start + 1) % CloudSoundShare.ringCapacity
                    } else {
                        ring.count += 1
                    }
                }
            }
        }
    }

    // MARK: Sending (on `queue`)

    private func tick() {
        guard let endpoint = Self.endpoint else {
            isSharing.store(false, ordering: .relaxed)
            closeSocket()
            return
        }
        isSharing.store(true, ordering: .relaxed)
        if socketEndpoint != endpoint {
            closeSocket()
        }
        if socket == nil {
            guard Self.now >= retryAfter else { return }
            openSocket(to: endpoint)
        }
        let block = ring.withLock { ring -> Data? in
            guard ring.count > 0 else { return nil }
            var data = Data(count: ring.count * 2)
            data.withUnsafeMutableBytes { bytes in
                let output = bytes.bindMemory(to: Int16.self)
                for offset in 0 ..< ring.count {
                    output[offset] = ring.samples[(ring.start + offset) % CloudSoundShare.ringCapacity].littleEndian
                }
            }
            ring.start = (ring.start + ring.count) % CloudSoundShare.ringCapacity
            ring.count = 0
            return data
        }
        if let block {
            send(.data(block))
        }
    }

    private func openSocket(to endpoint: URL) {
        let socket = session.webSocketTask(with: endpoint)
        socket.resume()
        self.socket = socket
        socketEndpoint = endpoint
        send(.string("{\"start\": {\"sampleRate\": \(Self.sampleRate), \"source\": \"CloudNow\"}}"))
        soundShareLog.info("Sharing sound with \(endpoint.absoluteString, privacy: .public)")
    }

    private func send(_ message: URLSessionWebSocketTask.Message) {
        guard let socket else { return }
        socket.send(message) { [weak self] error in
            guard let self, let error else { return }
            queue.async {
                guard self.socket === socket else { return }
                soundShareLog.debug("Sound not delivered: \(error.localizedDescription, privacy: .public)")
                self.closeSocket()
                self.retryAfter = Self.now + Self.retryInterval
            }
        }
    }

    private func closeSocket() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        socketEndpoint = nil
    }

    private static var now: TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
