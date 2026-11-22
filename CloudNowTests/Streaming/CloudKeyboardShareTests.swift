@testable import CloudNow
import Testing
import UIKit

struct CloudKeyboardShareTests {
    @Test("A HID modifier byte maps left and right modifiers to the same flags")
    func modifierFlags() {
        #expect(CloudKeyboardShare.modifierFlags(fromHID: 0).isEmpty)
        #expect(CloudKeyboardShare.modifierFlags(fromHID: 0x03) == [.control, .shift])
        #expect(CloudKeyboardShare.modifierFlags(fromHID: 0x30) == [.control, .shift])
        #expect(CloudKeyboardShare.modifierFlags(fromHID: 0x44) == [.alternate])
        #expect(CloudKeyboardShare.modifierFlags(fromHID: 0x88) == [.command])
    }
}
