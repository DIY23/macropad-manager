import Foundation
import Carbon.HIToolbox

// MARK: - Modifiers (CH57x protocol codes)

enum Modifier: String, Codable, CaseIterable, Identifiable {
    case ctrl, shift, alt, cmd, rctrl, rshift, ralt, rcmd
    var id: String { rawValue }

    /// Wire code in the K8850 0xFD protocol
    var code: UInt8 {
        switch self {
        case .ctrl:   return 0xF1
        case .shift:  return 0xF2
        case .alt:    return 0xF3
        case .cmd:    return 0xF4
        case .rctrl:  return 0xF5
        case .rshift: return 0xF6
        case .ralt:   return 0xF7
        case .rcmd:   return 0xF8
        }
    }

    var glyph: String {
        switch self {
        case .ctrl, .rctrl:   return "⌃"
        case .shift, .rshift: return "⇧"
        case .alt, .ralt:     return "⌥"
        case .cmd, .rcmd:     return "⌘"
        }
    }

    /// Normalised to the left-hand variant for sending: the pad has no way to
    /// express "right cmd" as a distinct chord from the user's point of view,
    /// so we keep the distinction only if it was explicitly recorded.
    var isRight: Bool {
        switch self {
        case .rctrl, .rshift, .ralt, .rcmd: return true
        default: return false
        }
    }
}

/// Canonical order so two equal sets produce identical byte streams.
let modifierOrder: [Modifier] = [.ctrl, .shift, .alt, .cmd, .rctrl, .rshift, .ralt, .rcmd]

// MARK: - Actions

struct Action: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case keystroke, media, mouse, none
        var id: String { rawValue }
        var title: String {
            switch self {
            case .keystroke: return "Keystroke"
            case .media:     return "Media key"
            case .mouse:     return "Mouse"
            case .none:      return "Nothing"
            }
        }
        var symbol: String {
            switch self {
            case .keystroke: return "keyboard"
            case .media:     return "speaker.wave.2"
            case .mouse:     return "computermouse"
            case .none:      return "minus.circle"
            }
        }
    }

    var kind: Kind = .none
    var modifiers: Set<Modifier> = []
    /// What the key should *produce*, not where it sits. A character is resolved
    /// to a key position against the target layout at write time, which is what
    /// makes a profile portable between QWERTY and AZERTY machines.
    var tokens: [KeyToken] = []
    var mediaKey: String = ""           // MediaKey.rawValue
    var mouseMode: String = "button"    // "button" | "wheel" — never both
    var mouseButton: String = "left"    // left | right | middle
    var wheelDirection: Int = -1        // -1 down, +1 up
    var wheelMultiplier: Int = 1
    var wheel: Int = 0                  // legacy: derived from mode when encoding
    var mouseModifiers: Set<Modifier> = []
    /// Optional user label drawn on the key face, Stream Deck style. When empty
    /// the key shows the shortcut itself.
    var label: String? = nil

    /// What the key face should say.
    var keyFace: String {
        if let l = label, !l.trimmingCharacters(in: .whitespaces).isEmpty { return l }
        return display
    }

    static let none = Action(kind: .none)

    var isEmpty: Bool { kind == .none }

    /// A mouse binding is either a click or a wheel turn, not both.
    var isWheel: Bool { mouseMode == "wheel" || (mouseMode.isEmpty && wheel != 0) }

    var wheelValue: Int { wheelMultiplier * (wheelDirection >= 0 ? 1 : -1) }

    /// Human label for the UI, e.g. "⌘⇧Z" or "Volume up".
    var display: String {
        switch kind {
        case .none: return "Nothing"
        case .media: return MediaKey(rawValue: mediaKey)?.title ?? mediaKey
        case .mouse:
            if isWheel {
                return "Wheel \(wheelDirection > 0 ? "up" : "down")" + (wheelMultiplier > 1 ? " ×\(wheelMultiplier)" : "")
            }
            return "\(mouseButton.capitalized) click"
        case .keystroke:
            if tokens.isEmpty { return "—" }
            let mods = modifierOrder.filter { modifiers.contains($0) }.map(\.glyph).joined()
            let shift = modifiers.contains(.shift) || modifiers.contains(.rshift)
            let resolver = LayoutContext.resolver
            let keys = tokens.map { t -> String in
                switch t.kind {
                case .character: return shift ? t.value.uppercased() : t.value
                case .usage:     return resolver.label(for: t.usageValue ?? 0, shift: shift)
                }
            }.joined(separator: " ")
            return mods + keys
        }
    }
}

