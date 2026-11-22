import Foundation
import os
import UIKit

private nonisolated let keyboardShareLog = Logger(subsystem: "com.owenselles.CloudNow2", category: "KeyboardShare")

/// The "Share Keyboard" setting: while a GeForce NOW stream accepts input, a server on the local
/// network sends key presses over a WebSocket and they go into the stream as if a keyboard were
/// connected. The app opens the connection, so nothing listens on the Apple TV.
///
/// The app first sends `{"hello": {"name": "<device name>", "id": "<vendor id>"}}`, so a server
/// that serves several Apple TVs knows which one is playing: the connection is open only while a
/// stream accepts input. The server then sends `{"k": <HID usage>, "d": <down>, "m": <HID
/// modifier byte>}` for each key change, and `{"ping": 1}` every few seconds, which also lets a
/// turned-off setting or a changed address close the connection during a stream.
@MainActor
final class CloudKeyboardShare {
    static let shared = CloudKeyboardShare()

    static let enabledDefaultsKey = "keyboardShare.enabled"
    static let addressDefaultsKey = "keyboardShare.address"
    static let defaultAddress = "ws://192.168.31.204:8796/keys"

    private static let retryDelay: Duration = .seconds(2)

    private weak var handler: (any InputEventHandler)?
    private var task: Task<Void, Never>?
    private let session = URLSession(configuration: .ephemeral)

    private init() {}

    static var endpoint: URL? {
        let defaults = UserDefaults.standard
        // On unless turned off in Settings.
        guard defaults.object(forKey: enabledDefaultsKey) as? Bool ?? true else { return nil }
        let address = defaults.string(forKey: addressDefaultsKey) ?? defaultAddress
        return URL(string: address.trimmingCharacters(in: .whitespaces))
    }

    /// The stream's input is ready: deliver shared keys to `handler` until `detach()`.
    func attach(_ handler: any InputEventHandler) {
        detach()
        self.handler = handler
        task = Task { [weak self] in
            await self?.run()
        }
    }

    /// The stream ended or is reconnecting; the server sees the connection close.
    func detach() {
        task?.cancel()
        task = nil
        handler = nil
    }

    private func run() async {
        while !Task.isCancelled {
            if let endpoint = Self.endpoint {
                await serve(endpoint)
            }
            try? await Task.sleep(for: Self.retryDelay)
        }
    }

    private func serve(_ endpoint: URL) async {
        let socket = session.webSocketTask(with: endpoint)
        socket.resume()
        await withTaskCancellationHandler {
            do {
                try await socket.send(.string(Self.hello()))
                keyboardShareLog.info("Sharing the keyboard with \(endpoint.absoluteString, privacy: .public)")
                while !Task.isCancelled, Self.endpoint == endpoint {
                    if case let .string(text) = try await socket.receive() {
                        deliver(text)
                    }
                }
            } catch {
                keyboardShareLog.debug("Keyboard share closed: \(error.localizedDescription, privacy: .public)")
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
        socket.cancel(with: .normalClosure, reason: nil)
    }

    private func deliver(_ text: String) {
        guard let message = try? JSONDecoder().decode(SharedKey.self, from: Data(text.utf8)),
              let usage = message.usage,
              let down = message.down,
              let keyCode = UIKeyboardHIDUsage(rawValue: usage)
        else { return }
        handler?.sendKeyEvent(
            down: down,
            keyCode: keyCode,
            modifiers: Self.modifierFlags(fromHID: message.modifiers ?? 0)
        )
    }

    private static func hello() -> String {
        let hello = ["hello": [
            "name": UIDevice.current.name,
            "id": UIDevice.current.identifierForVendor?.uuidString ?? "",
        ]]
        let data = (try? JSONSerialization.data(withJSONObject: hello)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// A HID keyboard report's modifier byte: left then right Ctrl, Shift, Alt, GUI.
    nonisolated static func modifierFlags(fromHID byte: Int) -> UIKeyModifierFlags {
        var flags: UIKeyModifierFlags = []
        if byte & 0x11 != 0 {
            flags.insert(.control)
        }
        if byte & 0x22 != 0 {
            flags.insert(.shift)
        }
        if byte & 0x44 != 0 {
            flags.insert(.alternate)
        }
        if byte & 0x88 != 0 {
            flags.insert(.command)
        }
        return flags
    }

    private nonisolated struct SharedKey: Decodable {
        let usage: Int?
        let down: Bool?
        let modifiers: Int?

        enum CodingKeys: String, CodingKey {
            case usage = "k"
            case down = "d"
            case modifiers = "m"
        }
    }
}
