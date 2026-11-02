//
//  EmulatedControllerCombo.swift
//  PlayCover
//

import Foundation

// Controller combos: what a combo presses when its keys also have their own buttons
// (plist raw values; PlayTools reads the same strings)
enum EmulatedControllerComboPriority: String, CaseIterable {
    case combo = "Combo"
    case keys = "Keys"
    case both = "Both"

    var localizationKey: String { "settings.controller.combo.priority.\(self)" }
    var helpKey: String { "\(localizationKey).help" }
}

// Controller combos: controller inputs pressed together by one set of keyboard keys held together
struct EmulatedControllerCombo: Equatable {
    let keys: [Int]
    let inputs: [EmulatedControllerInput]
    var priority = EmulatedControllerComboPriority.combo

    // Shown between the inputs or keys of a combo, e.g. "L1 + R1"
    static let displaySeparator = " + "

    init<Keys: Sequence, Inputs: Sequence>(keys: Keys, inputs: Inputs,
                                           priority: EmulatedControllerComboPriority = .combo)
    where Keys.Element == Int, Inputs.Element == EmulatedControllerInput {
        self.keys = Set(keys).sorted()
        self.inputs = Self.sortedInputs(inputs)
        self.priority = priority
    }

    static func sortedInputs<Inputs: Sequence>(_ inputs: Inputs) -> [EmulatedControllerInput]
    where Inputs.Element == EmulatedControllerInput {
        Set(inputs).sorted { $0.rawValue < $1.rawValue }
    }
}

// Controller combos: the key sets of one input set, shown as one combo row (priority of its first entry)
struct EmulatedControllerComboGroup: Equatable {
    let inputs: [EmulatedControllerInput]
    var keySets: [[Int]]
    var priority = EmulatedControllerComboPriority.combo
}

// Controller combos: pure combo operations on the mapping (flat entries, one per key set)
extension EmulatedControllerMapping {
    // Controller combos: stored entries grouped by input set, in order of first appearance
    var comboGroups: [EmulatedControllerComboGroup] {
        var groups: [EmulatedControllerComboGroup] = []
        var groupIndexByInputs: [[EmulatedControllerInput]: Int] = [:]
        for combo in combos {
            if let index = groupIndexByInputs[combo.inputs] {
                groups[index].keySets.append(combo.keys)
            } else {
                groupIndexByInputs[combo.inputs] = groups.count
                groups.append(EmulatedControllerComboGroup(inputs: combo.inputs, keySets: [combo.keys],
                                                           priority: combo.priority))
            }
        }
        return groups
    }

    // Controller combos: add a key set to an input set (inheriting its priority);
    // returns the input set the key set was moved away from
    @discardableResult
    mutating func addComboKeys(_ keys: Set<Int>,
                               to inputs: [EmulatedControllerInput]) -> [EmulatedControllerInput]? {
        var combo = EmulatedControllerCombo(keys: keys, inputs: inputs)
        guard !combo.keys.isEmpty, !combo.inputs.isEmpty else { return nil }
        let index = combos.firstIndex { $0.keys == combo.keys }
        let previousInputs = index.map { combos[$0].inputs }
        guard previousInputs != combo.inputs else { return nil }
        if let index {
            combos.remove(at: index)
        }
        combo.priority = combos.first { $0.inputs == combo.inputs }?.priority ?? .combo
        combos.append(combo)
        return previousInputs
    }

    // Controller combos: every entry of one input set shares its priority
    mutating func setComboPriority(_ priority: EmulatedControllerComboPriority,
                                   for inputs: [EmulatedControllerInput]) {
        for index in combos.indices where combos[index].inputs == inputs {
            combos[index].priority = priority
        }
    }

    mutating func removeComboKeys(_ keys: [Int]) {
        combos.removeAll { $0.keys == keys }
    }

    mutating func removeCombo(inputs: [EmulatedControllerInput]) {
        combos.removeAll { $0.inputs == inputs }
    }
}

// Controller combos: plist entry {Keys: [Int], Inputs: [Int], Priority: String}; an invalid entry fails to decode
extension EmulatedControllerCombo: Codable {
    enum CodingKeys: String, CodingKey {
        case keys = "Keys"
        case inputs = "Inputs"
        case priority = "Priority"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedKeys = try container.decode([Int].self, forKey: .keys)
        let storedInputs = try container.decode([Int].self, forKey: .inputs)
        let validInputs = storedInputs.compactMap(EmulatedControllerInput.init(rawValue:))
        guard !storedKeys.isEmpty, storedKeys.allSatisfy({ $0 > 0 }),
              !storedInputs.isEmpty, validInputs.count == storedInputs.count else {
            throw DecodingError.dataCorruptedError(forKey: .inputs, in: container,
                                                   debugDescription: "Invalid controller combo")
        }
        // Controller combos: missing or unknown Priority (files from before the mode existed) = combo first
        let storedPriority = try? container.decodeIfPresent(String.self, forKey: .priority)
        self.init(keys: storedKeys, inputs: validInputs,
                  priority: storedPriority.flatMap(EmulatedControllerComboPriority.init(rawValue:)) ?? .combo)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keys, forKey: .keys)
        try container.encode(inputs.map(\.rawValue), forKey: .inputs)
        try container.encode(priority.rawValue, forKey: .priority)
    }
}

