import Foundation

// MARK: - Profile storage
//
// Profiles live in ~/Library/Application Support/MacroPad Manager/profiles/*.json
// One file per profile so the folder is browsable, greppable and sync-friendly.

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [PadProfile] = []
    @Published var activeProfileID: UUID?
    @Published private(set) var lastError: String?

    private let fm = FileManager.default

    var root: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("MacroPad Manager", isDirectory: true)
    }
    var profilesDir: URL { root.appendingPathComponent("profiles", isDirectory: true) }

    init() { load() }

    // MARK: disk

    private func ensureDirs() {
        try? fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
    }

    func load() {
        ensureDirs()
        guard let files = try? fm.contentsOfDirectory(at: profilesDir,
                                                      includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [PadProfile] = []
        for f in files where f.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: f) else { continue }
            if let p = try? decoder.decode(PadProfile.self, from: data) { loaded.append(p) }
        }
        profiles = loaded.sorted { $0.modified > $1.modified }
        if activeProfileID == nil { activeProfileID = profiles.first?.id }
        if profiles.isEmpty {
            let starter = StarterProfile.make()
            save(starter)
            activeProfileID = starter.id
        }
    }

    func save(_ profile: PadProfile) {
        ensureDirs()
        var p = profile
        p.modified = Date()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let url = profilesDir.appendingPathComponent("\(p.id.uuidString).json")
        do {
            try enc.encode(p).write(to: url, options: .atomic)
            if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p }
            else { profiles.insert(p, at: 0) }
            profiles.sort { $0.modified > $1.modified }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func delete(_ profile: PadProfile) {
        let url = profilesDir.appendingPathComponent("\(profile.id.uuidString).json")
        try? fm.removeItem(at: url)
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id { activeProfileID = profiles.first?.id }
    }

    func duplicate(_ profile: PadProfile) {
        var copy = profile
        copy.id = UUID()
        copy.name = profile.name + " copy"
        save(copy)
    }

    // MARK: import / export

    func export(_ profile: PadProfile, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(profile).write(to: url, options: .atomic)
    }

    func importProfile(from url: URL) throws {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var p = try dec.decode(PadProfile.self, from: Data(contentsOf: url))
        p.id = UUID()
        save(p)
        activeProfileID = p.id
    }
}

// MARK: - Starter profile
//
// Defaults are defined by CHARACTER and converted through the French AZERTY
// table, because that is the owner's layout. Recording a shortcut in the app
// does not use this table at all — it captures the physical keycode, which is
// layout independent and therefore always correct.

