import CrateKit
import SwiftUI

struct Artwork: View {
    let url: URL?
    /// nil: a square as big as the space it's given (Now Playing).
    var size: CGFloat? = 48
    var corner: CGFloat = 6

    var body: some View {
        if let size {
            image.frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        } else {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay { image }
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
    }

    private var image: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note").foregroundStyle(.secondary).font(.system(size: (size ?? 120) * 0.35))
                }
            }
        }
    }
}

/// New (waiting in the inbox), Kept, Added by you.
struct Badge: View {
    let text: String
    var color: Color = .accentColor
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct StarRating: View {
    let rating: Int
    var size: Font = .title3
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { n in
                Button {
                    onChange(n == rating ? 0 : n)  // tap the current rating again to clear it
                } label: {
                    Image(systemName: n <= rating ? "star.fill" : "star")
                        .font(size)
                        .foregroundStyle(n <= rating ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(n) star\(n == 1 ? "" : "s")")
            }
        }
    }
}

struct HeartButton: View {
    let starred: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: starred ? "heart.fill" : "heart")
                .foregroundStyle(starred ? Color.pink : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: starred)
        .accessibilityLabel(starred ? "Unlove" : "Love")
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            HStack(spacing: 12) {
                Text(toast.text).font(.subheadline).lineLimit(3)
                if let undo = toast.undo {
                    Button("Undo") { undo(); model.toast = nil }.font(.subheadline.bold())
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 8, y: 2)
            .padding(.top, 8).padding(.horizontal)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onTapGesture { model.toast = nil }
            .task(id: toast.id) {
                try? await Task.sleep(nanoseconds: (toast.undo == nil ? 3 : 5) * 1_000_000_000)
                if model.toast?.id == toast.id { withAnimation { model.toast = nil } }
            }
        }
    }
}

/// "Discover Weekly running for 3 min · Stop all", shown while Crate is busy.
struct BusyBanner: View {
    @Environment(AppModel.self) private var model
    @State private var confirmStop = false

    var body: some View {
        if let busy = model.status?.busy, !busy.isEmpty {
            HStack(alignment: .top) {
                ProgressView().padding(.trailing, 4)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(busy, id: \.self) { b in
                        Text(line(b)).font(.subheadline)
                    }
                }
                Spacer()
                Button("Stop all", role: .destructive) { confirmStop = true }
                    .font(.subheadline)
                    .confirmationDialog("Stop everything Crate is doing?", isPresented: $confirmStop, titleVisibility: .visible) {
                        Button("Stop all tasks", role: .destructive) { model.stopAll() }
                    } message: {
                        Text("Waiting tasks are cancelled; running ones stop at their next safe point. Scheduled runs still happen at their usual time.")
                    }
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func line(_ b: Status.Busy) -> String {
        let label = model.jobLabel(b.kind)
        switch b.status {
        case "queued": return "\(label) waiting"
        case "stopping": return "\(label) stopping…"
        default:
            guard let started = b.started else { return "\(label) running" }
            return "\(label) running for \(Date(timeIntervalSince1970: started).formatted(.relative(presentation: .named)).replacingOccurrences(of: " ago", with: ""))"
        }
    }
}

extension Int {
    /// 245 -> "4:05"
    var mmss: String { self > 0 ? String(format: "%d:%02d", self / 60, self % 60) : "" }
}

extension Double {
    var mmss: String {
        let s = isFinite ? Int(Swift.max(self, 0)) : 0
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension Optional where Wrapped == Double {
    /// Unix seconds -> "3 hours ago"
    var ago: String {
        guard let t = self else { return "" }
        return Date(timeIntervalSince1970: t).formatted(.relative(presentation: .named))
    }
}

extension PlaylistKind {
    var symbol: String {
        switch self {
        case .discover: "sparkles"
        case .releaseRadar: "dot.radiowaves.left.and.right"
        case .dailyMix: "sun.max"
        case .prompt: "text.bubble"
        case .own: "music.note.list"
        case .liked: "heart.fill"
        case .other: "music.note"
        }
    }

    var color: Color {
        switch self {
        case .discover: .purple
        case .releaseRadar: .orange
        case .dailyMix: .teal
        case .prompt: .indigo
        case .liked: .pink
        case .own, .other: .gray
        }
    }
}
