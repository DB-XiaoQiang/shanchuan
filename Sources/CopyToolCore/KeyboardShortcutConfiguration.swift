import Foundation

/// 使用独立、稳定的修饰键位图保存配置，不依赖 AppKit 或 Carbon 的常量取值。
public struct ShortcutBinding: Codable, Equatable, Sendable {
    public static let commandModifier: UInt32 = 1
    public static let optionModifier: UInt32 = 2
    public static let controlModifier: UInt32 = 4
    public static let shiftModifier: UInt32 = 8
    public static let supportedModifiers: UInt32 = 15

    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var displayName: String {
        let modifierNames: [(UInt32, String)] = [
            (Self.controlModifier, "⌃"), (Self.optionModifier, "⌥"),
            (Self.shiftModifier, "⇧"), (Self.commandModifier, "⌘")
        ]
        return modifierNames.filter { modifiers & $0.0 != 0 }.map(\.1).joined()
            + ShortcutKeyCatalog.displayName(for: keyCode)
    }

    fileprivate var validationError: String? {
        if !ShortcutKeyCatalog.allowedKeyCodes.contains(keyCode) { return "请选择支持的快捷键按键" }
        if modifiers & ~Self.supportedModifiers != 0 { return "快捷键包含不支持的修饰键" }
        if modifiers & (Self.commandModifier | Self.optionModifier | Self.controlModifier) == 0 {
            return "快捷键至少需要 Command、Option 或 Control 中的一个修饰键"
        }

        let command = modifiers & Self.commandModifier != 0
        let option = modifiers & Self.optionModifier != 0
        let control = modifiers & Self.controlModifier != 0
        let shift = modifiers & Self.shiftModifier != 0
        // 保留应用原有的复制、粘贴，以及 macOS 的窗口、切换、锁屏和截图操作。
        if command && !option && !control && [UInt32(8), 9].contains(keyCode) {
            return "请避开系统复制、粘贴快捷键 Command+C / Command+V"
        }
        if command && [UInt32(12), 13, 4, 46, 48, 49].contains(keyCode) {
            return "该组合用于系统或窗口操作，请选择其他快捷键"
        }
        if command && option && keyCode == 53 {
            return "该组合用于系统强制退出，请选择其他快捷键"
        }
        if command && shift && [UInt32(20), 21, 23].contains(keyCode) {
            return "该组合用于系统截图，请选择其他快捷键"
        }
        return nil
    }
}

public struct ShortcutKey: Identifiable, Equatable, Sendable {
    public var keyCode: UInt32
    public var displayName: String
    public var id: UInt32 { keyCode }
}

/// macOS 虚拟键码；键位按 ANSI 键盘标注，与系统当前输入法无关。
public enum ShortcutKeyCatalog {
    public static let keys: [ShortcutKey] = {
        let definitions: [(UInt32, String)] = [
            (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"),
            (5, "G"), (4, "H"), (34, "I"), (38, "J"), (40, "K"), (37, "L"),
            (46, "M"), (45, "N"), (31, "O"), (35, "P"), (12, "Q"), (15, "R"),
            (1, "S"), (17, "T"), (32, "U"), (9, "V"), (13, "W"), (7, "X"),
            (16, "Y"), (6, "Z"),
            (29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"),
            (23, "5"), (22, "6"), (26, "7"), (28, "8"), (25, "9"),
            (27, "-"), (24, "="), (33, "["), (30, "]"), (42, "\\"),
            (41, ";"), (39, "'"), (43, ","), (47, "."), (44, "/"), (50, "`"),
            (49, "空格"), (48, "Tab"), (36, "Return"), (51, "Delete"), (53, "Escape"),
            (123, "←"), (124, "→"), (125, "↓"), (126, "↑"),
            (115, "Home"), (119, "End"), (116, "Page Up"), (121, "Page Down"),
            (117, "向前删除"),
            (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"), (96, "F5"),
            (97, "F6"), (98, "F7"), (100, "F8"), (101, "F9"), (109, "F10"),
            (103, "F11"), (111, "F12")
        ]
        return definitions.map { ShortcutKey(keyCode: $0.0, displayName: $0.1) }
    }()

    public static let allowedKeyCodes = Set(keys.map(\.keyCode))

    public static func displayName(for keyCode: UInt32) -> String {
        keys.first { $0.keyCode == keyCode }?.displayName ?? "未知按键（\(keyCode)）"
    }
}

public struct CopyPasteShortcuts: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var copy: ShortcutBinding
    public var paste: ShortcutBinding

    public init(enabled: Bool = false,
                copy: ShortcutBinding = .init(keyCode: 8, modifiers: 6),
                paste: ShortcutBinding = .init(keyCode: 9, modifiers: 6)) {
        self.enabled = enabled
        self.copy = copy
        self.paste = paste
    }

    private enum CodingKeys: String, CodingKey { case enabled, copy, paste }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        copy = try values.decodeIfPresent(ShortcutBinding.self, forKey: .copy) ?? copy
        paste = try values.decodeIfPresent(ShortcutBinding.self, forKey: .paste) ?? paste
    }

    public var validationError: String? {
        guard enabled else { return nil }
        if let error = copy.validationError { return "复制快捷键：" + error }
        if let error = paste.validationError { return "粘贴快捷键：" + error }
        if copy == paste { return "复制和粘贴快捷键不能相同" }
        return nil
    }
}
