import SwiftUI

@main
struct CrateApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.player)
                .tint(.accentColor)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        if model.isConnected {
            TabView {
                HomeView().withMiniPlayer()
                    .tabItem { Label("Home", systemImage: "house") }
                PlaylistsView().withMiniPlayer()
                    .tabItem { Label("Playlists", systemImage: "music.note.list") }
                SearchView().withMiniPlayer()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                AutomationsView().withMiniPlayer()
                    .tabItem { Label("Create", systemImage: "wand.and.stars") }
                ActivityView().withMiniPlayer()
                    .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
            }
            .sheet(isPresented: Bindable(player).showNowPlaying) { NowPlayingView() }
            .overlay(alignment: .top) { ToastView() }
        } else {
            ConnectView()
        }
    }
}

extension View {
    /// The mini player, just above the tab bar on every tab (and the tab's "Add to playlist…").
    func withMiniPlayer() -> some View { modifier(MiniPlayerInset()).playlistPicker() }
}

private struct MiniPlayerInset: ViewModifier {
    @Environment(AudioPlayer.self) private var player
    func body(content: Content) -> some View {
        // A safe-area inset set outside a NavigationStack doesn't reach the lists inside it, so the
        // mini player covered the end of every page. Give scrolling content room for it instead.
        content
            .contentMargins(.bottom, player.current != nil ? MiniPlayer.height : 0, for: .scrollContent)
            .overlay(alignment: .bottom) {
                if player.current != nil { MiniPlayer() }
            }
    }
}
