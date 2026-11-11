import SwiftUI

/// Checklist of every installed layout, used to choose which few appear in the
/// header menu. Tapping a row makes it the target; the star pins it.
struct LayoutChooserSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    /// Cached once: enumerating 244 input sources on every redraw is wasteful.
    static let allLayouts: [LayoutDescriptor] = KeyboardLayouts.all()

    private var all: [LayoutDescriptor] { Self.allLayouts }

    private var filtered: [LayoutDescriptor] {
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard Layouts").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)

            TextField("Search layouts", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            Divider()

            List(filtered) { d in
                HStack(spacing: 10) {
                    Button {
                        app.togglePin(d.id)
                    } label: {
                        Image(systemName: app.isPinned(d.id) ? "star.fill" : "star")
                            .foregroundStyle(app.isPinned(d.id) ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(app.isPinned(d.id) ? "Hide from the menu" : "Show in the menu")

                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.name).font(.system(size: 12))
                        Text(d.id).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if d.id == KeyboardLayouts.currentID() {
                        Text("this Mac").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    if d.id == app.targetLayoutID {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(SidebarView.green)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    app.targetLayoutID = d.id
                    dismiss()
                }
            }
            .listStyle(.inset)

            Divider()
            Text("Starred layouts appear in the header menu.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(width: 440, height: 480)
    }
}
