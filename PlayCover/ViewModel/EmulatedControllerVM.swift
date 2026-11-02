//
//  EmulatedControllerVM.swift
//  PlayCover
//

import AppKit
import Foundation
import UniformTypeIdentifiers

// Controller emulation mapping: edits one app's key layout file and records keys for an input row
final class EmulatedControllerVM: ObservableObject {
    // Controller combos: a row that records keys and shows hints, either one input or one combo
    enum RowTarget: Equatable {
        case input(EmulatedControllerInput)
        case combo([EmulatedControllerInput])
    }

    // Controller combos: transient inline message under one row (nil target = action buttons)
    struct RowHint: Equatable {
        let id = UUID()
        let target: RowTarget?
        let text: String
    }

    private static let hintDuration: TimeInterval = 3

    // Virtual key code -> modifier flag of Left/Right Shift, Control, Option, Command and Caps Lock
    private static let modifierFlagByVirtualKeyCode: [UInt16: NSEvent.ModifierFlags] = [
        56: .shift, 60: .shift, 59: .control, 62: .control,
        58: .option, 61: .option, 55: .command, 54: .command, 57: .capsLock
    ]

    // Controller combos: Caps Lock reports no key release, so a key set records it as a tap
    private static let capsLockUsage = 57

    #if DEBUG
    private static let selfCheckOnce: Void = EmulatedControllerMapping.selfCheck()
    #endif

    let bundleIdentifier: String

    @Published private(set) var mapping: EmulatedControllerMapping {
        didSet { persist() }
    }
    @Published private(set) var recordingTarget: RowTarget?
    @Published private(set) var hint: RowHint?
    // Controller combos: input set of a new combo, shown (not saved) until its first key set is recorded
    @Published private(set) var pendingComboInputs: [EmulatedControllerInput]?
    // Controller presets: mapping (bundled preset or imported file) waiting for the replace confirmation
    @Published var replacementCandidate: EmulatedControllerMapping?

    // Controller presets: preset shipped in the app for this bundle id, nil when none
    let bundledPreset: EmulatedControllerMapping?

    private var hasStoredFile: Bool
    private var keyMonitor: Any?
    private var heldKeys: Set<Int> = []
    private var largestHeldKeys: Set<Int> = []

    var isEnabled: Bool {
        get { mapping.isEnabled }
        set {
            stopRecording()
            // Controller presets: first enable without a file uses the bundled preset (enabled),
            // else Apple's layout plus the suggested extras
            if newValue && !hasStoredFile {
                var firstMapping = bundledPreset ?? .seeded
                firstMapping.isEnabled = true
                mapping = firstMapping
            } else {
                mapping.isEnabled = newValue
            }
        }
    }

    // Controller combos: saved combos plus the pending one
    var comboGroups: [EmulatedControllerComboGroup] {
        let groups = mapping.comboGroups
        guard let pendingComboInputs else { return groups }
        return groups + [EmulatedControllerComboGroup(inputs: pendingComboInputs, keySets: [])]
    }

    init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
        let storedMapping = EmulatedControllerMapping.load(bundleIdentifier: bundleIdentifier)
        hasStoredFile = storedMapping != nil
        mapping = storedMapping ?? EmulatedControllerMapping()
        bundledPreset = EmulatedControllerMapping.bundledPreset(bundleIdentifier: bundleIdentifier)
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

    // Controller presets: ask to replace the layout with the bundled preset
    func requestBundledPreset() {
        stopRecording()
        replacementCandidate = bundledPreset
    }