enum StarterProfile {
    static func make() -> PadProfile {
        var p = PadProfile.empty(model: .k8850)
        p.name = "Studio Default"

        for i in 0..<3 { p.layers[i].name = ["Editing", "Browser", "System"][i] }

        // Layer 1
        let l1: [(Int, String, [Modifier])] = [
            (0, "c", [.cmd]), (1, "v", [.cmd]), (2, "x", [.cmd]), (3, "z", [.cmd]),
            (4, "z", [.cmd, .shift]), (5, "a", [.cmd]), (6, "f", [.cmd]), (7, "s", [.cmd]),
        ]
        for (idx, ch, mods) in l1 {
            if let u = AZERTY.usage(for: ch) {
                p.layers[0].set(.button(idx), Action(kind: .keystroke, modifiers: Set(mods), usages: [u]))
            }
        }
        p.layers[0].set(.button(8), Action(kind: .keystroke, usages: [0x29]))   // esc
        p.layers[0].set(.button(9), Action(kind: .keystroke, usages: [0x28]))   // return
        p.layers[0].set(.button(10), Action(kind: .keystroke, usages: [0x2A]))  // delete
        p.layers[0].set(.button(11), Action(kind: .keystroke, modifiers: [.cmd], usages: [0x50])) // cmd-left
        p.layers[0].set(.button(12), Action(kind: .keystroke, modifiers: [.cmd], usages: [0x4F])) // cmd-right
        p.layers[0].set(.button(13), Action(kind: .keystroke, modifiers: [.cmd], usages: [0x2B])) // cmd-tab
        p.layers[0].set(.button(14), Action(kind: .keystroke, modifiers: [.cmd, .shift], usages: [0x2B]))
        p.layers[0].set(.button(15), Action(kind: .keystroke, modifiers: [.cmd, .shift], usages: [0x21])) // cmd-shift-4

        for k in 0..<3 { p.layers[0].set(.knob(k, .ccw), media(.volumeDown))
                         p.layers[0].set(.knob(k, .cw),  media(.volumeUp)) }
        p.layers[0].set(.knob(0, .press), media(.mute))
        p.layers[0].set(.knob(1, .ccw), media(.previousTrack))
        p.layers[0].set(.knob(1, .press), media(.playPause))
        p.layers[0].set(.knob(1, .cw), media(.nextTrack))
        p.layers[0].set(.knob(2, .ccw), Action(kind: .keystroke, modifiers: [.ctrl, .shift], usages: [0x2B]))
        p.layers[0].set(.knob(2, .press), Action(kind: .keystroke, usages: [0x29]))
        p.layers[0].set(.knob(2, .cw), Action(kind: .keystroke, modifiers: [.ctrl], usages: [0x2B]))

        // Layer 2 — browser
        let l2: [(Int, String, [Modifier])] = [
            (0, "t", [.cmd]), (1, "w", [.cmd]), (2, "t", [.cmd, .shift]), (3, "r", [.cmd]),
            (4, "r", [.cmd, .shift]), (5, "l", [.cmd]), (10, "d", [.cmd]), (11, "f", [.cmd]),
        ]
        for (idx, ch, mods) in l2 {
            if let u = AZERTY.usage(for: ch) {
                p.layers[1].set(.button(idx), Action(kind: .keystroke, modifiers: Set(mods), usages: [u]))
            }
        }
        p.layers[1].set(.button(6), Action(kind: .keystroke, modifiers: [.ctrl], usages: [0x2B]))
        p.layers[1].set(.button(7), Action(kind: .keystroke, modifiers: [.ctrl, .shift], usages: [0x2B]))
        p.layers[1].set(.button(13), Action(kind: .keystroke, usages: [0x29]))
        p.layers[1].set(.button(14), Action(kind: .keystroke, usages: [0x28]))
        p.layers[1].set(.button(15), Action(kind: .keystroke, modifiers: [.cmd, .shift], usages: [0x21]))

        // Layer 3 — system
        p.layers[2].set(.button(0), Action(kind: .keystroke, modifiers: [.ctrl], usages: [0x52]))
        p.layers[2].set(.button(1), Action(kind: .keystroke, modifiers: [.ctrl], usages: [0x51]))
        p.layers[2].set(.button(2), Action(kind: .keystroke, modifiers: [.cmd], usages: [0x2C]))
        p.layers[2].set(.button(3), Action(kind: .keystroke, modifiers: [.ctrl, .cmd],
                                           usages: [AZERTY.usage(for: "q") ?? 0x04]))
        p.layers[2].set(.button(4), Action(kind: .keystroke, modifiers: [.cmd, .shift], usages: [0x20]))
        p.layers[2].set(.button(5), Action(kind: .keystroke, modifiers: [.cmd, .shift], usages: [0x21]))
        p.layers[2].set(.button(6), Action(kind: .keystroke, modifiers: [.ctrl, .cmd], usages: [0x09]))
        p.layers[2].set(.button(7), Action(kind: .keystroke, modifiers: [.cmd], usages: [AZERTY.usage(for: "h") ?? 0x0B]))
        p.layers[2].set(.button(8), Action(kind: .keystroke, modifiers: [.cmd], usages: [AZERTY.usage(for: "m") ?? 0x10]))
        p.layers[2].set(.button(9), Action(kind: .keystroke, modifiers: [.cmd], usages: [0x2B]))
        p.layers[2].set(.button(10), Action(kind: .keystroke, modifiers: [.cmd, .shift], usages: [0x2B]))
        p.layers[2].set(.button(11), media(.brightnessDown))
        p.layers[2].set(.button(12), media(.brightnessUp))
        p.layers[2].set(.button(13), media(.mute))
        p.layers[2].set(.button(14), Action(kind: .keystroke, usages: [0x29]))
        p.layers[2].set(.button(15), Action(kind: .keystroke, usages: [0x28]))

        return p
    }

    static func media(_ m: MediaKey) -> Action {
        Action(kind: .media, mediaKey: m.rawValue)
    }
}

/// French AZERTY: character -> HID usage. Used only for authoring defaults and
/// for the "type a character" helper, never for shortcut recording.
enum AZERTY {
    static let table: [String: UInt8] = [
        "a":0x14, "z":0x1A, "e":0x08, "r":0x15, "t":0x17, "y":0x1C, "u":0x18,
        "i":0x0C, "o":0x12, "p":0x13, "q":0x04, "s":0x16, "d":0x07, "f":0x09,
        "g":0x0A, "h":0x0B, "j":0x0D, "k":0x0E, "l":0x0F, "m":0x33,
        "w":0x1D, "x":0x1B, "c":0x06, "v":0x19, "b":0x05, "n":0x11,
    ]
    static func usage(for ch: String) -> UInt8? { table[ch.lowercased()] }
}
