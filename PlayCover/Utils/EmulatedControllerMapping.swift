//
//  EmulatedControllerMapping.swift
//  PlayCover
//

import Foundation

// Controller emulation mapping: gamepad input of macOS Controller Emulation (raw value = event input index)
enum EmulatedControllerInput: Int, CaseIterable {
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case buttonA, buttonB, buttonX, buttonY
    case leftShoulder, rightShoulder
    case leftStickUp, leftStickDown, leftStickLeft, leftStickRight
    case rightStickUp, rightStickDown, rightStickLeft, rightStickRight
    case leftTrigger, rightTrigger
    case leftStickButton, rightStickButton
    case home, menu, options

    var localizationKey: String { "settings.controller.input.\(self)" }
}

// Controller emulation mapping: in-game overlay settings (edited in a later phase, preserved on rewrite)
struct EmulatedControllerOverlay: Codable, Equatable {
    static let defaultStyle = "list"
    static let defaultOpacity = 0.8

    var style = EmulatedControllerOverlay.defaultStyle
    var opacity = EmulatedControllerOverlay.defaultOpacity

    enum CodingKeys: String, CodingKey {
        case style = "Style"
        case opacity = "Opacity"
    }
}

// Controller emulation mapping: per-app key layout shared with PlayTools through a plist file
struct EmulatedControllerMapping: Equatable {
    // Esc (show pointer) and Left/Right Command (menu shortcuts) stay with macOS
    static let reservedKeys: Set<Int> = [41, 227, 231]

    // Apple's built-in layout (HID keyboard usage -> input)
    static let appleDefaultButtons: [Int: EmulatedControllerInput] = [
        82: .dpadUp, 81: .dpadDown, 80: .dpadLeft, 79: .dpadRight,
        44: .buttonA, 9: .buttonB, 11: .buttonB, 20: .buttonX, 24: .buttonX, 8: .buttonY, 18: .buttonY,
        43: .leftShoulder, 28: .leftShoulder, 21: .rightShoulder, 19: .rightShoulder,
        26: .leftStickUp, 12: .leftStickUp, 22: .leftStickDown, 14: .leftStickDown,
        4: .leftStickLeft, 13: .leftStickLeft, 7: .leftStickRight, 15: .leftStickRight,
        225: .leftTrigger, 17: .leftTrigger, 45: .menu, 53: .menu
    ]

    // Inputs Apple leaves unmapped: Z -> L3, X -> R3, C -> Options, V -> Home
    static let suggestedExtraButtons: [Int: EmulatedControllerInput] = [
        29: .leftStickButton, 27: .rightStickButton, 6: .options, 25: .home
    ]

    static var seeded: EmulatedControllerMapping {
        EmulatedControllerMapping(isEnabled: true,
                                  buttons: appleDefaultButtons.merging(suggestedExtraButtons) { _, extra in extra })
    }

    var isEnabled = false
    var buttons: [Int: EmulatedControllerInput] = [:]
    var overlay = EmulatedControllerOverlay()

    var keysByInput: [EmulatedControllerInput: [Int]] {
        Dictionary(grouping: buttons.sorted { $0.key < $1.key }, by: { $0.value })
            .mapValues { entries in entries.map { $0.key } }
    }

    // Controller emulation mapping: map a key to an input; returns the input it was moved away from
    @discardableResult
    mutating func assign(key: Int, to input: EmulatedControllerInput) -> EmulatedControllerInput? {
        let previous = buttons.updateValue(input, forKey: key)
        return previous == input ? nil : previous
    }

    mutating func removeKey(_ key: Int) {
        buttons[key] = nil
    }

    mutating func resetToAppleDefault() {
        buttons = Self.appleDefaultButtons
    }

    // Controller emulation mapping: add only extras whose key is free; returns the skipped (already used) keys
    @discardableResult
    mutating func addSuggestedExtras() -> [Int] {
        var skippedKeys: [Int] = []
        for (key, input) in Self.suggestedExtraButtons {
            if let currentInput = buttons[key], currentInput != input {
                skippedKeys.append(key)
            } else {
                buttons[key] = input
            }
        }
        return skippedKeys.sorted()
    }
}