    // Controller presets: pick a mapping plist (any file name); an unusable file only shows a hint
    func requestImport() {
        stopRecording()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.propertyList]
        panel.begin { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            guard let imported = EmulatedControllerMapping.decode(contentsOf: url),
                  !imported.buttons.isEmpty || !imported.combos.isEmpty else {
                self.showHint(NSLocalizedString("settings.controller.importInvalid", comment: ""), for: nil)
                return
            }
            self.replacementCandidate = imported
        }
    }

    // Controller presets: confirmed replacement keeps this app's overlay settings and turns the layout on,
    // since loading or importing a layout means the user wants to use it
    func applyReplacement(_ replacement: EmulatedControllerMapping) {
        stopRecording()
        replacementCandidate = nil
        var replaced = mapping
        replaced.replaceKeepingOverlay(with: replacement)
        replaced.isEnabled = true
        mapping = replaced
    }

    // Controller emulation mapping: add free extras and list the ones skipped because their key is in use
    func addSuggestedExtras() {
        stopRecording()
        let skippedKeys = mapping.addSuggestedExtras()
        guard !skippedKeys.isEmpty else { return }
        // Controller key chips: same full key names as the chips
        let keyNames = skippedKeys.map { EmulatedControllerKeyLabel.name(forHIDUsage: $0) }.joined(separator: ", ")
        let format = NSLocalizedString("settings.controller.extrasSkipped", comment: "")
        showHint(String(format: format, keyNames), for: nil)
    }

    // Controller combos: record a key set for an input set; a new input set stays pending until recorded
    func startCombo(with inputs: Set<EmulatedControllerInput>) {
        let comboInputs = EmulatedControllerCombo.sortedInputs(inputs)
        guard !comboInputs.isEmpty else { return }
        stopRecording()
        let isExistingCombo = mapping.combos.contains { $0.inputs == comboInputs }
        pendingComboInputs = isExistingCombo ? nil : comboInputs
        startRecording(.combo(comboInputs))
    }

    // Controller combos: removing a key set cancels recording, its combo row may disappear
    func removeComboKeys(_ keys: [Int]) {
        stopRecording()
        mapping.removeComboKeys(keys)
    }

    func setComboPriority(_ priority: EmulatedControllerComboPriority, for inputs: [EmulatedControllerInput]) {
        mapping.setComboPriority(priority, for: inputs)
    }

    func deleteCombo(_ inputs: [EmulatedControllerInput]) {
        stopRecording()
        mapping.removeCombo(inputs: inputs)
    }

    // Controller combos: hint text for a row, or for the action buttons when target is nil
    func hintText(for target: RowTarget?) -> String? {
        guard let hint, hint.target == target else { return nil }
        return hint.text
    }

    // Controller combos: start recording for a row, or cancel when it is already recording (one row at a time)
    func toggleRecording(for target: RowTarget) {
        let isSameRow = recordingTarget == target
        stopRecording()
        guard !isSameRow else { return }
        startRecording(target)
    }

    // Controller combos: stopping also drops a pending combo and the keys held so far
    func stopRecording() {
        recordingTarget = nil
        pendingComboInputs = nil
        heldKeys = []
        largestHeldKeys = []
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    private func startRecording(_ target: RowTarget) {
        hint = nil
        recordingTarget = target
        let recordedEvents: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: recordedEvents) { [weak self] event in
            guard let self else { return event }
            return self.handleRecording(event)
        }
    }

    // Controller combos: route a key event to the recording row; returning nil swallows the event
    private func handleRecording(_ event: NSEvent) -> NSEvent? {
        guard let target = recordingTarget else { return event }
        let isMenuShortcut = event.type == .keyDown && event.modifierFlags.contains(.command)
        guard !isMenuShortcut else { return event }
        guard let change = Self.keyChange(of: event, heldKeys: heldKeys) else {
            guard event.type == .keyDown else { return event }
            showHint(NSLocalizedString("settings.controller.unsupportedKey", comment: ""), for: target)
            return nil
        }
        if EmulatedControllerMapping.reservedKeys.contains(change.usage) {
            guard change.isPress else { return event }
            showHint(NSLocalizedString("settings.controller.reservedKey", comment: ""), for: target)
            return nil
        }
        switch target {
        case .input(let input):
            guard change.isPress else { return event }
            record(change.usage, for: input)
        case .combo(let inputs):
            trackKeySet(change, for: inputs)
        }
        return nil
    }

    // Controller combos: HID usage of a key event and whether the key went down; nil for unknown keys.
    // A modifier whose flag stays set while it is held was released with its Left/Right twin still down.
    // ponytail: a twin held before recording started reads as a press on release; fine for a settings screen
    private static func keyChange(of event: NSEvent, heldKeys: Set<Int>) -> (usage: Int, isPress: Bool)? {
        guard let usage = KeyCodeNames.hidUsageByVirtualKeyCode[event.keyCode] else { return nil }
        switch event.type {
        case .keyDown:
            return (usage, true)
        case .keyUp:
            return (usage, false)
        default:
            guard let flag = modifierFlagByVirtualKeyCode[event.keyCode] else { return nil }
            return (usage, event.modifierFlags.contains(flag) && !heldKeys.contains(usage))
        }
    }

    private func record(_ usage: Int, for input: EmulatedControllerInput) {
        stopRecording()
        hint = nil
        guard let movedFrom = mapping.assign(key: usage, to: input) else { return }
        showMovedFromHint(movedFrom.localizedName, for: .input(input))
    }

    // Controller combos: track held keys; once all are released, commit the largest set held together
    private func trackKeySet(_ change: (usage: Int, isPress: Bool), for inputs: [EmulatedControllerInput]) {
        let isTap = change.usage == Self.capsLockUsage
        if change.isPress || isTap {
            heldKeys.insert(change.usage)
            if heldKeys.count > largestHeldKeys.count {
                largestHeldKeys = heldKeys
            }
        }
        guard !change.isPress || isTap else { return }
        heldKeys.remove(change.usage)
        guard heldKeys.isEmpty, !largestHeldKeys.isEmpty else { return }
        recordKeySet(largestHeldKeys, for: inputs)
    }

    // Controller combos: save the key set; a key set taken from another combo shows where it came from
    private func recordKeySet(_ keys: Set<Int>, for inputs: [EmulatedControllerInput]) {
        stopRecording()
        hint = nil
        guard let movedFrom = mapping.addComboKeys(keys, to: inputs) else { return }
        let movedFromName = movedFrom.map(\.localizedName).joined(separator: EmulatedControllerCombo.displaySeparator)
        showMovedFromHint(movedFromName, for: .combo(inputs))
    }

    private func showMovedFromHint(_ name: String, for target: RowTarget) {
        let format = NSLocalizedString("settings.controller.movedFrom", comment: "")
        showHint(String(format: format, name), for: target)
    }

    private func showHint(_ text: String, for target: RowTarget?) {
        let newHint = RowHint(target: target, text: text)
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
