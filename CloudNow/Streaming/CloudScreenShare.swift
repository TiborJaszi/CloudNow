@preconcurrency import CoreImage
@preconcurrency import CoreVideo
import Foundation
import os

private nonisolated let screenShareLog = Logger(subsystem: "com.owenselles.CloudNow2", category: "ScreenShare")

/// The "Share Screen" setting: a few frames a second of the stream, as JPEGs POSTed to a
/// server on the local network (e.g. a page that shows the game on a phone or reads its chat).
/// Each frame is offered by the video renderer; one is encoded and sent at a time, frames that
/// arrive meanwhile are skipped, so the stream itself never waits for the network. The server's
/// reply may ask for another pace: `{"every": seconds}`.
nonisolated final class CloudScreenShare: @unchecked Sendable {
    static let shared = CloudScreenShare()

    static let enabledDefaultsKey = "screenShare.enabled"
    static let addressDefaultsKey = "screenShare.address"
    static let defaultAddress = "http://192.168.31.204:8796/screen/frame"

    private static let defaultInterval: TimeInterval = 1.0 / 3
    private static let failureInterval: TimeInterval = 5
    private static let intervalRange: ClosedRange<TimeInterval> = 0.1 ... 30
    private static let maxWidth: CGFloat = 1920
    private static let jpegQuality: CGFloat = 0.75

    private struct State {
        var isSending = false
        var lastOfferTime: TimeInterval = 0
        var interval = CloudScreenShare.defaultInterval
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "com.owenselles.CloudNow2.screen-share", qos: .utility)
    private let context = CIContext()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }()

    private init() {}

    static var endpoint: URL? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: enabledDefaultsKey) else { return nil }
        let address = defaults.string(forKey: addressDefaultsKey) ?? defaultAddress
        return URL(string: address.trimmingCharacters(in: .whitespaces))
    }

    /// Called for every decoded frame, on the render queue: cheap unless a frame is due.
    func offer(_ pixelBuffer: CVPixelBuffer) {
        let now = Self.now
        let isDue = state.withLock { state in
            guard !state.isSending, now - state.lastOfferTime >= state.interval else { return false }
            state.lastOfferTime = now
            return true
        }
        guard isDue, let endpoint = Self.endpoint else { return }
        state.withLock { $0.isSending = true }
        queue.async { [self] in
            guard let jpeg = encode(pixelBuffer) else {
                finish(interval: Self.failureInterval)
                return
            }
            send(jpeg, to: endpoint)
        }
    }

    private func encode(_ pixelBuffer: CVPixelBuffer) -> Data? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let width = image.extent.width
        if width > Self.maxWidth {
            let scale = Self.maxWidth / width
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let quality = kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption
        return context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [quality: Self.jpegQuality])
    }

    private func send(_ jpeg: Data, to endpoint: URL) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        session.uploadTask(with: request, from: jpeg) { [self] data, response, error in
            guard error == nil, let status = (response as? HTTPURLResponse)?.statusCode, status < 300 else {
                screenShareLog.debug("Frame not delivered: \(error?.localizedDescription ?? "HTTP error", privacy: .public)")
                finish(interval: Self.failureInterval)
                return
            }
            finish(interval: Self.requestedInterval(in: data) ?? Self.defaultInterval)
        }.resume()
    }

    private func finish(interval: TimeInterval) {
        state.withLock { state in
            state.isSending = false
            state.interval = interval
        }
    }

    private static func requestedInterval(in data: Data?) -> TimeInterval? {
        guard let data,
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let every = reply["every"] as? Double
        else { return nil }
        return min(max(every, intervalRange.lowerBound), intervalRange.upperBound)
    }

    private static var now: TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
