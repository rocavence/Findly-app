import SwiftUI
import AppKit

/// One row in the sidebar. `id` is the POSIX path — the stable identity used for
/// selection and for persisting the user's custom order.
struct SidebarEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let url: URL
    /// SF Symbol for a standard location; nil → fall back to the file's real
    /// icon (e.g. Dropbox keeps its brand icon).
    let systemSymbol: String?
}

/// Observable backing store the AppKit side refreshes on each show, so the
/// SwiftUI list mirrors Finder.
@MainActor
final class SidebarModel: ObservableObject {
    @Published var favorites: [SidebarEntry] = []
    @Published var locations: [SidebarEntry] = []
    @Published var selection: String?
    var onSelect: ((URL) -> Void)?
    var onReorderFavorites: (([SidebarEntry]) -> Void)?
}

/// Native macOS sidebar built with SwiftUI's `.sidebar` list style — selection,
/// group headers, row metrics, vibrancy and (on macOS 26) Liquid Glass all come
/// from the system instead of hand-rolled cells.
struct FindlySidebar: View {
    @ObservedObject var model: SidebarModel

    var body: some View {
        List(selection: $model.selection) {
            Section(NSLocalizedString("Favorites", comment: "Sidebar section header")) {
                ForEach(model.favorites) { row($0) }
                    .onMove(perform: moveFavorite)
            }
            Section(NSLocalizedString("Locations", comment: "Sidebar section header")) {
                ForEach(model.locations) { row($0) }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: model.selection) { _, newValue in
            guard let id = newValue,
                  let entry = (model.favorites + model.locations).first(where: { $0.id == id })
            else { return }
            model.onSelect?(entry.url)
        }
    }

    @ViewBuilder
    private func row(_ entry: SidebarEntry) -> some View {
        if let symbol = entry.systemSymbol {
            Label(entry.title, systemImage: symbol).tag(entry.id)
        } else {
            Label {
                Text(entry.title)
            } icon: {
                Image(nsImage: Self.brandIcon(entry.url))
            }
            .tag(entry.id)
        }
    }

    private func moveFavorite(from: IndexSet, to: Int) {
        model.favorites.move(fromOffsets: from, toOffset: to)
        model.onReorderFavorites?(model.favorites)
    }

    private static func brandIcon(_ url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 18, height: 18)
        return icon
    }
}
