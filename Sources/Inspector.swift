import SwiftUI
import AppKit

// MARK: - Inspector

struct InspectorView: View {
    @EnvironmentObject var app: AppState
    @State private var recording = false

    var control: ControlID? { app.selection }
    var action: Action { control.map { app.action($0) } ?? .none }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                knobPicker

                VStack(alignment: .leading, spacing: 8) {
                    label("ACTION")
                    VStack(spacing: 0) {
                        ForEach(Action.Kind.allCases) { kind in
                            Button {
                                setKind(kind)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: kind.symbol)
                                        .font(.system(size: 11)).frame(width: 16)
                                    Text(kind.title).font(.system(size: 12))
                                    Spacer()
                                    if action.kind == kind {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(SidebarView.green)
                                    }
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 10).padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                            .background(action.kind == kind ? Color.primary.opacity(0.06) : Color.clear)
                            if kind != Action.Kind.allCases.last { Divider().padding(.leading, 34) }
                        }
                    }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(.white.opacity(0.08)))
                }

                switch action.kind {
                case .keystroke: keystrokeEditor
                case .media:     mediaEditor
                case .mouse:     mouseEditor
                case .none:      EmptyView()
                }

                if action.kind != .none { labelEditor }

                if control != nil {
                    Button(role: .destructive) {
                        if let c = control { app.set(c, .none) }
                    } label: {
                        Label("Clear this control", systemImage: "eraser")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
        }
        .background(.ultraThinMaterial)
        .sheet(isPresented: $recording) {
            if let c = control {
                RecorderSheet { captured in app.set(c, captured) }
            }
        }
    }

    /// Knobs have three separately programmable actions; without this you could
    /// only ever reach "press" by clicking.
    @ViewBuilder var knobPicker: some View {
        if case .knob(let k, let part)? = app.selection {
            Picker("", selection: Binding(
                get: { part },
                set: { app.selection = .knob(k, $0) })) {
                Text("⟲ Left").tag(KnobPart.ccw)
                Text("Press").tag(KnobPart.press)
                Text("Right ⟳").tag(KnobPart.cw)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// Free text drawn on the key face instead of the shortcut — the Stream Deck
    /// convention: label by intent, not by key combination.
    var labelEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("KEY LABEL")
            TextField(action.display, text: Binding(
                get: { action.label ?? "" },
                set: { v in
                    guard let c = control else { return }
                    var a = action
                    let t = v.trimmingCharacters(in: .whitespaces)
                    a.label = t.isEmpty ? nil : v
                    app.set(c, a)
                }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            Text("Shown on the key. Leave empty to show the shortcut.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(control?.title ?? "Nothing selected")
                .font(.system(size: 17, weight: .semibold))
            Text("\(app.profile.layers.indices.contains(app.layerIndex) ? app.profile.layers[app.layerIndex].name : "Layer") · written to the device")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    var keystrokeEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("SHORTCUT")
            HStack(spacing: 5) {
                if action.tokens.isEmpty {
                    Text("Nothing recorded").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(modifierOrder.filter { action.modifiers.contains($0) }, id: \.self) { m in
                        Text(m.glyph)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.primary.opacity(0.09),
                                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    ForEach(Array(action.tokens.enumerated()), id: \.offset) { _, t in
                        Text(t.display.uppercased())
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.primary.opacity(0.09),
                                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            Button { recording = true } label: {
                Label("Record shortcut", systemImage: "record.circle")
                    .font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.small)

            if !action.modifiers.isEmpty || !action.tokens.isEmpty {
                Text("Sends \(action.display)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text("Recorded as characters, resolved to keys for the target layout.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)

            if let bad = unresolvedCharacter {
                Label("“\(bad)” cannot be typed on \(KeyboardLayouts.name(for: app.targetLayoutID))",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// First character token the target layout cannot produce, if any.
    var unresolvedCharacter: String? {
        guard action.kind == .keystroke else { return nil }
        let shift = action.modifiers.contains(.shift) || action.modifiers.contains(.rshift)
        let r = LayoutContext.resolver
        for t in action.tokens where t.kind == .character {
            let want = shift ? t.value.uppercased() : t.value
            if r.resolve(character: want) == nil { return t.value }
        }
        return nil
    }

    var mediaEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("MEDIA KEY")
            Picker("", selection: Binding(
                get: { action.mediaKey.isEmpty ? MediaKey.volumeUp.rawValue : action.mediaKey },
                set: { v in
                    guard let c = control else { return }
                    var a = action; a.kind = .media; a.mediaKey = v
                    app.set(c, a)
                })) {
                ForEach(MediaKey.allCases) { m in Text(m.title).tag(m.rawValue) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    var mouseEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("MOUSE")
            Picker("", selection: Binding(
                get: { action.isWheel ? "wheel" : "button" },
                set: { v in
                    guard let c = control else { return }
                    var a = action; a.kind = .mouse; a.mouseMode = v
                    app.set(c, a)
                })) {
                Text("Button").tag("button")
                Text("Wheel").tag("wheel")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if action.isWheel {
                Picker("", selection: Binding(
                    get: { action.wheelDirection >= 0 ? "up" : "down" },
                    set: { v in
                        guard let c = control else { return }
                        var a = action; a.kind = .mouse; a.mouseMode = "wheel"
                        a.wheelDirection = (v == "up") ? 1 : -1
                        app.set(c, a)
                    })) {
                    Label("Up", systemImage: "arrow.up").tag("up")
                    Label("Down", systemImage: "arrow.down").tag("down")
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack {
                    Text("Steps per notch").font(.system(size: 11))
                    Spacer()
                    Stepper(value: Binding(
                        get: { action.wheelMultiplier },
                        set: { v in
                            guard let c = control else { return }
                            var a = action; a.kind = .mouse; a.mouseMode = "wheel"
                            a.wheelMultiplier = v
                            app.set(c, a)
                        }), in: 1...20) {
                        Text("\(action.wheelMultiplier)").font(.system(size: 11)).monospacedDigit()
                    }
                    .controlSize(.small)
                }
            } else {
                Picker("", selection: Binding(
                    get: { action.mouseButton },
                    set: { v in
                        guard let c = control else { return }
                        var a = action; a.kind = .mouse; a.mouseMode = "button"; a.mouseButton = v
                        app.set(c, a)
                    })) {
                    Text("Left").tag("left")
                    Text("Right").tag("right")
                    Text("Middle").tag("middle")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    func setKind(_ kind: Action.Kind) {
        guard let c = control else { return }
        var a = action
        a.kind = kind
        switch kind {
        case .media where a.mediaKey.isEmpty: a.mediaKey = MediaKey.volumeUp.rawValue
        case .mouse where a.mouseButton.isEmpty: a.mouseButton = "left"
        default: break
        }
        if kind == .none { a = .none }
        app.set(c, a)
    }

    func label(_ s: String) -> some View {
        Text(s).font(.system(size: 9.5, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
    }
}

// MARK: - Shortcut recorder

struct RecorderSheet: View {
    let onCapture: (Action) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tokens: [KeyToken] = []
    @State private var mods: Set<Modifier> = []
    @State private var monitor: Any?

    // What the keys produce on *this* Mac, which is the intent we store.
    private let pressResolver = LayoutContext.resolver(for: KeyboardLayouts.currentID())

    var body: some View {
        VStack(spacing: 16) {
            Text("Record a shortcut").font(.system(size: 15, weight: .semibold))
            Text("Press the key combination. Press several keys to record a sequence.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 5) {
                ForEach(modifierOrder.filter { mods.contains($0) }, id: \.self) { m in
                    Text(m.glyph).font(.system(size: 18, weight: .medium))
                }
                ForEach(Array(tokens.enumerated()), id: \.offset) { _, t in
                    Text(t.display.uppercased()).font(.system(size: 15, weight: .medium))
                }
                if mods.isEmpty && tokens.isEmpty {
                    Text("⌨︎").font(.system(size: 26)).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text("\(tokens.count) / 18 keys")
                .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use this") {
                    var a = Action(kind: .keystroke)
                    a.tokens = tokens
                    a.modifiers = mods
                    onCapture(a)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(tokens.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 && tokens.isEmpty { dismiss(); return nil }   // esc
                let f = event.modifierFlags
                var m: Set<Modifier> = []
                if f.contains(.control) { m.insert(.ctrl) }
                if f.contains(.shift)   { m.insert(.shift) }
                if f.contains(.option)  { m.insert(.alt) }
                if f.contains(.command) { m.insert(.cmd) }
                if !m.isEmpty { mods = m }
                if let usage = VirtualKeyMap.table[event.keyCode], tokens.count < 18 {
                    // Store what this key actually types here; a character is
                    // portable to other layouts, a bare usage only if it has none.
                    if let ch = pressResolver.character(for: usage) {
                        tokens.append(.char(ch.lowercased()))
                    } else {
                        tokens.append(.key(usage))
                    }
                }
                return nil
            }
        }
        .onDisappear {
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
        }
    }
}

// MARK: - Export helper

enum Exporter {
    static func export(_ p: PadProfile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(p.name).json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            try? enc.encode(p).write(to: url, options: .atomic)
        }
    }
}
