//
//  EmulatedControllerView.swift
//  PlayCover
//

import SwiftUI

// Controller emulation mapping: input groups shown in the Controller tab
enum EmulatedControllerGroup: CaseIterable {
    case face, dpad, shoulders, leftStick, rightStick, system

    var localizationKey: String { "settings.controller.group.\(self)" }

    var inputs: [EmulatedControllerInput] {
        switch self {
        case .face: return [.buttonA, .buttonB, .buttonX, .buttonY]
        case .dpad: return [.dpadUp, .dpadDown, .dpadLeft, .dpadRight]
        case .shoulders: return [.leftShoulder, .rightShoulder, .leftTrigger, .rightTrigger]
        case .leftStick: return [.leftStickUp, .leftStickDown, .leftStickLeft, .leftStickRight, .leftStickButton]
        case .rightStick:
            return [.rightStickUp, .rightStickDown, .rightStickLeft, .rightStickRight, .rightStickButton]
        case .system: return [.menu, .options, .home]
        }
    }
}

// Controller emulation mapping: "Controller" settings tab editing the emulated controller key layout
struct EmulatedControllerView: View {
    @StateObject private var viewModel: EmulatedControllerVM
    @State private var isConfirmingReset = false

    init(bundleIdentifier: String) {
        _viewModel = StateObject(wrappedValue: EmulatedControllerVM(bundleIdentifier: bundleIdentifier))
    }

    var body: some View {
        let keysByInput = viewModel.mapping.keysByInput
        ScrollView {
            VStack(alignment: .leading) {
                Toggle("settings.controller.toggle", isOn: $viewModel.isEnabled)
                Text("settings.controller.help")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Controller presets: usable while the layout is off, since applying one turns it on
                presetButtons
                // An enabled layout without keys leaves the keyboard unable to control the game
                if viewModel.isEnabled && viewModel.mapping.buttons.isEmpty {
                    Label("settings.controller.noKeysWarning", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
                Group {
                    ForEach(EmulatedControllerGroup.allCases, id: \.self) { group in
                        inputGroup(group, keysByInput: keysByInput)
                    }
                    actionButtons
                    // Controller combos: combos come after the input layout, disabled with it
                    EmulatedControllerCombosSection(viewModel: viewModel)
                }
                .disabled(!viewModel.isEnabled)
                fixedInputs
            }
            .padding()
        }
        .onDisappear {
            viewModel.stopRecording()
        }
    }

    // Controller emulation mapping: reset asks for confirmation; skipped extras are listed below the buttons
    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Button("settings.controller.resetDefault") {
                    viewModel.stopRecording()
                    isConfirmingReset = true
                }
                Button("settings.controller.addExtras") {
                    viewModel.addSuggestedExtras()
                }
                .help("settings.controller.addExtras.help")
                Spacer()
            }
            if let actionHint = viewModel.hintText(for: nil) {
                Text(actionHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .alert("settings.controller.resetConfirm.title", isPresented: $isConfirmingReset) {
            Button("settings.controller.resetConfirm.reset", role: .destructive) {
                viewModel.resetToAppleDefault()
            }
            Button("button.Cancel", role: .cancel) {}
        } message: {
            Text("settings.controller.resetConfirm.message")
        }
    }

    // Controller presets: bundled preset (only when one exists) and file import, both confirmed before replacing
    private var presetButtons: some View {
        HStack {
            if viewModel.bundledPreset != nil {
                Button("settings.controller.loadPreset") {
                    viewModel.requestBundledPreset()
                }
                .help("settings.controller.loadPreset.help")
            }
            Button("settings.controller.import") {
                viewModel.requestImport()
            }
            .help("settings.controller.import.help")
        }
        .alert("settings.controller.replaceConfirm.title", isPresented: isConfirmingReplacement,
               presenting: viewModel.replacementCandidate) { candidate in
            Button("settings.controller.replaceConfirm.replace", role: .destructive) {
                viewModel.applyReplacement(candidate)
            }
            Button("button.Cancel", role: .cancel) {}
        } message: { _ in
            Text("settings.controller.replaceConfirm.message")
        }
    }

    // Controller presets: the alert is shown while a replacement waits; dismissing drops it
    private var isConfirmingReplacement: Binding<Bool> {
        Binding(get: { viewModel.replacementCandidate != nil },
                set: { isPresented in
                    if !isPresented { viewModel.replacementCandidate = nil }
                })
    }

    // Mouse and Esc behaviour stays Apple's and is shown read-only
    private var fixedInputs: some View {
        GroupBox {
            VStack(alignment: .leading) {
                Text("settings.controller.fixed.mouseClick")
                Text("settings.controller.fixed.mouseMove")
                Text("settings.controller.fixed.esc")
            }
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("settings.controller.group.fixed")
        }
    }

    private func inputGroup(_ group: EmulatedControllerGroup,
                            keysByInput: [EmulatedControllerInput: [Int]]) -> some View {
        GroupBox {
            VStack(alignment: .leading) {
                // Controller combos: recording and hints are addressed by row target
                ForEach(group.inputs, id: \.self) { input in
                    EmulatedControllerRow(input: input,
                                          keys: keysByInput[input] ?? [],
                                          isRecording: viewModel.recordingTarget == .input(input),
                                          hint: viewModel.hintText(for: .input(input)),
                                          onRecord: { viewModel.toggleRecording(for: .input(input)) },
                                          onRemove: { key in viewModel.removeKey(key) })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(LocalizedStringKey(group.localizationKey))
        }
    }
}

// Controller emulation mapping: one input row with its key chips and a record button
struct EmulatedControllerRow: View {
    // Controller combos: wide enough for the dual Xbox / PlayStation labels, shared with the combo picker
    static let labelWidth: CGFloat = 170
    private static let iconWidth: CGFloat = 44

    let input: EmulatedControllerInput
    let keys: [Int]
    let isRecording: Bool
    let hint: String?
    let onRecord: () -> Void
    let onRemove: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Controller combos: input icons before the label; chips and record button shared with combo rows
            HStack {
                EmulatedControllerInputIcon(input: input)
                    .frame(width: Self.iconWidth, alignment: .leading)
                Text(LocalizedStringKey(input.localizationKey))
                    .frame(width: Self.labelWidth, alignment: .leading)
                // Controller key chips: icon + full name per key
                ForEach(keys, id: \.self) { key in
                    EmulatedControllerKeyChip(keys: [key]) {
                        onRemove(key)
                    }
                }
                Spacer()
                EmulatedControllerRecordButton(isRecording: isRecording,
                                               recordingTitle: "settings.controller.pressKey",
                                               recordHelp: "settings.controller.addKey",
                                               action: onRecord)
            }
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}
