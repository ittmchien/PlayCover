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
                ForEach(group.inputs, id: \.self) { input in
                    EmulatedControllerRow(input: input,
                                          keys: keysByInput[input] ?? [],
                                          isRecording: viewModel.recordingInput == input,
                                          hint: viewModel.hintText(for: input),
                                          onRecord: { viewModel.toggleRecording(for: input) },
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
    private static let labelWidth: CGFloat = 140
    private static let chipCornerRadius: CGFloat = 6
    private static let chipHorizontalPadding: CGFloat = 6
    private static let chipVerticalPadding: CGFloat = 2
    private static let chipBackgroundOpacity = 0.2

    let input: EmulatedControllerInput
    let keys: [Int]
    let isRecording: Bool
    let hint: String?
    let onRecord: () -> Void
    let onRemove: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(LocalizedStringKey(input.localizationKey))
                    .frame(width: Self.labelWidth, alignment: .leading)
                ForEach(keys, id: \.self) { key in
                    keyChip(key)
                }
                Spacer()
                recordButton
            }
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var recordButton: some View {
        let helpKey: LocalizedStringKey = isRecording
            ? "settings.controller.cancelRecording"
            : "settings.controller.addKey"
        return Button(action: onRecord) {
            if isRecording {
                Text("settings.controller.pressKey")
            } else {
                Image(systemName: "plus")
            }
        }
        .help(helpKey)
    }

    private func keyChip(_ key: Int) -> some View {
        HStack(spacing: 2) {
            Text(verbatim: KeyCodeNames.displayName(forHIDUsage: key))
            Button {
                onRemove(key)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(BorderlessButtonStyle())
            .help("settings.controller.removeKey")
        }
        .padding(.horizontal, Self.chipHorizontalPadding)
        .padding(.vertical, Self.chipVerticalPadding)
        .background(RoundedRectangle(cornerRadius: Self.chipCornerRadius)
            .fill(Color.secondary.opacity(Self.chipBackgroundOpacity)))
    }
}
