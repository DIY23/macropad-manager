import SwiftUI
import AppKit
import Combine

// MARK: - App state

@MainActor
final class AppState: ObservableObject {
    let transport = HIDTransport()
    let store = ProfileStore()
    let writer = PadWriter()

    private var cancellables = Set<AnyCancellable>()

    @Published var profile: PadProfile
    @Published var layerIndex: Int = 0
    @Published var selection: ControlID? = .button(0)
    @Published var selectedDeviceID: String?

    /// The layout of the Mac the pad will be *used* on.
    @Published var targetLayoutID: String {
        didSet {
            LayoutContext.targetID = targetLayoutID
            UserDefaults.standard.set(targetLayoutID, forKey: "targetLayoutID")
        }
    }

    /// Layouts shown directly in the header menu. Everything else is reachable
    /// through the chooser sheet.
    @Published var pinnedLayoutIDs: [String] {
        didSet { UserDefaults.standard.set(pinnedLayoutIDs, forKey: "pinnedLayoutIDs") }
    }

    /// Layer clipboard, so a layer can be copied from one profile to another.
    @Published private(set) var copiedLayerName: String?
    private var layerClipboard: Layer?

    init() {
        let saved = UserDefaults.standard.string(forKey: "targetLayoutID")
        let id = saved ?? KeyboardLayouts.currentID()
        targetLayoutID = id
        LayoutContext.targetID = id

        let savedPins = UserDefaults.standard.stringArray(forKey: "pinnedLayoutIDs")
        var seen = Set<String>()
        pinnedLayoutIDs = (savedPins ?? (KeyboardLayouts.enabled().map(\.id) + [id]))
            .filter { seen.insert($0).inserted }

        if let first = store.profiles.first { profile = first }
        else { profile = StarterProfile.make() }

        for obj in [transport.objectWillChange, store.objectWillChange, writer.objectWillChange] {
            obj.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        }
    }

    var model: DeviceModel {
        DeviceModel.all.first { $0.id == profile.deviceModelID } ?? .k8850
    }

    var writableDevices: [ConnectedDevice] { transport.devices.filter(\.isWritable) }

    /// The device being edited for: explicitly chosen, else the first one.
    var connected: ConnectedDevice? {
        if let id = selectedDeviceID, let d = writableDevices.first(where: { $0.id == id }) { return d }
        return writableDevices.first
    }

    var currentLayer: Layer {
        guard layerIndex < profile.layers.count else { return Layer(name: "Layer") }
        return profile.layers[layerIndex]
    }

    func action(_ c: ControlID) -> Action { currentLayer.action(c) }

    func set(_ c: ControlID, _ a: Action) {
        guard layerIndex < profile.layers.count else { return }
        profile.layers[layerIndex].set(c, a)
        persistSoon()
    }