// MARK: - Media keys (consumer usage codes used by the firmware)

enum MediaKey: String, Codable, CaseIterable, Identifiable {
    case volumeUp, volumeDown, mute, playPause, nextTrack, previousTrack, stop
    case brightnessUp, brightnessDown, calculator, screenLock
    var id: String { rawValue }

    var code: UInt16 {
        switch self {
        case .volumeUp:       return 0x00E9
        case .volumeDown:     return 0x00EA
        case .mute:           return 0x00E2
        case .playPause:      return 0x00CD
        case .nextTrack:      return 0x00B5
        case .previousTrack:  return 0x00B6
        case .stop:           return 0x00B7
        case .brightnessUp:   return 0x006F
        case .brightnessDown: return 0x0070
        case .calculator:     return 0x0192
        case .screenLock:     return 0x019E
        }
    }

    var title: String {
        switch self {
        case .volumeUp:       return "Volume up"
        case .volumeDown:     return "Volume down"
        case .mute:           return "Mute"
        case .playPause:      return "Play / pause"
        case .nextTrack:      return "Next track"
        case .previousTrack:  return "Previous track"
        case .stop:           return "Stop"
        case .brightnessUp:   return "Brightness up"
        case .brightnessDown: return "Brightness down"
        case .calculator:     return "Calculator"
        case .screenLock:     return "Lock screen"
        }
    }

    /// SF Symbol drawn on the key face, distinct per action.
    var symbol: String {
        switch self {
        case .volumeUp:       return "speaker.wave.3.fill"
        case .volumeDown:     return "speaker.wave.1.fill"
        case .mute:           return "speaker.slash.fill"
        case .playPause:      return "playpause.fill"
        case .nextTrack:      return "forward.fill"
        case .previousTrack:  return "backward.fill"
        case .stop:           return "stop.fill"
        case .brightnessUp:   return "sun.max.fill"
        case .brightnessDown: return "sun.min.fill"
        case .calculator:     return "plus.forwardslash.minus"
        case .screenLock:     return "lock.fill"
        }
    }
}

// MARK: - Physical controls

enum KnobPart: String, Codable, CaseIterable, Identifiable {
    case ccw, press, cw
    var id: String { rawValue }
    /// Firmware knob action index
    var index: UInt8 { switch self { case .ccw: return 0; case .press: return 1; case .cw: return 2 } }
    var title: String { switch self { case .ccw: return "Turn left"; case .press: return "Press"; case .cw: return "Turn right" } }
}

enum ControlID: Hashable, Codable, Identifiable {
    case button(Int)                 // 0-based, row-major
    case knob(Int, KnobPart)         // 0-based

    var id: String { stableKey }

    /// Persistence key. Deliberately device-agnostic so profiles survive a
    /// device-model change: "b12", "k0p".
    var stableKey: String {
        switch self {
        case .button(let n):        return "b\(n)"
        case .knob(let k, let p):   return "k\(k)\(p == .ccw ? "l" : p == .cw ? "r" : "p")"
        }
    }

    init?(stableKey: String) {
        guard let first = stableKey.first else { return nil }
        let rest = String(stableKey.dropFirst())
        if first == "b", let n = Int(rest) { self = .button(n); return }
        if first == "k" {
            let digits = rest.prefix { $0.isNumber }
            guard let k = Int(digits) else { return nil }
            guard let suffix = rest.last, rest.count > digits.count else { return nil }
            switch suffix {
            case "l": self = .knob(k, .ccw)
            case "r": self = .knob(k, .cw)
            case "p": self = .knob(k, .press)
            default: return nil
            }
            return
        }
        return nil
    }

