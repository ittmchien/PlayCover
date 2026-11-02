//
//  EmulatedControllerKeyLabel.swift
//  PlayCover
//

import SwiftUI

// Controller key chips: SF Symbol and localized full name of the special keys, by HID keyboard usage
enum EmulatedControllerKeyLabel {
    private struct SpecialKey {
        let symbolName: String
        let localizationKey: String
    }

    private static let specialKeysByHIDUsage: [Int: SpecialKey] = [
        225: SpecialKey(symbolName: "shift", localizationKey: "settings.controller.key.leftShift"),
        229: SpecialKey(symbolName: "shift", localizationKey: "settings.controller.key.rightShift"),
        224: SpecialKey(symbolName: "control", localizationKey: "settings.controller.key.leftControl"),
        228: SpecialKey(symbolName: "control", localizationKey: "settings.controller.key.rightControl"),
        226: SpecialKey(symbolName: "option", localizationKey: "settings.controller.key.leftOption"),
        230: SpecialKey(symbolName: "option", localizationKey: "settings.controller.key.rightOption"),
        227: SpecialKey(symbolName: "command", localizationKey: "settings.controller.key.leftCommand"),
        231: SpecialKey(symbolName: "command", localizationKey: "settings.controller.key.rightCommand"),
        57: SpecialKey(symbolName: "capslock", localizationKey: "settings.controller.key.capsLock"),
        44: SpecialKey(symbolName: "space", localizationKey: "settings.controller.key.space"),
        40: SpecialKey(symbolName: "return", localizationKey: "settings.controller.key.return"),
        42: SpecialKey(symbolName: "delete.left", localizationKey: "settings.controller.key.delete"),
        43: SpecialKey(symbolName: "arrow.right.to.line", localizationKey: "settings.controller.key.tab"),
        41: SpecialKey(symbolName: "escape", localizationKey: "settings.controller.key.escape"),
        82: SpecialKey(symbolName: "arrow.up", localizationKey: "settings.controller.key.upArrow"),
        81: SpecialKey(symbolName: "arrow.down", localizationKey: "settings.controller.key.downArrow"),
        80: SpecialKey(symbolName: "arrow.left", localizationKey: "settings.controller.key.leftArrow"),
        79: SpecialKey(symbolName: "arrow.right", localizationKey: "settings.controller.key.rightArrow")
    ]

    // Resolved once: symbol availability never changes while PlayCover runs; a missing symbol shows the name only
    private static let availableSymbolNamesByHIDUsage: [Int: String] = specialKeysByHIDUsage
        .filter { EmulatedControllerInputIcon.isAvailable($0.value.symbolName) }
        .mapValues(\.symbolName)

    static func symbolName(forHIDUsage usage: Int) -> String? {
        availableSymbolNamesByHIDUsage[usage]
    }

    // Special keys get their full localized name; every other key keeps its KeyCodeNames name
    static func name(forHIDUsage usage: Int) -> String {
        guard let specialKey = specialKeysByHIDUsage[usage] else {
            return KeyCodeNames.displayName(forHIDUsage: usage)
        }
        return NSLocalizedString(specialKey.localizationKey, comment: "")
    }
}

// Controller key chips: one key as its SF Symbol (special keys only) followed by its full name
struct EmulatedControllerKeyView: View {
    private static let iconSpacing: CGFloat = 2

    let usage: Int

    var body: some View {
        HStack(spacing: Self.iconSpacing) {
            if let symbolName = EmulatedControllerKeyLabel.symbolName(forHIDUsage: usage) {
                Image(systemName: symbolName)
            }
            Text(verbatim: EmulatedControllerKeyLabel.name(forHIDUsage: usage))
        }
    }
}

// Controller key chips: removable chip of one key (input rows) or a key set joined with "+" (combo rows)
struct EmulatedControllerKeyChip: View {
    private static let cornerRadius: CGFloat = 6
    private static let horizontalPadding: CGFloat = 6
    private static let verticalPadding: CGFloat = 2
    private static let backgroundOpacity = 0.2

    let keys: [Int]
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(keys.enumerated()), id: \.element) { index, key in
                if index > 0 {
                    Text(verbatim: EmulatedControllerCombo.displaySeparator)
                }
                EmulatedControllerKeyView(usage: key)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(BorderlessButtonStyle())
            .help("settings.controller.removeKey")
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .background(RoundedRectangle(cornerRadius: Self.cornerRadius)
            .fill(Color.secondary.opacity(Self.backgroundOpacity)))
    }
}
