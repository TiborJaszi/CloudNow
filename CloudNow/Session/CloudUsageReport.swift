import Foundation
import os

private nonisolated let usageReportLog = Logger(subsystem: "com.owenselles.CloudNow2", category: "UsageReport")

/// Passes NVIDIA's membership answer (play time left this month, when it resets) on to the
/// server Share Video sends to, at `http://<that host>/gfn/usage`, whenever the app fetches it,
/// so the home server can show it. Best effort: nothing is retried or stored.
nonisolated enum CloudUsageReport {
    /// How often the app asks NVIDIA again while it is open (the time left drops while playing).
    static let refreshInterval: Duration = .seconds(300)

    private static let session = URLSession(configuration: .ephemeral)

    static var endpoint: URL? {
        let address = UserDefaults.standard.string(forKey: CloudVideoShare.addressDefaultsKey) ?? CloudVideoShare.defaultAddress
        guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespaces)) else { return nil }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = "/gfn/usage"
        return components.url
    }

    /// `body`: the MES subscriptions response as NVIDIA sent it.
    static func send(_ body: Data) {
        // Not from tests: their fixtures stay on this machine.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil, let endpoint else { return }
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        session.uploadTask(with: request, from: body) { _, _, error in
            if let error {
                usageReportLog.debug("Usage not delivered: \(error.localizedDescription, privacy: .public)")
            }
        }.resume()
    }
}
