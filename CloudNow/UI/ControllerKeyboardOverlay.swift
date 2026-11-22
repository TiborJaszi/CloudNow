import GameController
import SwiftUI

/// A key on the controller keyboard overlay. `width` counts grid columns.
struct ControllerKeyboardKey: Equatable {
    enum Action: Equatable {
        case character(String)
        case key(UIKeyboardHIDUsage)
        case shift
    }

    let label: String
    let action: Action
    var width = 1

    static func chars(_ values: String) -> [ControllerKeyboardKey] {
        values.map { ControllerKeyboardKey(label: String($0), action: .character(String($0))) }
    }
}

/// The overlay's state: selection, Shift, what was typed since the last Enter, position, and
/// whether the control hints show. Presses go to the game as they happen; nothing is buffered.
@MainActor @Observable
final class ControllerKeyboardModel {
    static let rows: [[ControllerKeyboardKey]] = [
        ControllerKeyboardKey.chars("1234567890")
            + [ControllerKeyboardKey(label: "⌫", action: .key(.keyboardDeleteOrBackspace))],
        ControllerKeyboardKey.chars("qwertyuiop")
            + [ControllerKeyboardKey(label: "esc", action: .key(.keyboardEscape))],
        ControllerKeyboardKey.chars("asdfghjkl'")
            + [ControllerKeyboardKey(label: "⏎", action: .key(.keyboardReturnOrEnter))],
        [ControllerKeyboardKey(label: "⇧", action: .shift)]
            + ControllerKeyboardKey.chars("zxcvbnm,.?"),
        [ControllerKeyboardKey(label: "tab", action: .key(.keyboardTab))]
            + ControllerKeyboardKey.chars("!@-")
            + [ControllerKeyboardKey(label: "space", action: .character(" "), width: 4)]
            + ControllerKeyboardKey.chars("/:_"),
    ]

    private(set) var row = 1
    private(set) var column = 0
    private(set) var shift = false
    /// What went to the game since it was opened or Enter was pressed, for L2 to clear.
    private(set) var typed = ""
    private(set) var showsHints = false
    /// How far the panel was dragged from its top-right home, clamped to `dragRange`.
    private(set) var offset: CGSize = .zero
    var dragRange: CGSize = .zero {
        didSet { move(by: .zero) }
    }

    private let type: ([OverlayKeyboardStroke]) -> Void

    init(type: @escaping ([OverlayKeyboardStroke]) -> Void) {
        self.type = type
    }

    func toggleHints() {
        showsHints.toggle()
    }

    // MARK: Selection

    func isSelected(row: Int, keyIndex: Int) -> Bool {
        row == self.row && keyIndex == Self.keyIndex(in: row, column: column)
    }

    func moveSelection(dx: Int, dy: Int) {
        if dy != 0 {
            row = (row + dy + Self.rows.count) % Self.rows.count
        }
        if dx != 0 {
            let keys = Self.rows[row]
            let index = (Self.keyIndex(in: row, column: column) + dx + keys.count) % keys.count
            column = Self.startColumn(in: row, keyIndex: index)
        }
    }

    private static func keyIndex(in row: Int, column: Int) -> Int {
        var start = 0
        for (index, key) in rows[row].enumerated() {
            if column < start + key.width { return index }
            start += key.width
        }
        return rows[row].count - 1
    }

    private static func startColumn(in row: Int, keyIndex: Int) -> Int {
        rows[row].prefix(keyIndex).reduce(0) { $0 + $1.width }
    }

    // MARK: Typing

    func pressSelected() {
        let key = Self.rows[row][Self.keyIndex(in: row, column: column)]
        switch key.action {
        case .shift:
            shift.toggle()
        case let .character(value):
            typeCharacter(value)
        case .key(.keyboardDeleteOrBackspace):
            backspace()
        case .key(.keyboardReturnOrEnter):
            enter()
        case let .key(usage):
            type([.key(usage)])
        }
    }

    func toggleShift() {
        shift.toggle()
    }

    func space() {
        typeCharacter(" ")
    }

    func backspace() {
        type([.key(.keyboardDeleteOrBackspace)])
        if !typed.isEmpty { typed.removeLast() }
    }

    func enter() {
        type([.key(.keyboardReturnOrEnter)])
        typed = ""
    }

    /// Erases, with Backspace, everything typed since the overlay opened or the last Enter.
    func clear() {
        guard !typed.isEmpty else { return }
        type(Array(repeating: .key(.keyboardDeleteOrBackspace), count: typed.count))
        typed = ""
    }

    private func typeCharacter(_ value: String) {
        let text = shift ? value.uppercased() : value
        type([.character(text)])
        typed += text
        if typed.count > 64 { typed.removeFirst(typed.count - 64) }
        shift = false
    }

