@testable import CloudNow
import Foundation
import Testing

struct CloudVideoShareTests {
    private func sized(_ width: Int, _ height: Int) -> [Int] {
        let size = CloudVideoShare.outputSize(width: width, height: height)
        return [size.width, size.height]
    }

    @Test("The shared video fits 1920x1080 with the stream's aspect ratio and even sides")
    func outputSize() {
        #expect(sized(2560, 1440) == [1920, 1080])
        #expect(sized(3840, 2160) == [1920, 1080])
        #expect(sized(1280, 720) == [1280, 720])
        #expect(sized(3440, 1440) == [1920, 804])
    }

    @Test("The config names the codec from the SPS and carries an avcC record")
    func configMessage() throws {
        let sps = Data([0x67, 0x64, 0x00, 0x28, 0xAC])
        let pps = Data([0x68, 0xEE, 0x3C])
        let text = try #require(CloudVideoShare.configMessage(sps: sps, pps: pps, width: 1920, height: 1080))
        let message = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let config = try #require(message["config"] as? [String: Any])
        #expect(config["codec"] as? String == "avc1.640028")
        #expect(config["width"] as? Int == 1920)
        let description = try #require(Data(base64Encoded: config["description"] as? String ?? ""))
        #expect([UInt8](description) == [1, 0x64, 0x00, 0x28, 0xFF, 0xE1, 0, 5, 0x67, 0x64, 0x00, 0x28, 0xAC, 1, 0, 3, 0x68, 0xEE, 0x3C])
    }
}
