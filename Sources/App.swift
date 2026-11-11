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