    // MARK: Position

    func move(by delta: CGSize) {
        offset = CGSize(
            width: min(max(offset.width + delta.width, -dragRange.width), 0),
            height: min(max(offset.height + delta.height, 0), dragRange.height)
        )
    }
}

/// Reads the controllers directly while the overlay holds focus (gameplay input is paused then),
/// turning presses into keyboard actions. Buttons already down when focus arrives — the shortcut
/// that opened it — count only after they are released.
@MainActor
private struct ControllerKeyboardPoller {
    enum Button: CaseIterable {
        case up, down, left, right, buttonA, buttonB, buttonX, buttonY, l1, r1, l2, r2
    }

    private static let repeatDelay: TimeInterval = 0.38
    private static let repeatInterval: TimeInterval = 0.08
    private static let repeating: Set<Button> = [.up, .down, .left, .right, .buttonB]
    private static let touchpadScale: CGFloat = 520
    private static let stickSpeed: CGFloat = 900

    private var held: Set<Button>
    private var latched: Set<Button>
    private var nextRepeat: [Button: TimeInterval] = [:]
    private var lastTouch: CGPoint?

    init() {
        held = Self.pressedButtons()
        latched = held
    }

    /// Buttons that fire now: fresh presses, plus held repeating ones. Triangle hands input back
    /// to the game, so it fires on release — otherwise the game would see it held.
    mutating func poll(now: TimeInterval) -> (pressed: [Button], released: [Button]) {
        let current = Self.pressedButtons()
        latched.formIntersection(current)
        let usable = current.subtracting(latched)
        var pressed: [Button] = []
        for button in usable.subtracting(held) {
            pressed.append(button)
            nextRepeat[button] = now + Self.repeatDelay
        }
        for button in usable.intersection(held) where Self.repeating.contains(button) {
            if let due = nextRepeat[button], now >= due {
                pressed.append(button)
                nextRepeat[button] = now + Self.repeatInterval
            }
        }
        // A button that was latched when focus arrived never got a repeat deadline.
        var released: [Button] = []
        for button in held.subtracting(current) where nextRepeat.removeValue(forKey: button) != nil {
            released.append(button)
        }
        held = current
        return (pressed, released)
    }

    /// Touchpad slide plus right-stick push, in points, for dragging the panel.
    mutating func dragDelta(elapsed: TimeInterval) -> CGSize {
        var delta = CGSize.zero
        guard let pad = GCController.controllers().compactMap(\.extendedGamepad).first else { return delta }
        let stick = pad.rightThumbstick
        if abs(stick.xAxis.value) > 0.25 || abs(stick.yAxis.value) > 0.25 {
            delta.width += CGFloat(stick.xAxis.value) * Self.stickSpeed * elapsed
            delta.height -= CGFloat(stick.yAxis.value) * Self.stickSpeed * elapsed
        }
        let surface = (pad as? GCDualSenseGamepad)?.touchpadPrimary ?? (pad as? GCDualShockGamepad)?.touchpadPrimary
        if let surface {
            let point = CGPoint(x: CGFloat(surface.xAxis.value), y: CGFloat(surface.yAxis.value))
            let touching = abs(point.x) > 0.02 || abs(point.y) > 0.02
            if touching, let lastTouch {
                delta.width += (point.x - lastTouch.x) * Self.touchpadScale
                delta.height -= (point.y - lastTouch.y) * Self.touchpadScale
            }
            lastTouch = touching ? point : nil
        }
        return delta
    }

    private static func pressedButtons() -> Set<Button> {
        var buttons = Set<Button>()
        for pad in GCController.controllers().compactMap(\.extendedGamepad) {
            let stick = pad.leftThumbstick
            if pad.dpad.up.isPressed || stick.yAxis.value > 0.6 { buttons.insert(.up) }
            if pad.dpad.down.isPressed || stick.yAxis.value < -0.6 { buttons.insert(.down) }
            if pad.dpad.left.isPressed || stick.xAxis.value < -0.6 { buttons.insert(.left) }
            if pad.dpad.right.isPressed || stick.xAxis.value > 0.6 { buttons.insert(.right) }
            if pad.buttonA.isPressed { buttons.insert(.buttonA) }
            if pad.buttonB.isPressed { buttons.insert(.buttonB) }
            if pad.buttonX.isPressed { buttons.insert(.buttonX) }
            if pad.buttonY.isPressed { buttons.insert(.buttonY) }
            if pad.leftShoulder.isPressed { buttons.insert(.l1) }
            if pad.rightShoulder.isPressed { buttons.insert(.r1) }
            if pad.leftTrigger.isPressed { buttons.insert(.l2) }
            if pad.rightTrigger.isPressed { buttons.insert(.r2) }
        }
        return buttons
    }
}

