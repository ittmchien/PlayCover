//
//  EmulatedControllerVM.swift
//  PlayCover
//

import AppKit
import Foundation

// Controller emulation mapping: edits one app's key layout file and records keys for an input row
final class EmulatedControllerVM: ObservableObject {
    // Controller emulation mapping: transient inline message shown under one input row
    struct RowHint: Equatable {
        let id = UUID()
        let input: EmulatedControllerInput
        let text: String
    }

    private static let hintDuration: TimeInterval = 3

    // Virtual key code -> modifier flag of Left/Right Shift, Control, Option, Command and Caps Lock
    private static let modifierFlagByVirtualKeyCode: [UInt16: NSEvent.ModifierFlags] = [
        56: .shift, 60: .shift, 59: .control, 62: .control,
        58: .option, 61: .option, 55: .command, 54: .command, 57: .capsLock
    ]

    #if DEBUG
    private static let selfCheckOnce: Void = EmulatedControllerMapping.selfCheck()
    #endif

    let bundleIdentifier: String

    @Published private(set) var mapping: EmulatedControllerMapping {
        didSet { persist() }
    }
    @Published private(set) var recordingInput: EmulatedControllerInput?
    @Published private(set) var hint: RowHint?

    private var hasStoredFile: Bool
    private var keyMonitor: Any?

    var isEnabled: Bool {
        get { mapping.isEnabled }
        set {
            stopRecording()
            // First enable without a file seeds Apple's layout plus the suggested extras
            if newValue && !hasStoredFile {
                mapping = .seeded
            } else {
                mapping.isEnabled = newValue
            }
        }
    }

    init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
        let storedMapping = EmulatedControllerMapping.load(bundleIdentifier: bundleIdentifier)
        hasStoredFile = storedMapping != nil
        mapping = storedMapping ?? EmulatedControllerMapping()
        #if DEBUG
        _ = EmulatedControllerVM.selfCheckOnce
        #endif
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    func removeKey(_ key: Int) {
        mapping.removeKey(key)
    }

    func resetToAppleDefault() {
        stopRecording()
        mapping.resetToAppleDefault()
    }

    func addSuggestedExtras() {
        stopRecording()
        mapping.addSuggestedExtras()
    }

    // Controller emulation mapping: start recording for a row, or cancel when it is already recording
    func toggleRecording(for input: EmulatedControllerInput) {
        let isSameRow = recordingInput == input
        stopRecording()
        guard !isSameRow else { return }
        hint = nil
        recordingInput = input
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handleRecording(event)
        }
    }

    func stopRecording() {
        recordingInput = nil
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    // Controller emulation mapping: capture the next key press; returning nil swallows the event
    private func handleRecording(_ event: NSEvent) -> NSEvent? {
        guard let input = recordingInput else { return event }
        let isMenuShortcut = event.type == .keyDown && event.modifierFlags.contains(.command)
        guard !isMenuShortcut else { return event }
        guard let usage = Self.pressedHIDUsage(of: event) else {
            guard event.type == .keyDown else { return event }
            showHint(NSLocalizedString("settings.controller.unsupportedKey", comment: ""), for: input)
            return nil
        }
        guard !EmulatedControllerMapping.reservedKeys.contains(usage) else {
            showHint(NSLocalizedString("settings.controller.reservedKey", comment: ""), for: input)
            return nil
        }
        record(usage, for: input)
        return nil
    }

    // Controller emulation mapping: HID usage of a key press; nil for unknown keys and modifier releases
    // ponytail: reads the shared modifier flag, so releasing one Shift while the other is held counts as a press
    private static func pressedHIDUsage(of event: NSEvent) -> Int? {
        guard let usage = KeyCodeNames.hidUsageByVirtualKeyCode[event.keyCode] else { return nil }
        guard event.type == .flagsChanged else { return usage }
        guard let flag = modifierFlagByVirtualKeyCode[event.keyCode] else { return nil }
        return event.modifierFlags.contains(flag) ? usage : nil
    }

    private func record(_ usage: Int, for input: EmulatedControllerInput) {
        stopRecording()
        hint = nil
        guard let movedFrom = mapping.assign(key: usage, to: input) else { return }
        let format = NSLocalizedString("settings.controller.movedFrom", comment: "")
        showHint(String(format: format, NSLocalizedString(movedFrom.localizationKey, comment: "")), for: input)
    }

    private func showHint(_ text: String, for input: EmulatedControllerInput) {
        let newHint = RowHint(input: input, text: text)
        hint = newHint
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hintDuration) { [weak self] in
            guard let self, self.hint == newHint else { return }
            self.hint = nil
        }
    }

    private func persist() {
        mapping.save(bundleIdentifier: bundleIdentifier)
        hasStoredFile = true
    }
}
