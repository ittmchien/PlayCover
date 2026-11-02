//
//  EmulatedControllerComboView.swift
//  PlayCover
//

import AppKit
import SwiftUI

// Controller combos: Apple's SF Symbols of an input on an Xbox and a PlayStation controller
extension EmulatedControllerInput {
    // swiftlint:disable:next cyclomatic_complexity
    var symbolNames: (xbox: String, playStation: String) {
        switch self {
        case .dpadUp: return ("dpad.up.fill", "dpad.up.fill")
        case .dpadDown: return ("dpad.down.fill", "dpad.down.fill")
        case .dpadLeft: return ("dpad.left.fill", "dpad.left.fill")
        case .dpadRight: return ("dpad.right.fill", "dpad.right.fill")
        case .buttonA: return ("a.circle", "xmark.circle")
        case .buttonB: return ("b.circle", "circle.circle")
        case .buttonX: return ("x.circle", "square.circle")
        case .buttonY: return ("y.circle", "triangle.circle")
        case .leftShoulder: return ("lb.rectangle.roundedbottom", "l1.rectangle.roundedbottom")
        case .rightShoulder: return ("rb.rectangle.roundedbottom", "r1.rectangle.roundedbottom")
        case .leftTrigger: return ("lt.rectangle.roundedtop", "l2.rectangle.roundedtop")
        case .rightTrigger: return ("rt.rectangle.roundedtop", "r2.rectangle.roundedtop")
        case .leftStickUp: return ("l.joystick.tilt.up", "l.joystick.tilt.up")
        case .leftStickDown: return ("l.joystick.tilt.down", "l.joystick.tilt.down")
        case .leftStickLeft: return ("l.joystick.tilt.left", "l.joystick.tilt.left")
        case .leftStickRight: return ("l.joystick.tilt.right", "l.joystick.tilt.right")
        case .rightStickUp: return ("r.joystick.tilt.up", "r.joystick.tilt.up")
        case .rightStickDown: return ("r.joystick.tilt.down", "r.joystick.tilt.down")
        case .rightStickLeft: return ("r.joystick.tilt.left", "r.joystick.tilt.left")
        case .rightStickRight: return ("r.joystick.tilt.right", "r.joystick.tilt.right")
        case .leftStickButton: return ("l.joystick.down", "l.joystick.down")
        case .rightStickButton: return ("r.joystick.press.down", "r.joystick.press.down")
        case .home: return ("logo.xbox", "logo.playstation")
        // Both names draw the same glyph (line.3.horizontal.circle is an alias), so one name lets the icon dedupe
        case .menu: return ("line.horizontal.3.circle", "line.horizontal.3.circle")
        case .options: return ("rectangle.fill.on.rectangle.fill.circle", "square.and.arrow.up.circle")
        }
    }

    // Used when a symbol is missing on older macOS (stick tilt symbols need macOS 13)
    var fallbackSymbolName: String {
        switch self {
        case .leftStickUp, .leftStickDown, .leftStickLeft, .leftStickRight: return "l.joystick"
        case .rightStickUp, .rightStickDown, .rightStickLeft, .rightStickRight: return "r.joystick"
        default: return EmulatedControllerInputIcon.genericSymbolName
        }
    }
}

// Controller combos: Xbox and PlayStation icons of an input (once when both are the same), tooltip = its name
struct EmulatedControllerInputIcon: View {
    static let genericSymbolName = "gamecontroller"
    private static let iconSpacing: CGFloat = 2

    // Resolved once: symbol availability never changes while PlayCover runs
    private static let symbolNamesByInput: [EmulatedControllerInput: [String]] = Dictionary(
        uniqueKeysWithValues: EmulatedControllerInput.allCases.map { input in
            let names = [input.symbolNames.xbox, input.symbolNames.playStation].map { name in
                [name, input.fallbackSymbolName].first(where: isAvailable) ?? genericSymbolName
            }
            return (input, names[0] == names[1] ? [names[0]] : names)
        })

    let input: EmulatedControllerInput

    var body: some View {
        HStack(spacing: Self.iconSpacing) {
            ForEach(Self.symbolNamesByInput[input] ?? [Self.genericSymbolName], id: \.self) { name in
                Image(systemName: name)
            }
        }
        .help(input.localizedName)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(input.localizedName)
    }

    // Controller key chips: shared with the key labels
    static func isAvailable(_ symbolName: String) -> Bool {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) != nil
    }
}

// Controller combos: "+" record button that shows a prompt while recording (click again cancels)
struct EmulatedControllerRecordButton: View {
    let isRecording: Bool
    let recordingTitle: LocalizedStringKey
    let recordHelp: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isRecording {
                Text(recordingTitle)
            } else {
                Image(systemName: "plus")
            }
        }
        .help(isRecording ? "settings.controller.cancelRecording" : recordHelp)
    }
}