/// A see-through keyboard in the top-right corner of the stream: just the keys, no panel. While
/// it's open the controller drives it: D-pad picks a key, A types it, and every press reaches the
/// game at once. The touchpad or right stick moves it; Square shows the control hints.
struct ControllerKeyboardOverlay: View {
    let model: ControllerKeyboardModel
    let onClose: () -> Void

    private static let keySize = CGSize(width: 60, height: 52)
    private static let spacing: CGFloat = 6
    private static let margin: CGFloat = 40

    @State private var containerSize: CGSize = .zero
    @State private var keyboardSize: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            keys
            if model.showsHints {
                hints
            }
        }
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { keyboardSize = $0; updateDragRange() }
        .offset(model.offset)
        .padding(Self.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { containerSize = $0; updateDragRange() }
        .task { await pollController() }
    }

    private var keys: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(ControllerKeyboardModel.rows.indices, id: \.self) { row in
                HStack(spacing: Self.spacing) {
                    ForEach(ControllerKeyboardModel.rows[row].indices, id: \.self) { index in
                        keyView(ControllerKeyboardModel.rows[row][index], row: row, index: index)
                    }
                }
            }
        }
        .fixedSize()
    }

    private func keyView(_ key: ControllerKeyboardKey, row: Int, index: Int) -> some View {
        let selected = model.isSelected(row: row, keyIndex: index)
        let active = key.action == .shift && model.shift
        let label = model.shift && key.label.count == 1 ? key.label.uppercased() : key.label
        let width = Self.keySize.width * CGFloat(key.width) + Self.spacing * CGFloat(key.width - 1)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Text(label)
            .font(.system(size: key.label.count > 1 ? 19 : 26, weight: .semibold))
            .foregroundStyle(selected ? Color.black : Color.white)
            .frame(width: width, height: Self.keySize.height)
            .background(selected ? Color.white.opacity(0.92) : Color.black.opacity(active ? 0.8 : 0.6), in: shape)
            .overlay { shape.stroke(.white.opacity(active ? 0.6 : 0.18), lineWidth: 1) }
            .scaleEffect(selected ? 1.06 : 1)
    }

    private var hints: some View {
        let pad = GCController.controllers().compactMap(\.extendedGamepad).first
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                hint(pad?.buttonA.sfSymbolsName ?? "a.circle", "type")
                hint(pad?.buttonB.sfSymbolsName ?? "b.circle", "delete")
                hint(pad?.leftShoulder.sfSymbolsName ?? "l1.rectangle.roundedbottom", "shift")
                hint(pad?.rightShoulder.sfSymbolsName ?? "r1.rectangle.roundedbottom", "space")
                hint(pad?.leftTrigger.sfSymbolsName ?? "l2.rectangle.roundedtop", "clear")
            }
            HStack(spacing: 14) {
                hint(pad?.rightTrigger.sfSymbolsName ?? "r2.rectangle.roundedtop", "enter")
                hint(pad?.buttonY.sfSymbolsName ?? "y.circle", "close")
                hint(pad?.buttonX.sfSymbolsName ?? "x.circle", "hide help")
                hint("hand.draw", "touchpad moves")
            }
        }
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .fixedSize()
    }

    private func hint(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(text)
        }
    }

    private func updateDragRange() {
        model.dragRange = CGSize(
            width: max(containerSize.width - keyboardSize.width - Self.margin * 2, 0),
            height: max(containerSize.height - keyboardSize.height - Self.margin * 2, 0)
        )
    }

    private func pollController() async {
        var poller = ControllerKeyboardPoller()
        var last = Date.timeIntervalSinceReferenceDate
        while !Task.isCancelled {
            let now = Date.timeIntervalSinceReferenceDate
            let (pressed, released) = poller.poll(now: now)
            for button in pressed {
                handlePress(button)
            }
            if released.contains(.buttonY) {
                onClose()
                return
            }
            model.move(by: poller.dragDelta(elapsed: now - last))
            last = now
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private func handlePress(_ button: ControllerKeyboardPoller.Button) {
        switch button {
        case .up: model.moveSelection(dx: 0, dy: -1)
        case .down: model.moveSelection(dx: 0, dy: 1)
        case .left: model.moveSelection(dx: -1, dy: 0)
        case .right: model.moveSelection(dx: 1, dy: 0)
        case .buttonA: model.pressSelected()
        case .buttonB: model.backspace()
        case .buttonX: model.toggleHints()
        case .l1: model.toggleShift()
        case .r1: model.space()
        case .l2: model.clear()
        case .r2: model.enter()
        case .buttonY: break
        }
    }
}