// Controller emulation mapping: plist coding with string HID keys (plist dictionary keys must be strings)
extension EmulatedControllerMapping: Codable {
    enum CodingKeys: String, CodingKey {
        case isEnabled = "Enabled"
        case buttons = "Buttons"
        case overlay = "Overlay"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        let storedButtons = try container.decodeIfPresent([String: Int].self, forKey: .buttons) ?? [:]
        let storedOverlay = try container.decodeIfPresent(EmulatedControllerOverlay.self, forKey: .overlay)
            ?? EmulatedControllerOverlay()
        let validButtons = storedButtons.compactMap { key, value -> (Int, EmulatedControllerInput)? in
            guard let usage = Int(key), let input = EmulatedControllerInput(rawValue: value) else { return nil }
            return (usage, input)
        }
        self.init(isEnabled: storedEnabled,
                  buttons: Dictionary(validButtons) { first, _ in first },
                  overlay: storedOverlay)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let storedButtons = Dictionary(uniqueKeysWithValues: buttons.map { (String($0.key), $0.value.rawValue) })
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(storedButtons, forKey: .buttons)
        try container.encode(overlay, forKey: .overlay)
    }
}

// Controller emulation mapping: overlay decoding with defaults for missing values
extension EmulatedControllerOverlay {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedStyle = try container.decodeIfPresent(String.self, forKey: .style) ?? Self.defaultStyle
        let storedOpacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? Self.defaultOpacity
        self.init(style: storedStyle, opacity: storedOpacity)
    }
}

// Controller emulation mapping: file storage in PlayCover's container (EmulatedController/<bundleId>.plist)
extension EmulatedControllerMapping {
    static let directory = PlayTools.playCoverContainer.appendingPathComponent("EmulatedController")

    static func fileURL(bundleIdentifier: String) -> URL {
        directory.appendingPathComponent(bundleIdentifier).appendingPathExtension("plist")
    }

    // Returns nil when the app has no file yet or the file is unreadable
    static func load(bundleIdentifier: String) -> EmulatedControllerMapping? {
        let url = fileURL(bundleIdentifier: bundleIdentifier)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try PropertyListDecoder().decode(EmulatedControllerMapping.self, from: Data(contentsOf: url))
        } catch {
            Log.shared.log("Ignoring unreadable controller mapping \(url.path): \(error)", isError: true)
            return nil
        }
    }

    func save(bundleIdentifier: String) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try encoder.encode(self).write(to: Self.fileURL(bundleIdentifier: bundleIdentifier), options: .atomic)
        } catch {
            Log.shared.error(error)
        }
    }
}

#if DEBUG
// Controller emulation mapping: assert-based check of the pure model logic, DEBUG builds only
extension EmulatedControllerMapping {
    static func selfCheck() {
        let space = 44
        var mapping = EmulatedControllerMapping.seeded
        assert(mapping.isEnabled)
        assert(mapping.buttons.count == appleDefaultButtons.count + suggestedExtraButtons.count)
        assert(EmulatedControllerInput.options.rawValue == 24)
        assert(EmulatedControllerInput.leftStickButton.localizationKey == "settings.controller.input.leftStickButton")

        let movedFrom = mapping.assign(key: space, to: .buttonB)
        assert(movedFrom == .buttonA)
        let movedAgainFrom = mapping.assign(key: space, to: .buttonB)
        assert(movedAgainFrom == nil)
        assert(mapping.keysByInput[.buttonB] == [9, 11, space])
        mapping.removeKey(space)
        assert(mapping.buttons[space] == nil)

        mapping.resetToAppleDefault()
        assert(mapping.buttons == appleDefaultButtons)
        let skippedOnDefault = mapping.addSuggestedExtras()
        assert(skippedOnDefault.isEmpty)
        assert(mapping.keysByInput[.options] == [6])

        // Extras never steal a key the user moved elsewhere
        let zKey = 29
        mapping.assign(key: zKey, to: .buttonA)
        let skippedOnCustom = mapping.addSuggestedExtras()
        assert(skippedOnCustom == [zKey])
        assert(mapping.buttons[zKey] == .buttonA)
        assert(mapping.keysByInput[.leftStickButton] == nil)

        mapping.isEnabled = false
        do {
            let data = try PropertyListEncoder().encode(mapping)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            let storedButtons = plist?["Buttons"] as? [String: Int]
            assert(storedButtons?["44"] == EmulatedControllerInput.buttonA.rawValue)
            let decoded = try PropertyListDecoder().decode(EmulatedControllerMapping.self, from: data)
            assert(decoded == mapping)
        } catch {
            assertionFailure("Controller mapping round trip failed: \(error)")
        }
    }
}
#endif