// Controller combos: "Combos" box with the combo rows, the inline input picker and the delete confirmation
struct EmulatedControllerCombosSection: View {
    @ObservedObject var viewModel: EmulatedControllerVM
    @State private var isPickingInputs = false
    @State private var comboPendingDeletion: [EmulatedControllerInput]?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading) {
                Text("settings.controller.combo.help")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(viewModel.comboGroups, id: \.inputs) { group in
                    comboRow(group)
                }
                if isPickingInputs {
                    EmulatedControllerComboPicker(onCreate: { inputs in
                        isPickingInputs = false
                        viewModel.startCombo(with: inputs)
                    }, onCancel: {
                        isPickingInputs = false
                    })
                } else {
                    Button("settings.controller.combo.add") {
                        isPickingInputs = true
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("settings.controller.group.combos")
        }
        .alert("settings.controller.combo.deleteConfirm.title", isPresented: isConfirmingDeletion) {
            Button("settings.controller.combo.deleteConfirm.delete", role: .destructive) {
                guard let comboPendingDeletion else { return }
                viewModel.deleteCombo(comboPendingDeletion)
            }
            Button("button.Cancel", role: .cancel) {}
        } message: {
            Text("settings.controller.combo.deleteConfirm.message")
        }
    }

    private var isConfirmingDeletion: Binding<Bool> {
        Binding(get: { comboPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented { comboPendingDeletion = nil }
                })
    }

    // A pending combo has no key sets yet, so deleting it only cancels its recording
    private func comboRow(_ group: EmulatedControllerComboGroup) -> some View {
        let target = EmulatedControllerVM.RowTarget.combo(group.inputs)
        return EmulatedControllerComboRow(group: group,
                                          isRecording: viewModel.recordingTarget == target,
                                          hint: viewModel.hintText(for: target),
                                          onRecord: { viewModel.toggleRecording(for: target) },
                                          onRemoveKeys: { keys in viewModel.removeComboKeys(keys) },
                                          onPriorityChange: { priority in
                                              viewModel.setComboPriority(priority, for: group.inputs)
                                          },
                                          onDelete: {
                                              if group.keySets.isEmpty {
                                                  viewModel.stopRecording()
                                              } else {
                                                  comboPendingDeletion = group.inputs
                                              }
                                          })
    }
}

// Controller combos: inline picker of the inputs a new combo presses together, grouped like the input list
struct EmulatedControllerComboPicker: View {
    let onCreate: (Set<EmulatedControllerInput>) -> Void
    let onCancel: () -> Void
    @State private var selectedInputs: Set<EmulatedControllerInput> = []

    var body: some View {
        VStack(alignment: .leading) {
            Text("settings.controller.combo.pickInputs")
                .font(.caption)
                .foregroundColor(.secondary)
            ForEach(EmulatedControllerGroup.allCases, id: \.self) { group in
                HStack {
                    Text(LocalizedStringKey(group.localizationKey))
                        .frame(width: EmulatedControllerRow.labelWidth, alignment: .leading)
                    ForEach(group.inputs, id: \.self) { input in
                        Toggle(isOn: isSelected(input)) {
                            EmulatedControllerInputIcon(input: input)
                        }
                        .toggleStyle(.button)
                    }
                }
            }
            HStack {
                Button("button.Cancel", action: onCancel)
                Button("settings.controller.combo.create") {
                    onCreate(selectedInputs)
                }
                .disabled(selectedInputs.isEmpty)
            }
        }
    }

    private func isSelected(_ input: EmulatedControllerInput) -> Binding<Bool> {
        Binding(get: { selectedInputs.contains(input) },
                set: { isOn in
                    if isOn {
                        selectedInputs.insert(input)
                    } else {
                        selectedInputs.remove(input)
                    }
                })
    }
}

// Controller combos: one combo row with its input icons, key-set chips, record and delete buttons
struct EmulatedControllerComboRow: View {
    // HID keyboard usages of Left/Right Control, Shift, Option and Command, listed first in a key set
    private static let modifierUsages = 224...231

    let group: EmulatedControllerComboGroup
    let isRecording: Bool
    let hint: String?
    let onRecord: () -> Void
    let onRemoveKeys: ([Int]) -> Void
    let onPriorityChange: (EmulatedControllerComboPriority) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                HStack {
                    ForEach(group.inputs, id: \.self) { input in
                        EmulatedControllerInputIcon(input: input)
                    }
                }
                .frame(minWidth: EmulatedControllerRow.labelWidth, alignment: .leading)
                // Controller key chips: icon + full name per key
                ForEach(group.keySets, id: \.self) { keys in
                    EmulatedControllerKeyChip(keys: Self.modifiersFirst(keys)) {
                        onRemoveKeys(keys)
                    }
                }
                Spacer()
                priorityPicker
                EmulatedControllerRecordButton(isRecording: isRecording,
                                               recordingTitle: "settings.controller.combo.pressKeys",
                                               recordHelp: "settings.controller.combo.addKeys",
                                               action: onRecord)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .help("settings.controller.combo.delete")
            }
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // Controller combos: conflict mode of the whole combo; a pending combo (no key set yet) keeps the default
    private var priorityPicker: some View {
        let selection = Binding(get: { group.priority }, set: onPriorityChange)
        return Picker("settings.controller.combo.priority", selection: selection) {
            ForEach(EmulatedControllerComboPriority.allCases, id: \.self) { priority in
                Text(LocalizedStringKey(priority.localizationKey))
                    .help(LocalizedStringKey(priority.helpKey))
                    .tag(priority)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .help(LocalizedStringKey(group.priority.helpKey))
        .disabled(group.keySets.isEmpty)
    }

    // Controller key chips: key set shown modifiers first, e.g. Left Shift + W
    private static func modifiersFirst(_ keys: [Int]) -> [Int] {
        keys.filter { modifierUsages.contains($0) } + keys.filter { !modifierUsages.contains($0) }
    }
}
