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
/// modifier byte>}` for each key change, `{"pad": {"b", "lt", "rt", "lx", "ly", "rx", "ry"}}` for
/// a virtual controller's state (`VirtualGamepadState`; `{"pad": null}` disconnects it), and
/// `{"ping": 1}` every few seconds, which also lets a turned-off setting or a changed address
/// close the connection during a stream.
@MainActor
final class CloudKeyboardShare {
    static let shared = CloudKeyboardShare()

    static let enabledDefaultsKey = "keyboardShare.enabled"
    static let addressDefaultsKey = "keyboardShare.address"
    static let defaultAddress = "ws://192.168.31.204:8796/keys"

    private static let retryDelay: Duration = .seconds(2)

    private weak var sender: InputSender?
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

    /// The stream's input is ready: deliver shared keys and controller state to `sender` until `detach()`.
    func attach(_ sender: InputSender) {
        detach()
        self.sender = sender
        task = Task { [weak self] in
            await self?.run()
        }
    }

    /// The stream ended or is reconnecting; the server sees the connection close.
    func detach() {
        task?.cancel()
        task = nil
        sender = nil
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
        guard let message = try? JSONDecoder().decode(SharedInput.self, from: Data(text.utf8)) else { return }
        if let pad = message.pad {
            sender?.setVirtualGamepad(pad?.state)
        }
        guard let usage = message.usage,
              let down = message.down,
              let keyCode = UIKeyboardHIDUsage(rawValue: usage)
        else { return }
        sender?.sendKeyEvent(
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

    private nonisolated struct SharedInput: Decodable {
        let usage: Int?
        let down: Bool?
        let modifiers: Int?
        /// Absent: no change; null: the controller page closed; a value: its state.
        let pad: SharedPad??

        enum CodingKeys: String, CodingKey {
            case usage = "k"
            case down = "d"
            case modifiers = "m"
            case pad
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usage = try container.decodeIfPresent(Int.self, forKey: .usage)
            down = try container.decodeIfPresent(Bool.self, forKey: .down)
            modifiers = try container.decodeIfPresent(Int.self, forKey: .modifiers)
            if container.contains(.pad) {
                let state = try container.decodeIfPresent(SharedPad.self, forKey: .pad)
                pad = .some(state)
            } else {
                pad = nil
            }
        }
    }

    nonisolated struct SharedPad: Decodable {
        let buttons: Int
        let leftTrigger: Int
        let rightTrigger: Int
        let leftStickX: Int
        let leftStickY: Int
        let rightStickX: Int
        let rightStickY: Int

        enum CodingKeys: String, CodingKey {
            case buttons = "b"
            case leftTrigger = "lt"
            case rightTrigger = "rt"
            case leftStickX = "lx"
            case leftStickY = "ly"
            case rightStickX = "rx"
            case rightStickY = "ry"
        }

        var state: VirtualGamepadState {
            VirtualGamepadState(
                buttons: UInt16(truncatingIfNeeded: buttons),
                leftTrigger: UInt8(clamping: leftTrigger),
                rightTrigger: UInt8(clamping: rightTrigger),
                leftStickX: Int16(clamping: leftStickX),
                leftStickY: Int16(clamping: leftStickY),
                rightStickX: Int16(clamping: rightStickX),
                rightStickY: Int16(clamping: rightStickY)
            )
        }
    }
}
