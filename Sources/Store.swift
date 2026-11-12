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
        // Lets tests and screenshots run against a throwaway store without
        // touching the real one.
        if let override = ProcessInfo.processInfo.environment["MPM_SUPPORT_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
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
// Defaults are written as CHARACTERS, not key positions, so the same profile
// works on a QWERTY Mac and on this Belgian AZERTY one: the resolver maps each
// character to whatever physical key produces it on the target layout.

enum StarterProfile {
    static func make() -> PadProfile {
        var p = PadProfile.empty(model: .k8850)
        p.name = "Studio Default"
        for i in 0..<3 { p.layers[i].name = ["Editing", "Browser", "System"][i] }

        func ks(_ layer: Int, _ c: ControlID, _ mods: Set<Modifier>, _ tokens: [KeyToken]) {
            p.layers[layer].set(c, Action(kind: .keystroke, modifiers: mods, tokens: tokens))
        }
        func md(_ layer: Int, _ c: ControlID, _ m: MediaKey) {
            p.layers[layer].set(c, Action(kind: .media, mediaKey: m.rawValue))
        }

        // Layer 1 - editing and navigation
        ks(0, .button(0), [.cmd], [.char("c")])
        ks(0, .button(1), [.cmd], [.char("v")])
        ks(0, .button(2), [.cmd], [.char("x")])
        ks(0, .button(3), [.cmd], [.char("z")])
        ks(0, .button(4), [.cmd, .shift], [.char("z")])
        ks(0, .button(5), [.cmd], [.char("a")])
        ks(0, .button(6), [.cmd], [.char("f")])
        ks(0, .button(7), [.cmd], [.char("s")])
        ks(0, .button(8), [], [.key(0x29)])
        ks(0, .button(9), [], [.key(0x28)])
        ks(0, .button(10), [], [.key(0x2A)])
        ks(0, .button(11), [.cmd], [.key(0x50)])
        ks(0, .button(12), [.cmd], [.key(0x4F)])
        ks(0, .button(13), [.cmd], [.key(0x2B)])
        ks(0, .button(14), [.cmd, .shift], [.key(0x2B)])
        ks(0, .button(15), [.cmd, .shift], [.char("4")])

        md(0, .knob(0, .ccw), .volumeDown)
        md(0, .knob(0, .press), .mute)
        md(0, .knob(0, .cw), .volumeUp)
        md(0, .knob(1, .ccw), .previousTrack)
        md(0, .knob(1, .press), .playPause)
        md(0, .knob(1, .cw), .nextTrack)
        ks(0, .knob(2, .ccw), [.ctrl, .shift], [.key(0x2B)])
        ks(0, .knob(2, .press), [], [.key(0x29)])
        ks(0, .knob(2, .cw), [.ctrl], [.key(0x2B)])

        // Layer 2 - browser
        ks(1, .button(0), [.cmd], [.char("t")])
        ks(1, .button(1), [.cmd], [.char("w")])
        ks(1, .button(2), [.cmd, .shift], [.char("t")])
        ks(1, .button(3), [.cmd], [.char("r")])
        ks(1, .button(4), [.cmd, .shift], [.char("r")])
        ks(1, .button(5), [.cmd], [.char("l")])
        ks(1, .button(6), [.ctrl], [.key(0x2B)])
        ks(1, .button(7), [.ctrl, .shift], [.key(0x2B)])
        ks(1, .button(8), [.cmd], [.char("d")])
        ks(1, .button(9), [.cmd], [.char("f")])
        ks(1, .button(13), [], [.key(0x29)])
        ks(1, .button(14), [], [.key(0x28)])
        ks(1, .button(15), [.cmd, .shift], [.char("4")])
        ks(1, .knob(0, .ccw), [.ctrl, .shift], [.key(0x2B)])
        ks(1, .knob(0, .press), [], [.key(0x29)])
        ks(1, .knob(0, .cw), [.ctrl], [.key(0x2B)])
        md(1, .knob(1, .ccw), .volumeDown)
        md(1, .knob(1, .press), .mute)
        md(1, .knob(1, .cw), .volumeUp)
        ks(1, .knob(2, .ccw), [], [.key(0x4B)])
        ks(1, .knob(2, .press), [], [.key(0x29)])
        ks(1, .knob(2, .cw), [], [.key(0x4E)])

        // Layer 3 - window and system
        ks(2, .button(0), [.ctrl], [.key(0x52)])
        ks(2, .button(1), [.ctrl], [.key(0x51)])
        ks(2, .button(2), [.cmd], [.key(0x2C)])
        ks(2, .button(3), [.ctrl, .cmd], [.char("q")])
        ks(2, .button(4), [.cmd, .shift], [.char("3")])
        ks(2, .button(5), [.cmd, .shift], [.char("4")])
        ks(2, .button(6), [.ctrl, .cmd], [.char("f")])
        ks(2, .button(7), [.cmd], [.char("h")])
        ks(2, .button(8), [.cmd], [.char("m")])
        ks(2, .button(9), [.cmd], [.key(0x2B)])
        ks(2, .button(10), [.cmd, .shift], [.key(0x2B)])
        md(2, .button(11), .brightnessDown)
        md(2, .button(12), .brightnessUp)
        md(2, .button(13), .mute)
        ks(2, .button(14), [], [.key(0x29)])
        ks(2, .button(15), [], [.key(0x28)])

        md(2, .knob(0, .ccw), .volumeDown)
        md(2, .knob(0, .press), .mute)
        md(2, .knob(0, .cw), .volumeUp)
        md(2, .knob(1, .ccw), .previousTrack)
        md(2, .knob(1, .press), .playPause)
        md(2, .knob(1, .cw), .nextTrack)
        ks(2, .knob(2, .ccw), [.ctrl], [.key(0x2B)])
        ks(2, .knob(2, .press), [], [.key(0x29)])
        ks(2, .knob(2, .cw), [.ctrl, .shift], [.key(0x2B)])

        return p
    }
}
