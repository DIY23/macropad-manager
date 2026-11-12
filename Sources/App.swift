import SwiftUI
import AppKit

@main
struct MacroPadManagerApp: App {
    @StateObject private var app = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Write All Layers to Pad") {
                    app.writeToPad()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(app.connected == nil)
            }
            CommandGroup(after: .newItem) {
                Button("Import Profile…") { Importer.importProfile(into: app) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Export Profile…") { Exporter.export(app.profile) }
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Copy Layer") { app.copyCurrentLayer() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                Button("Paste Layer") { Dialogs.pasteLayer(app) }
                    .keyboardShortcut("v", modifiers: [.command, .option])
                    .disabled(!app.canPasteLayer)
                Divider()
                Button("Clear Layer…") { Dialogs.clearLayer(app) }
                Button("Clear Profile…") { Dialogs.clearProfile(app) }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum Importer {
    @MainActor
    static func importProfile(into app: AppState) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            try? app.store.importProfile(from: url)
            if let p = app.store.profiles.first { app.loadProfile(p) }
        }
    }
}

// MARK: - Destructive actions, always confirmed

enum Dialogs {
    @MainActor
    static func confirm(_ title: String, _ info: String, _ confirmTitle: String,
                        _ action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { action() }
    }

    @MainActor
    static func clearLayer(_ app: AppState) {
        let n = app.currentLayer.name
        confirm("Clear “\(n)”?",
                "This removes every binding on layer \(app.layerIndex + 1) of this profile. The pad keeps its current keymap until you write to it.",
                "Clear Layer") {
            app.clearLayer()
        }
    }

    @MainActor
    static func clearProfile(_ app: AppState) {
        confirm("Clear “\(app.profile.name)”?",
                "This removes every binding on all three layers of this profile. The pad keeps its current keymap until you write to it.",
                "Clear Profile") {
            app.clearProfile()
        }
    }

    @MainActor
    static func pasteLayer(_ app: AppState) {
        let name = app.currentLayer.name
        let count = app.currentLayer.bindings.count
        guard count > 0 else {
            app.pasteLayerOverCurrent()
            return
        }
        confirm("Replace “\(name)”?",
                "Layer \(app.layerIndex + 1) already has \(count) bindings. Pasting replaces them with the copied layer.",
                "Replace Layer") {
            app.pasteLayerOverCurrent()
        }
    }

    // MARK: rename

    @MainActor
    static func promptText(title: String, initial: String, action: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = " "
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { action(v) }
        }
    }

    @MainActor
    static func renameProfile(_ app: AppState, _ p: PadProfile) {
        promptText(title: "Rename Profile", initial: p.name) { app.renameProfile(p.id, to: $0) }
    }

    @MainActor
    static func renameLayer(_ app: AppState, index: Int, current: String) {
        promptText(title: "Rename Layer \(index + 1)", initial: current) { app.renameLayer(index, to: $0) }
    }
}
