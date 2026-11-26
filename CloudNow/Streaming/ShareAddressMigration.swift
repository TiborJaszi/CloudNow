import Foundation

/// The home server the Share settings talk to moved from Home Assistant (192.168.31.204) to the
/// Docker host (192.168.31.95) on 2026-11-26. Saved addresses that still name the old server are
/// rewritten once at launch; any other address is left as the user typed it.
@MainActor
enum ShareAddressMigration {
    static let oldHost = "192.168.31.204:8796"
    static let newHost = "192.168.31.95:8796"

    static func run(defaults: UserDefaults = .standard) {
        let keys = [
            CloudScreenShare.addressDefaultsKey,
            CloudSoundShare.addressDefaultsKey,
            CloudKeyboardShare.addressDefaultsKey,
            CloudVideoShare.addressDefaultsKey,
        ]
        for key in keys {
            guard let address = defaults.string(forKey: key), address.contains(oldHost) else { continue }
            defaults.set(address.replacingOccurrences(of: oldHost, with: newHost), forKey: key)
        }
    }
}
