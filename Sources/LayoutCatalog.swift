import Foundation
import Carbon.HIToolbox

// MARK: - Installed keyboard layouts

struct LayoutDescriptor: Identifiable, Hashable {
    let id: String          // com.apple.keylayout.Belgian
    let name: String        // Belgian
    let enabled: Bool       // currently an active input source on this Mac
}

enum KeyboardLayouts {

    private static func descriptors(includeAll: Bool) -> [LayoutDescriptor] {
        let opts = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource] as CFDictionary
        guard let list = TISCreateInputSourceList(opts, includeAll)?.takeRetainedValue() as? [TISInputSource]
        else { return [] }

        var out: [LayoutDescriptor] = []
        var seen = Set<String>()
        for src in list {
            guard let raw = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
            // Only layouts that actually carry key layout data can be translated.
            guard TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) != nil else { continue }
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            let name = (TISGetInputSourceProperty(src, kTISPropertyLocalizedName).map {
                Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
            }) ?? id
            out.append(LayoutDescriptor(id: id, name: name, enabled: !includeAll))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Every installed layout that can be used as a target.
    static func all() -> [LayoutDescriptor] { descriptors(includeAll: true) }

    /// Layouts the user has actually enabled in System Settings.
    static func enabled() -> [LayoutDescriptor] { descriptors(includeAll: false) }

    static func currentID() -> String {
        if let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let raw = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) {
            return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        }
        return "com.apple.keylayout.US"
    }

    static func name(for id: String) -> String {
        all().first { $0.id == id }?.name ?? id
    }

    static func layoutData(for id: String) -> Data? {
        let opts = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource] as CFDictionary
        guard let list = TISCreateInputSourceList(opts, true)?.takeRetainedValue() as? [TISInputSource]
        else { return nil }
        for src in list {
            guard let raw = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { continue }
            let sid = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
            guard sid == id,
                  let dataPtr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData)
            else { continue }
            return Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue() as Data
        }
        return nil
    }
}

// MARK: - Character <-> key position for one layout

/// Resolves between the *character* a shortcut means and the *physical key
/// position* the pad has to send. macOS shortcuts are matched on the character,
/// while a HID device can only send a position, so this translation is what
/// makes one profile work on a QWERTY Mac and an AZERTY Mac alike.
final class LayoutResolver {

    struct Entry {
        let usage: UInt8
        let needsShift: Bool
        let needsOption: Bool
    }

    let id: String
    private var charToEntry: [String: Entry] = [:]
    private var usageToChar: [UInt8: String] = [:]

    init(id: String) {
        self.id = id
        guard let data = KeyboardLayouts.layoutData(for: id) else { return }

        data.withUnsafeBytes { buffer in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            for (usage, vk) in Self.usageToVK {
                // Order matters: unshifted wins, then shift, then option.
                let states: [(UInt32, Bool, Bool)] = [(0, false, false), (0x02, true, false),
                                                      (0x08, false, true), (0x0A, true, true)]
                for (state, shift, option) in states {
                    guard let s = Self.translate(layout, vk, state), s.count == 1 else { continue }
                    if charToEntry[s] == nil { charToEntry[s] = Entry(usage: usage, needsShift: shift, needsOption: option) }
                    if state == 0, usageToChar[usage] == nil { usageToChar[usage] = s }
                }
            }
        }
    }

    private static let usageToVK: [(UInt8, UInt16)] = {
        var seen = Set<UInt8>()
        var out: [(UInt8, UInt16)] = []
        for (vk, usage) in VirtualKeyMap.table.sorted(by: { $0.value < $1.value }) where !seen.contains(usage) {
            seen.insert(usage)
            out.append((usage, vk))
        }
        return out
    }()

    private static func translate(_ layout: UnsafePointer<UCKeyboardLayout>, _ vk: UInt16, _ state: UInt32) -> String? {
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let err = UCKeyTranslate(layout, vk, UInt16(kUCKeyActionDisplay), state, 0,
                                 OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        guard err == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        guard let f = s.first,
              !f.isNewline,
              !(f.unicodeScalars.first.map { CharacterSet.controlCharacters.contains($0) } ?? true)
        else { return nil }
        return s
    }

    // MARK: queries

    /// The character this physical key produces on this layout, ignoring modifiers.
    func character(for usage: UInt8) -> String? { usageToChar[usage] }

    /// Label for a control, honouring a Shift that is part of the shortcut.
    func label(for usage: UInt8, shift: Bool) -> String {
        guard let base = usageToChar[usage] else { return KeyNames.label(for: usage) }
        return shift ? base.uppercased() : base
    }

    /// Resolve the character a shortcut should produce into a key position plus
    /// any extra modifiers that character needs on this layout (e.g. on AZERTY
    /// the digit "4" lives on Shift + the "'" key).
    func resolve(character: String) -> Entry? {
        if let e = charToEntry[character] { return e }
        let lower = character.lowercased()
        if let e = charToEntry[lower] { return e }
        return charToEntry[character.uppercased()]
    }

    var isUsable: Bool { !charToEntry.isEmpty }
}

// MARK: - Active resolver (target layout)

enum LayoutContext {
    private static var cache: [String: LayoutResolver] = [:]
    private static var activeID: String = KeyboardLayouts.currentID()

    static var targetID: String {
        get { activeID }
        set {
            activeID = newValue
            if cache[newValue] == nil { cache[newValue] = LayoutResolver(id: newValue) }
        }
    }

    static var resolver: LayoutResolver {
        if let r = cache[activeID] { return r }
        let r = LayoutResolver(id: activeID)
        cache[activeID] = r
        return r
    }

    static func resolver(for id: String) -> LayoutResolver {
        if let r = cache[id] { return r }
        let r = LayoutResolver(id: id)
        cache[id] = r
        return r
    }
}
