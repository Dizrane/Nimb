import SwiftUI

/// The tabs of the window. A small ring of Nimb goes round the word of the selected one; on the home tab, three small rings show
/// which of the services work.
struct TabBar: View {
    @Binding var selection: AppTab
    let isOn: (AppTab) -> Bool

    @StateObject private var ring = HeaderRing()
    @ObservedObject private var gate = AnimationGate.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var frames = TabFrames()
    private static let bleed: CGFloat = 36

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(AppTab.allCases.enumerated()), id: \.element.id) { index, tab in
                if index > 0 { Spacer(minLength: 0) }
                segment(tab)
            }
        }
        .coordinateSpace(name: "tabbar")
        .onPreferenceChange(TabFrameKey.self) { frames.set($0); placeRing() }
        .onChange(of: selection) { _ in placeRing() }
        .background {
            // The canvas reaches beyond the bar by `bleed` on every side: the ring round the last word and its glow go past the
            // end of the word, and a canvas that stopped at the bar cut them off. Its origin moves by the same amount.
            TimelineView(.animation(minimumInterval: ring.moving ? 1.0 / 30 : 1.0 / 15, paused: !gate.shouldRun(brief: ring.moving))) { context in
                Canvas { ctx, _ in
                    ctx.translateBy(x: Self.bleed, y: Self.bleed)
                    draw(&ctx, date: context.date)
                }
            }
            .padding(-Self.bleed)
            .allowsHitTesting(false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.black.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .padding(.horizontal, 12)
    }

    // MARK: Segments

    private func segment(_ tab: AppTab) -> some View {
        let selected = selection == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { selection = tab }
        } label: {
            Group {
                if tab == .home {
                    // The rings of the home tab are drawn behind, in the header canvas; this only keeps their place.
                    Color.clear.frame(width: 26, height: 20)
                } else {
                    Text(tab.title)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        // Three soft black shadows behind the letters keep them clean over the light of the ring.
                        .shadow(color: .black, radius: 1)
                        .shadow(color: .black, radius: 2.5)
                        .shadow(color: .black, radius: 4)
                }
            }
            .background(GeometryReader { proxy in
                Color.clear.preference(key: TabFrameKey.self, value: [tab: proxy.frame(in: .named("tabbar"))])
            })
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(tab.title + (isOn(tab) ? ", включено" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Ring

    private func pose(for tab: AppTab) -> HeaderRing.Pose? {
        guard let frame = frames.frames[tab] else { return nil }
        if tab == .home {
            return HeaderRing.Pose(x: frame.midX, y: frame.midY, rx: frame.width / 2 + 6, ry: 9)
        }
        return HeaderRing.Pose(x: frame.midX, y: frame.midY + 0.5, rx: frame.width / 2 + 15, ry: 8.8)
    }

    private func placeRing() {
        if let pose = pose(for: selection) { ring.update(tab: selection, pose: pose) }
    }

    private func draw(_ ctx: inout GraphicsContext, date: Date) {
        ring.drawSelection(&ctx, date: date, reduceMotion: reduceMotion)
        if let home = frames.frames[.home] {
            HeaderRing.drawStack(&ctx, center: CGPoint(x: home.midX, y: home.midY),
                                 enabled: [isOn(.ai), isOn(.telegram), isOn(.media)], selected: selection == .home)
        }
    }
}

/// The places of the labels in the tab bar, as the ring needs them.
@MainActor
final class TabFrames: ObservableObject {
    private(set) var frames: [AppTab: CGRect] = [:]
    func set(_ new: [AppTab: CGRect]) { if new != frames { frames = new } }
}

private struct TabFrameKey: PreferenceKey {
    static var defaultValue: [AppTab: CGRect] = [:]
    static func reduce(value: inout [AppTab: CGRect], nextValue: () -> [AppTab: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