    private var saveTask: Task<Void, Never>?
    func persistSoon() {
        saveTask?.cancel()
        let snapshot = profile
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.store.save(snapshot)
        }
    }

    func loadProfile(_ p: PadProfile) {
        profile = p
        layerIndex = 0
        selection = .button(0)
    }

    func writeToPad() {
        guard let dev = connected else { return }
        writer.write(profile: profile, model: model, transport: transport, deviceID: dev.id)
    }

    // MARK: destructive edits (caller confirms first)

    func clearLayer() {
        guard layerIndex < profile.layers.count else { return }
        profile.layers[layerIndex].bindings.removeAll()
        store.save(profile)
    }

    func clearProfile() {
        for i in profile.layers.indices { profile.layers[i].bindings.removeAll() }
        store.save(profile)
    }

    func renameCurrentLayer(_ name: String) {
        guard layerIndex < profile.layers.count else { return }
        profile.layers[layerIndex].name = name
        persistSoon()
    }

    func renameLayer(_ index: Int, to name: String) {
        guard index < profile.layers.count, !name.isEmpty else { return }
        profile.layers[index].name = name
        persistSoon()
    }

    func renameProfile(_ id: UUID, to name: String) {
        guard let i = store.profiles.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        var p = store.profiles[i]
        p.name = name
        store.save(p)
        if profile.id == id { profile.name = name }
    }

    // MARK: pinned layouts

    func isPinned(_ id: String) -> Bool { pinnedLayoutIDs.contains(id) }

    func togglePin(_ id: String) {
        if let i = pinnedLayoutIDs.firstIndex(of: id) { pinnedLayoutIDs.remove(at: i) }
        else { pinnedLayoutIDs.append(id) }
    }

    /// Pinned layouts that still exist, deduped, always including the target.
    var menuLayouts: [LayoutDescriptor] {
        let all = LayoutChooserSheet.allLayouts
        var seen = Set<String>()
        var ids = pinnedLayoutIDs.filter { seen.insert($0).inserted }
        if seen.insert(targetLayoutID).inserted { ids.append(targetLayoutID) }
        return ids.compactMap { id in all.first { $0.id == id } }
    }

    // MARK: layer clipboard

    var canPasteLayer: Bool { layerClipboard != nil }

    func copyCurrentLayer() {
        layerClipboard = currentLayer
        copiedLayerName = "\(currentLayer.name) (layer \(layerIndex + 1))"
    }

    /// Replaces the current layer with the clipboard contents. The copied layer
    /// keeps its own name — that is the point of copying it between profiles.
    func pasteLayerOverCurrent() {
        guard let clip = layerClipboard, layerIndex < profile.layers.count else { return }
        profile.layers[layerIndex] = clip
        store.save(profile)
    }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 215, ideal: 240, max: 300)
        } detail: {
            HStack(spacing: 0) {
                CanvasView()
                Divider()
                InspectorView().frame(width: 300)
            }
        }
        // The profile header lives in the window's toolbar, so it costs no
        // vertical space of its own.
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(app.profile.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("\(app.model.displayName) · Layer \(app.layerIndex + 1) · \(app.currentLayer.name)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(minWidth: 220)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                HeaderActions()
            }
        }
        .navigationTitle("")
        .frame(minWidth: 1040, minHeight: 660)
    }
}

/// Layout menu, connection state and the write button, all in the title bar.
struct HeaderActions: View {
    @EnvironmentObject var app: AppState
    @State private var showLayoutChooser = false

    private var layoutTitle: String {
        let name = KeyboardLayouts.name(for: app.targetLayoutID)
        return app.targetLayoutID == KeyboardLayouts.currentID() ? "\(name) (this Mac)" : name
    }