// Controller combos: decodes one Combos entry without failing the whole array (nil = invalid entry)
struct EmulatedControllerLossyCombo: Decodable {
    let combo: EmulatedControllerCombo?

    init(from decoder: Decoder) throws {
        combo = try? EmulatedControllerCombo(from: decoder)
    }
}

#if DEBUG
// Controller combos: assert-based check of the combo model, run from EmulatedControllerMapping.selfCheck()
extension EmulatedControllerMapping {
    // Controller combos: move semantics, grouping, shared priority, reset and plist round trip
    static func comboSelfCheck() {
        let shiftW: Set<Int> = [225, 26]
        let rKey: Set<Int> = [21]
        let shoulders: [EmulatedControllerInput] = [.leftShoulder, .rightShoulder]
        var mapping = EmulatedControllerMapping.seeded
        // Keys and inputs are stored sorted and unique
        assert(mapping.addComboKeys(shiftW, to: [.rightShoulder, .leftShoulder, .rightShoulder]) == nil)
        assert(mapping.combos == [EmulatedControllerCombo(keys: [26, 225], inputs: shoulders)])
        assert(mapping.addComboKeys(shiftW, to: shoulders) == nil)
        assert(mapping.addComboKeys(rKey, to: [.buttonX]) == nil)
        assert(mapping.addComboKeys(rKey, to: shoulders) == [.buttonX])
        assert(mapping.comboGroups == [EmulatedControllerComboGroup(inputs: shoulders, keySets: [[26, 225], [21]])])
        // Priority is shared by every entry of a combo and inherited by a newly added key set
        mapping.setComboPriority(.both, for: shoulders)
        assert(mapping.addComboKeys([22], to: shoulders) == nil)
        assert(mapping.combos.allSatisfy { $0.priority == .both })
        assert(mapping.comboGroups.first?.priority == .both)
        mapping.removeComboKeys([22])
        mapping.addComboKeys([6], to: [.buttonA])
        mapping.removeComboKeys([21])
        assert(mapping.combos.count == 2)
        mapping.resetToAppleDefault()
        assert(mapping.combos.count == 2)
        let encoded = try? PropertyListEncoder().encode(mapping)
        let decoded = encoded.flatMap { try? PropertyListDecoder().decode(EmulatedControllerMapping.self, from: $0) }
        assert(decoded == mapping)
        mapping.removeCombo(inputs: shoulders)
        assert(mapping.combos == [EmulatedControllerCombo(keys: [6], inputs: [.buttonA])])
        comboFileSelfCheck()
    }

    // Controller combos: invalid entries dropped, Priority default, old files without Combos
    private static func comboFileSelfCheck() {
        // Empty, unknown input, non-positive usage and repeated key set entries are dropped
        let storedCombos: [[String: Any]] = [
            ["Keys": [6], "Inputs": [0, 4]], ["Keys": [Int](), "Inputs": [4]], ["Keys": [7], "Inputs": [25]],
            ["Keys": [0], "Inputs": [4]], ["Keys": [6], "Inputs": [5]], ["Keys": ["W"], "Inputs": [4]]
        ]
        let fromFile = decodedSelfCheckFile(["Combos": storedCombos])
        assert(fromFile?.combos == [EmulatedControllerCombo(keys: [6], inputs: [.dpadUp, .buttonA])])
        // Missing or unknown Priority decodes as combo first
        let prioritized: [[String: Any]] = [["Keys": [6], "Inputs": [4], "Priority": "Keys"],
                                            ["Keys": [7], "Inputs": [5], "Priority": "Later"]]
        assert(decodedSelfCheckFile(["Combos": prioritized])?.combos.map(\.priority) == [.keys, .combo])
        // A file written before combos existed has none
        assert(decodedSelfCheckFile(["Enabled": true])?.combos == [])
    }

    private static func decodedSelfCheckFile(_ plist: Any?) -> EmulatedControllerMapping? {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist ?? [:], format: .xml, options: 0)
            return try PropertyListDecoder().decode(EmulatedControllerMapping.self, from: data)
        } catch {
            assertionFailure("Controller combo self check decode failed: \(error)")
            return nil
        }
    }
}
#endif
