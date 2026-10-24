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
    /// The mini player, just above the tab bar on every tab.
    func withMiniPlayer() -> some View { modifier(MiniPlayerInset()) }
}

private struct MiniPlayerInset: ViewModifier {
    @Environment(AudioPlayer.self) private var player
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if player.current != nil { MiniPlayer() }
        }
    }
}
