import SwiftUI
import AppKit
import Combine

// MARK: - App state

@MainActor
final class AppState: ObservableObject {
    let transport = HIDTransport()
    let store = ProfileStore()
    let writer = PadWriter()

    /// Nested ObservableObjects don't republish into SwiftUI through AppState,
    /// so forward their change notifications or the UI silently goes stale.
    private var cancellables = Set<AnyCancellable>()

    @Published var profile: PadProfile
    @Published var layerIndex: Int = 0
    @Published var selection: ControlID? = .button(0)

    /// The keyboard layout of the Mac the pad will be *used* on. Shortcuts are
    /// stored as characters and translated into key positions through this
    /// layout, so one profile works on a QWERTY and an AZERTY machine alike.
    @Published var targetLayoutID: String {
        didSet {
            LayoutContext.targetID = targetLayoutID
            UserDefaults.standard.set(targetLayoutID, forKey: "targetLayoutID")
        }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "targetLayoutID")
        let id = saved ?? KeyboardLayouts.currentID()
        targetLayoutID = id
        LayoutContext.targetID = id

        if let first = store.profiles.first { profile = first }
        else { profile = StarterProfile.make() }

        for obj in [transport.objectWillChange, store.objectWillChange, writer.objectWillChange] {
            obj.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        }
    }

    var model: DeviceModel {
        DeviceModel.all.first { $0.id == profile.deviceModelID } ?? .k8850
    }

    var connected: ConnectedDevice? {
        transport.devices.first { $0.isWritable }
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
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 215, ideal: 235, max: 290)
        } detail: {
            HStack(spacing: 0) {
                CanvasView()
                Divider()
                InspectorView()
                    .frame(width: 300)
            }
        }
        .navigationTitle("MacroPad Manager")
        .frame(minWidth: 1000, minHeight: 640)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var app: AppState

    /// Enabled layouts first (what people actually use), then everything else.
    static let layoutOptions: [LayoutDescriptor] = {
        var seen = Set<String>()
        var out: [LayoutDescriptor] = []
        for d in KeyboardLayouts.enabled() where seen.insert(d.id).inserted { out.append(d) }
        for d in KeyboardLayouts.all() where seen.insert(d.id).inserted { out.append(d) }
        return out
    }()

    var body: some View {
        List {
            Section("DEVICE") {
                if let dev = app.connected {
                    HStack(spacing: 9) {
                        Circle().fill(Self.green).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.model.displayName).font(.system(size: 12, weight: .medium))
                            Text(String(format: "%04x:%04x · USB", dev.vendorID, dev.productID))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                } else {
                    HStack(spacing: 9) {
                        Circle().fill(.secondary.opacity(0.4)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("No macropad connected").font(.system(size: 12))
                            Text("Connect the USB cable to write")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("TARGET LAYOUT") {
                Picker("", selection: $app.targetLayoutID) {
                    ForEach(Self.layoutOptions) { d in
                        Text(d.id == KeyboardLayouts.currentID() ? "\(d.name)  (this Mac)" : d.name)
                            .tag(d.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Text("Shortcuts are translated into key positions for this layout.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("LAYERS") {
                ForEach(Array(app.profile.layers.enumerated()), id: \.offset) { idx, layer in
                    Button {
                        app.layerIndex = idx
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(app.layerIndex == idx ? Self.green : Color.secondary.opacity(0.25))
                                .frame(width: 6, height: 6)
                            Text(layer.name).font(.system(size: 12))
                            Spacer()
                            Text("\(layer.bindings.count)").font(.system(size: 10))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(app.layerIndex == idx ? Color.primary.opacity(0.06) : Color.clear)
                }
            }

            Section("PROFILES") {
                ForEach(app.store.profiles) { p in
                    Button { app.loadProfile(p) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: p.id == app.profile.id ? "doc.fill" : "doc")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(p.name).font(.system(size: 12))
                            Spacer()
                            if p.id == app.profile.id {
                                Text("open").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
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
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Text(app.profile.name).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
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
                ProgressView(value: Double(done), total: Double(total))
                    .frame(width: 90)
                Text("\(Int(Double(done) / Double(max(total, 1)) * 100))%")
                    .font(.system(size: 11)).monospacedDigit()
            }
        default:
            Button {
                app.writeToPad()
            } label: {
                Label("Write to Pad", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(app.connected == nil)
            .help(app.connected == nil ? "Connect the macropad with its USB cable" : "Write all three layers")
        }
    }
}

// MARK: - Canvas

struct CanvasView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.profile.layers.indices.contains(app.layerIndex)
                         ? app.profile.layers[app.layerIndex].name : "Layer")
                        .font(.system(size: 15, weight: .semibold))
                    Text("\(app.model.buttonCount) keys · \(app.model.knobCount) encoders · on-device")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if case .failed(let msg) = app.writer.phase {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
                }
                if case .finished(let n) = app.writer.phase {
                    Label("\(n) reports written", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(SidebarView.green)
                }
                ConnectionPill()
                WriteButton()
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }

            ScrollView {
                VStack(spacing: 20) {
                    PadPlateView()
                        .frame(maxWidth: 760)
                    Legend()
                }
                .padding(28)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
        }
    }
}

struct Legend: View {
    var body: some View {
        HStack(spacing: 16) {
            item("square.grid.3x3", "Keys 1–16, left→right, top→bottom")
            item("circle.dashed", "Knobs 1–3, top→bottom")
            item("light.beacon.max", "Layer shown by the 3 LEDs")
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
    }
    func item(_ s: String, _ t: String) -> some View {
        HStack(spacing: 5) { Image(systemName: s); Text(t) }
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
                HStack(alignment: .center, spacing: pad * 0.042) {
                    keyGrid(pad)
                    statusStrip(pad)
                    knobColumn(pad)
                }
                .frame(width: pad * 0.86)
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
        let size = pad * 0.545
        let gap = size * 0.045
        let cell = (size - gap * 3) / 4
        return VStack(spacing: gap) {
            ForEach(0..<app.model.rows, id: \.self) { r in
                HStack(spacing: gap) {
                    ForEach(0..<app.model.columns, id: \.self) { c in
                        let idx = r * app.model.columns + c
                        let sel = app.selection == .button(idx)
                        keyCap(side: cell, selected: sel, action: app.action(.button(idx)))
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
                Text(action.kind == .keystroke ? action.display : "")
                    .font(.system(size: side * 0.19, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .padding(.horizontal, 3)
                if action.kind != .keystroke {
                    Image(systemName: action.kind == .media ? "speaker.wave.2.fill" : "computermouse.fill")
                        .font(.system(size: side * 0.22))
                        .foregroundStyle(.white.opacity(0.75))
                }
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

    func statusStrip(_ pad: CGFloat) -> some View {
        let h = pad * 0.26
        return VStack(spacing: h * 0.06) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(i < (app.layerIndex + 1) ? SidebarView.green : Color(white: 0.70).opacity(0.5))
                    .overlay(RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
            }
        }
        .frame(width: h * 0.05, height: h)
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
    }

    func knobColumn(_ pad: CGFloat) -> some View {
        let width = pad * 0.205
        return VStack(spacing: width * 0.14) {
            ForEach(0..<app.model.knobCount, id: \.self) { k in
                let ratio = k < app.model.knobs.count ? app.model.knobs[k].diameterRatio : 1.0
                knob(index: k, dia: width * ratio, selected: isKnobSelected(k))
            }
        }
    }

    func isKnobSelected(_ k: Int) -> KnobPart? {
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
        }
        .frame(width: dia, height: dia)
        .overlay(alignment: .leading) {
            if selected == .ccw {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SidebarView.green).offset(x: -16)
            }
        }
        .overlay(alignment: .trailing) {
            if selected == .cw {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SidebarView.green).offset(x: 16)
            }
        }
        .overlay(alignment: .bottom) {
            if selected == .press {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(SidebarView.green).offset(y: 14)
            }
        }
        .contentShape(Circle())
        .onTapGesture { app.selection = .knob(index, .press) }
        .contextMenu {
            Button("Turn left") { app.selection = .knob(index, .ccw) }
            Button("Press") { app.selection = .knob(index, .press) }
            Button("Turn right") { app.selection = .knob(index, .cw) }
        }
    }
}