    var title: String {
        switch self {
        case .button(let n):      return "Key \(n + 1)"
        case .knob(let k, let p): return "Knob \(k + 1) · \(p.title)"
        }
    }
}

// MARK: - Layers & profiles

struct Layer: Codable, Hashable {
    var name: String
    var bindings: [String: Action] = [:]

    func action(_ c: ControlID) -> Action { bindings[c.stableKey] ?? .none }
    mutating func set(_ c: ControlID, _ a: Action) {
        if a.isEmpty { bindings.removeValue(forKey: c.stableKey) }
        else { bindings[c.stableKey] = a }
    }
}

struct PadProfile: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var deviceModelID: String
    var layers: [Layer]
    var notes: String = ""
    var modified: Date = Date()

    static func empty(model: DeviceModel) -> PadProfile {
        let names = ["Layer 1", "Layer 2", "Layer 3"]
        return PadProfile(name: "Untitled",
                          deviceModelID: model.id,
                          layers: (0..<3).map { Layer(name: names[$0]) })
    }
}

// MARK: - Device models

struct KnobGeometry: Hashable {
    var diameterRatio: Double      // relative to a key
    var offsetRatio: Double = 0    // horizontal nudge
}

struct DeviceModel: Identifiable, Hashable {
    var id: String
    var displayName: String
    var vendorIDs: [UInt16]
    var productIDs: [UInt16]
    var rows: Int
    var columns: Int
    var knobs: [KnobGeometry]
    var knobOrientation: KnobOrientation
    var hasLayerLEDs: Bool
    var driverID: String
    var notes: String

    enum KnobOrientation: String, Hashable { case rightColumn, leftColumn, below, none }

    var buttonCount: Int { rows * columns }
    var knobCount: Int { knobs.count }

    func buttonTitle(_ index: Int) -> String { "Key \(index + 1)" }

    static let k8850 = DeviceModel(
        id: "ch57x-k8850",
        displayName: "K8850 Macropad",
        vendorIDs: [0x514C, 0x1189],
        productIDs: [0x8850],
        rows: 4, columns: 4,
        knobs: [KnobGeometry(diameterRatio: 0.92), KnobGeometry(diameterRatio: 0.92), KnobGeometry(diameterRatio: 1.26)],
        knobOrientation: .rightColumn,
        hasLayerLEDs: true,
        driverID: "ch57x-k8850",
        notes: "16 keys, 3 encoders (bottom one larger), 3 layers, tri-mode."
    )

    /// Placeholder models: declared so the registry and the UI are already
    /// device-agnostic, but with no driver behind them yet.
    static let ch57x12x2 = DeviceModel(
        id: "ch57x-12x2",
        displayName: "CH57x 12-key · 2 knobs",
        vendorIDs: [0x1189, 0x514C],
        productIDs: [0x8840, 0x8842, 0x8851],
        rows: 3, columns: 4,
        knobs: [KnobGeometry(diameterRatio: 0.95), KnobGeometry(diameterRatio: 0.95)],
        knobOrientation: .rightColumn,
        hasLayerLEDs: false,
        driverID: "ch57x-884x",
        notes: "Same family, different protocol framing. Driver not implemented yet."
    )

    static let all: [DeviceModel] = [.k8850, .ch57x12x2]

    static func model(forVendor v: UInt16, product p: UInt16) -> DeviceModel? {
        all.first { $0.vendorIDs.contains(v) && $0.productIDs.contains(p) }
    }
}

// MARK: - HID key names