    var body: some View {
        if case .failed(let msg) = app.writer.phase {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).help(msg)
        }
        if case .finished(let n) = app.writer.phase {
            Label("\(n) written", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(SidebarView.green)
        }

        Menu {
            ForEach(app.menuLayouts) { d in
                Button {
                    app.targetLayoutID = d.id
                } label: {
                    if d.id == app.targetLayoutID {
                        Label(d.id == KeyboardLayouts.currentID() ? "\(d.name)  (this Mac)" : d.name,
                              systemImage: "checkmark")
                    } else {
                        Text(d.id == KeyboardLayouts.currentID() ? "\(d.name)  (this Mac)" : d.name)
                    }
                }
            }
            Divider()
            Button("Add Layouts…") { showLayoutChooser = true }
        } label: {
            Label(layoutTitle, systemImage: "keyboard")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .labelStyle(.titleAndIcon)
        .fixedSize()
        .help("Keyboard layout of the Mac the pad will be used on")
        .sheet(isPresented: $showLayoutChooser) {
            LayoutChooserSheet().environmentObject(app)
        }

        ConnectionPill()
        WriteButton()
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var app: AppState

    @State private var renamingProfileID: UUID?
    @State private var renamingLayer: Int?
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    private func beginProfileRename(_ p: PadProfile) {
        draft = p.name
        renamingLayer = nil
        renamingProfileID = p.id
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitProfileRename(_ id: UUID) {
        let v = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty { app.renameProfile(id, to: v) }
        renamingProfileID = nil
        nameFocused = false
    }

    private func beginLayerRename(_ idx: Int, current: String) {
        draft = current
        renamingProfileID = nil
        renamingLayer = idx
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitLayerRename(_ idx: Int) {
        let v = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty { app.renameLayer(idx, to: v) }
        renamingLayer = nil
        nameFocused = false
    }

    static let layoutOptions: [LayoutDescriptor] = {
        var seen = Set<String>()
        var out: [LayoutDescriptor] = []
        for d in KeyboardLayouts.enabled() where seen.insert(d.id).inserted { out.append(d) }
        for d in KeyboardLayouts.all() where seen.insert(d.id).inserted { out.append(d) }
        return out
    }()

    var body: some View {
        List {
            // Becomes a real selector when several pads are attached.
            Section("DEVICES") {
                if app.writableDevices.isEmpty {
                    HStack(spacing: 9) {
                        Circle().fill(.secondary.opacity(0.4)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("No macropad connected").font(.system(size: 12))
                            Text("Connect the USB cable to write")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ForEach(app.writableDevices) { dev in
                        Button { app.selectedDeviceID = dev.id } label: {
                            HStack(spacing: 9) {
                                Circle()
                                    .fill(app.connected?.id == dev.id
                                          ? SidebarView.green : Color.secondary.opacity(0.35))
                                    .frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(dev.model?.displayName ?? dev.name)
                                        .font(.system(size: 12, weight: .medium))
                                    Text(String(format: "%04x:%04x", dev.vendorID, dev.productID))
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(app.connected?.id == dev.id
                                           ? Color.primary.opacity(0.06) : Color.clear)
                    }
                }
            }

            Section("PROFILES") {
                ForEach(app.store.profiles) { p in
                    HStack(spacing: 8) {
                        Image(systemName: p.id == app.profile.id ? "doc.fill" : "doc")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if renamingProfileID == p.id {
                            TextField("Name", text: $draft)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .focused($nameFocused)
                                .onSubmit { commitProfileRename(p.id) }
                                .onExitCommand { renamingProfileID = nil; nameFocused = false }
                        } else {
                            Text(p.name).font(.system(size: 12)).lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginProfileRename(p) }
                    .onTapGesture { app.loadProfile(p) }
                    .listRowBackground(p.id == app.profile.id ? Color.primary.opacity(0.06) : Color.clear)
                    .contextMenu {
                        Button("Rename") { beginProfileRename(p) }
                        Button("Duplicate") { app.store.duplicate(p) }
                        Button("Export…") { Exporter.export(p) }
                        Divider()
                        Button("Delete", role: .destructive) { app.store.delete(p) }
                    }
                }
                Button {
                    var new = PadProfile.empty(model: app.model)
                    new.name = "New Profile"
                    app.store.save(new)
                    app.loadProfile(new)
                } label: {
                    Label("New profile", systemImage: "plus").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            // Layers live inside a profile, so they follow it.
            Section("LAYERS") {
                ForEach(Array(app.profile.layers.enumerated()), id: \.offset) { idx, layer in
                    HStack(spacing: 9) {
                        Text("\(idx + 1)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(app.layerIndex == idx ? .primary : .secondary)
                            .frame(width: 10)
                        if renamingLayer == idx {
                            TextField("Name", text: $draft)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .focused($nameFocused)
                                .onSubmit { commitLayerRename(idx) }
                                .onExitCommand { renamingLayer = nil; nameFocused = false }
                        } else {
                            Text(layer.name).font(.system(size: 12)).lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginLayerRename(idx, current: layer.name) }
                    .onTapGesture { app.layerIndex = idx }
                    .listRowBackground(app.layerIndex == idx ? Color.primary.opacity(0.06) : Color.clear)
                    .contextMenu {
                        Button("Rename") { beginLayerRename(idx, current: layer.name) }
                        Button("Copy Layer") { app.layerIndex = idx; app.copyCurrentLayer() }
                        Button("Paste Layer") { app.layerIndex = idx; Dialogs.pasteLayer(app) }
                            .disabled(!app.canPasteLayer)
                        Divider()
                        Button("Clear Layer…", role: .destructive) { app.layerIndex = idx; Dialogs.clearLayer(app) }
                    }
                }
            }
        }
        .padding(.top, 6)
        .listStyle(.sidebar)
    }

    static let green = Color(red: 0.18, green: 0.78, blue: 0.35)
}

// MARK: - Toolbar bits

struct ConnectionPill: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(app.connected != nil ? SidebarView.green : .secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(app.connected != nil ? "Connected" : "Not connected")
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
    }
}

struct WriteButton: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        switch app.writer.phase {
        case .writing(let done, let total):
            HStack(spacing: 8) {
                ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 90)
                Text("\(Int(Double(done) / Double(max(total, 1)) * 100))%")
                    .font(.system(size: 11)).monospacedDigit()
            }
        default:
            Button { app.writeToPad() } label: {
                Label("Write to Pad", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .labelStyle(.titleAndIcon)
            .tint(SidebarView.green)
            .disabled(app.connected == nil)
            .help(app.connected == nil ? "Connect the macropad with its USB cable" : "Write all three layers")
        }
    }
}

// MARK: - Canvas

struct CanvasView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        GeometryReader { geo in
            PadPlateView()
                .frame(maxWidth: min(780, max(geo.size.width - 56, 320)))
                .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }
}

// MARK: - The pad drawing

struct PadPlateView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        GeometryReader { geo in
            let pad = min(geo.size.width, geo.size.height * 1.42)
            ZStack(alignment: .topLeading) {
                plate(pad)
                HStack(alignment: .center, spacing: pad * 0.038) {
                    keyGrid(pad)
                    knobColumn(pad)
                }
                .frame(width: pad * 0.88)
                .frame(width: pad, height: pad * 0.70, alignment: .bottom)
                .padding(.bottom, pad * 0.018)
                if app.model.hasLayerLEDs {
                    layerLEDs(pad)
                        .padding(.leading, pad * 0.045)
                        .padding(.top, pad * 0.014)
                }
            }
            .frame(width: pad, height: pad * 0.70)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1.42, contentMode: .fit)
    }

    func plate(_ pad: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: pad * 0.022, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.93), Color(white: 0.84)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                RoundedRectangle(cornerRadius: pad * 0.022, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.9), .black.opacity(0.16)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1.2)
            )
            .shadow(color: .black.opacity(0.22), radius: 18, y: 9)
    }

    func keyGrid(_ pad: CGFloat) -> some View {
        let size = pad * 0.585
        let gap = size * 0.045
        let cell = (size - gap * 3) / 4
        return VStack(spacing: gap) {
            ForEach(0..<app.model.rows, id: \.self) { r in
                HStack(spacing: gap) {
                    ForEach(0..<app.model.columns, id: \.self) { c in
                        let idx = r * app.model.columns + c
                        keyCap(side: cell,
                               selected: app.selection == .button(idx),
                               action: app.action(.button(idx)))
                            .onTapGesture { app.selection = .button(idx) }
                    }
                }
            }
        }
        .frame(width: size)
    }

    func keyCap(side: CGFloat, selected: Bool, action: Action) -> some View {
        let r = side * 0.16
        return ZStack {
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.26), Color(white: 0.13)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: r, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .clear],
                                                 startPoint: .top, endPoint: .center), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: side * 0.05, y: side * 0.035)

            if !action.isEmpty {
                keyFaceView(action, side: side)
            }

            if selected {
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .strokeBorder(SidebarView.green, lineWidth: 2.5)
                    .shadow(color: SidebarView.green.opacity(0.6), radius: 5)
            }
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    func keyFaceView(_ action: Action, side: CGFloat) -> some View {
        let custom = !(action.label ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        if custom || action.kind == .keystroke {
            Text(action.keyFace.uppercased())
                .font(.system(size: side * 0.225, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.93))
                .lineLimit(1)
                .minimumScaleFactor(0.38)
                .padding(.horizontal, side * 0.05)
        } else if action.kind == .media, let mk = MediaKey(rawValue: action.mediaKey) {
            Image(systemName: mk.symbol)
                .font(.system(size: side * 0.30))
                .foregroundStyle(.white.opacity(0.85))
                .help(mk.title)
        } else if action.kind == .mouse {
            Image(systemName: action.isWheel ? "scroll" : "computermouse.fill")
                .font(.system(size: side * 0.30))
                .foregroundStyle(.white.opacity(0.85))
                .help(action.display)
        }
    }

    func layerLEDs(_ pad: CGFloat) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<app.profile.layers.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(i == app.layerIndex ? SidebarView.green : Color(white: 0.72).opacity(0.55))
                    .frame(width: 5, height: 9)
                    .shadow(color: i == app.layerIndex ? SidebarView.green.opacity(0.9) : .clear, radius: 4)
            }
        }
        .help("Layer LEDs — which layer the pad is on")
    }

    func knobColumn(_ pad: CGFloat) -> some View {
        let width = pad * 0.165
        return VStack(spacing: width * 0.22) {
            ForEach(0..<app.model.knobCount, id: \.self) { k in
                let ratio = k < app.model.knobs.count ? app.model.knobs[k].diameterRatio : 1.0
                VStack(spacing: width * 0.07) {
                    knob(index: k, dia: width * ratio, selected: selectedPart(k))
                    let caption = knobCaption(k)
                    if !caption.isEmpty {
                        Text(caption)
                            .font(.system(size: width * 0.115, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(maxWidth: width * 1.15)
                    }
                }
            }
        }
    }

    /// What the knob's press does, printed beside it so the encoder is not a blank.
    func knobCaption(_ k: Int) -> String {
        let a = app.action(.knob(k, .press))
        return a.isEmpty ? "" : a.keyFace.uppercased()
    }

    func selectedPart(_ k: Int) -> KnobPart? {
        for p in KnobPart.allCases where app.selection == .knob(k, p) { return p }
        return nil
    }

    func knob(index: Int, dia: CGFloat, selected: KnobPart?) -> some View {
        ZStack {
            Circle()
                .fill(AngularGradient(gradient: Gradient(colors: [
                    Color(white: 0.62), Color(white: 0.30), Color(white: 0.78),
                    Color(white: 0.34), Color(white: 0.70), Color(white: 0.28), Color(white: 0.62)
                ]), center: .center))
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.38), radius: dia * 0.10, y: dia * 0.05)
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.55), Color(white: 0.22)],
                                     center: .topLeading, startRadius: dia * 0.05, endRadius: dia * 0.6))
                .frame(width: dia * 0.52)
            Rectangle().fill(.white.opacity(0.85))
                .frame(width: 1.8, height: dia * 0.20)
                .offset(y: -dia * 0.29)
            if selected != nil {
                Circle().strokeBorder(SidebarView.green, lineWidth: 2.5)
                    .shadow(color: SidebarView.green.opacity(0.6), radius: 5)
            }
            // Which part is being edited, drawn on the knob itself.
            if let part = selected {
                VStack(spacing: 1) {
                    Image(systemName: part == .ccw ? "arrow.counterclockwise"
                                    : part == .cw ? "arrow.clockwise" : "arrow.down.to.line")
                        .font(.system(size: dia * 0.14, weight: .bold))
                    Text(part == .ccw ? "TURN LEFT" : part == .cw ? "TURN RIGHT" : "PRESS")
                        .font(.system(size: dia * 0.075, weight: .bold))
                }
                .foregroundStyle(SidebarView.green)
                .shadow(color: .black.opacity(0.5), radius: 2)
            }
        }
        .frame(width: dia, height: dia)
        // Three hit zones: left third turns left, middle presses, right turns right.
        .overlay(
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { app.selection = .knob(index, .ccw) }
                    .help("Turn left")
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { app.selection = .knob(index, .press) }
                    .help("Press")
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { app.selection = .knob(index, .cw) }
                    .help("Turn right")
            }
        )
        .contextMenu {
            Button("Turn left") { app.selection = .knob(index, .ccw) }
            Button("Press") { app.selection = .knob(index, .press) }
            Button("Turn right") { app.selection = .knob(index, .cw) }
        }
    }
}
