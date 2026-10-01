import CoreGraphics

/// A key plus modifiers, matched against raw key codes so it works with any layout.
struct Hotkey: Codable, Equatable {
    var keyCode: UInt16
    /// `CGEventFlags` raw value, limited to `modifierMask`.
    var modifiers: UInt64

    static let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        keyCode == self.keyCode && flags.intersection(Self.modifierMask).rawValue == modifiers
    }

    var displayString: String {
        let flags = CGEventFlags(rawValue: modifiers)
        var text = ""
        if flags.contains(.maskControl) { text += "⌃" }
        if flags.contains(.maskAlternate) { text += "⌥" }
        if flags.contains(.maskShift) { text += "⇧" }
        if flags.contains(.maskCommand) { text += "⌘" }
        return text + (Self.keyNames[keyCode] ?? "Key \(keyCode)")
    }

    private static let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    /// ⌃⌥⌘1, ⌃⌥⌘2, … skipping any already in use.
    static func defaultHotkey(excluding used: [Hotkey]) -> Hotkey? {
        let modifiers = CGEventFlags([.maskControl, .maskAlternate, .maskCommand]).rawValue
        return digitKeyCodes
            .map { Hotkey(keyCode: $0, modifiers: modifiers) }
            .first { !used.contains($0) }
    }

    /// Names by ANSI key position.
    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        115: "↖", 116: "⇞", 117: "⌦", 118: "F4", 119: "↘", 120: "F2", 121: "⇟", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}