enum KeyNames {
    static let table: [UInt8: String] = [
        0x04:"A",0x05:"B",0x06:"C",0x07:"D",0x08:"E",0x09:"F",0x0A:"G",0x0B:"H",
        0x0C:"I",0x0D:"J",0x0E:"K",0x0F:"L",0x10:"M",0x11:"N",0x12:"O",0x13:"P",
        0x14:"Q",0x15:"R",0x16:"S",0x17:"T",0x18:"U",0x19:"V",0x1A:"W",0x1B:"X",
        0x1C:"Y",0x1D:"Z",
        0x1E:"1",0x1F:"2",0x20:"3",0x21:"4",0x22:"5",0x23:"6",0x24:"7",0x25:"8",
        0x26:"9",0x27:"0",
        0x28:"↩",0x29:"esc",0x2A:"⌫",0x2B:"⇥",0x2C:"Space",0x2D:"-",0x2E:"=",
        0x2F:"[",0x30:"]",0x31:"\\",0x33:";",0x34:"'",0x35:"`",0x36:",",0x37:".",
        0x38:"/",0x39:"Caps",
        0x3A:"F1",0x3B:"F2",0x3C:"F3",0x3D:"F4",0x3E:"F5",0x3F:"F6",0x40:"F7",
        0x41:"F8",0x42:"F9",0x43:"F10",0x44:"F11",0x45:"F12",
        0x49:"Ins",0x4A:"Home",0x4B:"⇞",0x4C:"⌦",0x4D:"End",0x4E:"⇟",
        0x4F:"→",0x50:"←",0x51:"↓",0x52:"↑",
        0x68:"F13",0x69:"F14",0x6A:"F15",0x6B:"F16",0x6C:"F17",0x6D:"F18",
        0x6E:"F19",0x6F:"F20",0x70:"F21",0x71:"F22",0x72:"F23",0x73:"F24"
    ]
    static func label(for usage: UInt8) -> String { table[usage] ?? "0x" + String(format: "%02X", usage) }
}

/// A single keypress the pad should produce.
///
/// `.character` is the portable form: it names what the key should type, and is
/// resolved to a physical position against the target layout when writing.
/// `.usage` is for keys that have no character (arrows, F-keys, Esc, ⌫), which
/// sit at the same position on every layout.
struct KeyToken: Codable, Hashable {
    enum Kind: String, Codable { case character, usage }

    var kind: Kind
    var value: String

    static func char(_ s: String) -> KeyToken { KeyToken(kind: .character, value: s) }
    static func key(_ u: UInt8) -> KeyToken { KeyToken(kind: .usage, value: String(u)) }

    var usageValue: UInt8? { kind == .usage ? UInt8(value) : nil }
    var characterValue: String? { kind == .character ? value : nil }

    var display: String {
        switch kind {
        case .character: return value
        case .usage:     return KeyNames.label(for: usageValue ?? 0)
        }
    }
}

/// macOS virtual keycode -> HID usage. Layout independent: it describes the
/// physical key, which is exactly what a HID device emits.
enum VirtualKeyMap {
    static let table: [UInt16: UInt8] = [
        0:0x04, 1:0x16, 2:0x07, 3:0x09, 4:0x0B, 5:0x0A, 6:0x1D, 7:0x1B, 8:0x06, 9:0x19,
        11:0x05, 12:0x14, 13:0x1A, 14:0x08, 15:0x15, 16:0x1C, 17:0x17, 18:0x1E, 19:0x1F,
        20:0x20, 21:0x21, 22:0x23, 23:0x22, 24:0x2E, 25:0x26, 26:0x24, 27:0x2D, 28:0x25,
        29:0x27, 30:0x30, 31:0x12, 32:0x18, 33:0x2F, 34:0x0C, 35:0x13, 36:0x28, 37:0x0F,
        38:0x0D, 39:0x34, 40:0x0E, 41:0x33, 42:0x31, 43:0x36, 44:0x38, 45:0x11, 46:0x10,
        47:0x37, 48:0x2B, 49:0x2C, 50:0x35, 51:0x2A, 53:0x29,
        96:0x3E, 97:0x3F, 98:0x40, 99:0x3C, 100:0x41, 101:0x42, 103:0x44, 105:0x68,
        107:0x69, 109:0x43, 111:0x45, 113:0x6A,
        114:0x49, 115:0x4A, 116:0x4B, 117:0x4C, 118:0x3D, 119:0x4D, 120:0x3B, 121:0x4E,
        122:0x3A, 123:0x50, 124:0x4F, 125:0x51, 126:0x52
    ]
}
