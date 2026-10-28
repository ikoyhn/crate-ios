import SwiftUI
import UIKit

/// Crate's look: a warm, dark, artwork-first style. Deep charcoal surfaces that step up in tone
/// rather than using borders, sunset-amber accents, and tight, heavy headlines.
enum Theme {
    // Surfaces, from the canvas up
    static let canvas = Color(hex: 0x121212)
    static let surface1 = Color(hex: 0x181818)
    static let surface2 = Color(hex: 0x242424)
    static let surface3 = Color(hex: 0x2E2E2E)

    // Accents
    static let amber = Color(hex: 0xF97316)
    static let honey = Color(hex: 0xF59E0B)

    // Text
    static let textMedium = Color(hex: 0xA7A7A7)
    static let textLow = Color(hex: 0x6A6A6A)

    /// Big editorial titles (playlist headers, "What do you want to hear?").
    static func display(_ size: CGFloat = 30) -> Font { .system(size: size, weight: .heavy) }
    static func headline(_ size: CGFloat = 22) -> Font { .system(size: size, weight: .bold) }
    /// Small uppercase labels: badges like NEW, KEPT, PLAYING FROM.
    static let caps = Font.system(size: 11, weight: .bold)

    /// Navigation and tab bars to match, set once at launch.
    static func applyBarAppearance() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(canvas)
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: UIColor.white,
                                   .font: UIFont.systemFont(ofSize: 17, weight: .bold)]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.white,
                                        .font: UIFont.systemFont(ofSize: 32, weight: .heavy),
                                        .kern: -0.6]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(surface1)
        tab.shadowColor = .clear
        let normal = UIColor(textMedium)
        for layout in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            layout.normal.iconColor = normal
            layout.normal.titleTextAttributes = [.foregroundColor: normal]
            layout.selected.iconColor = UIColor(amber)
            layout.selected.titleTextAttributes = [.foregroundColor: UIColor(amber)]
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension View {
    /// The charcoal canvas behind a List, Form or ScrollView.
    func crateScreen() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.canvas.ignoresSafeArea())
    }
}

// MARK: - pieces

/// The round amber play button that leads every playlist and the player.
struct PlayCircle: View {
    var isPlaying = false
    var size: CGFloat = 56
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(Theme.canvas)
                .offset(x: isPlaying ? 0 : size * 0.03)  // a play triangle looks off-centre otherwise
                .frame(width: size, height: size)
                .background(Theme.amber, in: Circle())
                .shadow(color: Theme.amber.opacity(0.35), radius: 12, y: 4)
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

/// Shrinks a touch while pressed.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// A pill-shaped filter or quick choice. Selected: white with dark text.
struct Chip: View {
    let title: String
    var systemImage: String?
    var selected = false
    var dot: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                if let systemImage { Image(systemName: systemImage).font(.caption.weight(.semibold)) }
                Text(title).font(.subheadline.weight(selected ? .bold : .medium))
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(selected ? Theme.canvas : .white)
            .background(selected ? Color.white : Theme.surface2, in: Capsule())
        }
        .buttonStyle(PressScale())
    }
}

/// A smaller pill action: "Keep song", "Rebuild", "Don't recommend".
struct PillButton: View {
    let title: String
    var systemImage: String?
    var prominent = false
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(prominent ? Theme.amber : .white)
            .background(prominent ? Theme.amber.opacity(0.16) : Theme.surface3, in: Capsule())
        }
        .buttonStyle(PressScale())
    }
}

/// A round icon button on a surface: the ✓ and ✕ by a new song.
struct CircleIconButton: View {
    let systemImage: String
    var tint: Color = .white
    var filled = false
    var size: CGFloat = 34
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(filled ? Theme.canvas : tint)
                .frame(width: size, height: size)
                .background(filled ? tint : Theme.surface3, in: Circle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }
}

/// A section title in the editorial style, with an optional amber action ("See all", "Play all").
struct SectionTitle: View {
    let title: String
    var subtitle: String?
    var actionLabel = ""
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.headline()).tracking(-0.3)
                if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(Theme.textMedium) }
            }
            Spacer()
            if let action {
                Button(actionLabel, action: action).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.amber)
            }
        }
    }
}

/// The animated bars by whatever's playing.
struct PlayingBars: View {
    var animating = true
    var body: some View {
        Image(systemName: "waveform")
            .font(.caption.weight(.bold))
            .foregroundStyle(Theme.amber)
            .symbolEffect(.variableColor.iterative, isActive: animating)
            .accessibilityLabel("Playing")
    }
}

/// Shuffle and the big play button, right-aligned under an album or artist header.
struct PlayShuffleRow: View {
    let onPlay: () -> Void
    let onShuffle: () -> Void

    var body: some View {
        HStack(spacing: 22) {
            Spacer()
            Button(action: onShuffle) {
                Image(systemName: "shuffle").font(.title2).foregroundStyle(Theme.amber)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Shuffle")
            PlayCircle(size: 58, action: onPlay)
        }
    }
}
