import SwiftUI

/// The tabs in the title bar of the tabs layout, like in Safari: «Главная» pinned (the three small rings, no word), the other
/// open tabs with a word and a cross, a plus that opens a menu of the pages that are not open, and the gear that opens the
/// settings as a tab. A small ring of Nimb goes round the word of the selected tab (`HeaderRing`).
struct TitleTabs: View {
    static let height: CGFloat = 40
    /// Room for the three buttons of the window on the left.
    private static let lights: CGFloat = 78
    private static let bleed: CGFloat = 36

    @ObservedObject private var nav = Navigation.shared
    @ObservedObject private var all = AllServices.shared
    @StateObject private var ring = HeaderRing()
    @StateObject private var frames = TabFrames()
    @ObservedObject private var gate = AnimationGate.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.lights)
            ForEach(nav.openTabs) { page in tab(page) }
            addMenu
            Spacer(minLength: 8)
            gear
        }
        .padding(.trailing, 10)
        .frame(height: Self.height)
        .coordinateSpace(name: "tabbar")
        .onPreferenceChange(TabFrameKey.self) { frames.set($0); placeRing() }
        .onChange(of: nav.page) { _ in placeRing() }
        .background {
            // The canvas reaches beyond the strip, so that the ring round a word near its end is not cut.
            TimelineView(.animation(minimumInterval: ring.moving ? 1.0 / 30 : 1.0 / 15, paused: !gate.shouldRun(brief: ring.moving))) { context in
                Canvas { ctx, _ in
                    ctx.translateBy(x: Self.bleed, y: Self.bleed)
                    draw(&ctx, date: context.date)
                }
            }
            .padding(-Self.bleed)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }

    // MARK: Tabs

    private func tab(_ page: AppPage) -> some View {
        let selected = nav.page == page
        return HStack(spacing: 20) {
            Button { withAnimation(.easeOut(duration: 0.12)) { nav.select(page) } } label: {
                Group {
                    if page == .home {
                        // The rings of the home tab are drawn behind, in the strip's canvas; this only keeps their place.
                        Color.clear.frame(width: 26, height: 20)
                    } else {
                        Text(page.title)
                            .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                            .lineLimit(1)
                            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                            // Soft black shadows behind the letters keep them clean over the light of the ring.
                            .shadow(color: .black, radius: 1)
                            .shadow(color: .black, radius: 2.5)
                            .shadow(color: .black, radius: 4)
                    }
                }
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: TabFrameKey.self, value: [page: proxy.frame(in: .named("tabbar"))])
                })
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(page.title)
            .accessibilityAddTraits(selected ? .isSelected : [])

            if page != .home {
                Button { withAnimation(.easeOut(duration: 0.15)) { nav.close(page) } } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Закрыть вкладку")
                .accessibilityLabel("Закрыть вкладку \(page.title)")
            }
        }
        .padding(.horizontal, page == .home ? 14 : 12)
    }

    private var addMenu: some View {
        Menu {
            ForEach(nav.closedTabs) { page in
                Button(page.title) { withAnimation(.easeOut(duration: 0.12)) { nav.select(page) } }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(nav.closedTabs.isEmpty)
        .help("Открыть страницу")
        .accessibilityLabel("Открыть страницу")
        .padding(.leading, 4)
    }

    private var gear: some View {
        Button {
            StepIconPlayers.shared.player(.gear).play(reduceMotion: reduceMotion)
            withAnimation(.easeOut(duration: 0.12)) { nav.select(.settings) }
        } label: {
            GearIcon()
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help("Настройки")
        .accessibilityLabel("Настройки")
    }

    // MARK: Ring

    private func pose(for page: AppPage) -> HeaderRing.Pose? {
        guard let frame = frames.frames[page] else { return nil }
        if page == .home { return HeaderRing.Pose(x: frame.midX, y: frame.midY, rx: frame.width / 2 + 6, ry: 9) }
        return HeaderRing.Pose(x: frame.midX, y: frame.midY + 0.5, rx: frame.width / 2 + 15, ry: 8.8)
    }

    private func placeRing() {
        if let pose = pose(for: nav.page) { ring.update(tab: nav.page, pose: pose) }
    }

    private func draw(_ ctx: inout GraphicsContext, date: Date) {
        ring.drawSelection(&ctx, date: date, reduceMotion: reduceMotion)
        if let home = frames.frames[.home] {
            let e = all.effective
            HeaderRing.drawStack(&ctx, center: CGPoint(x: home.midX, y: home.midY), enabled: [e.ai, e.telegram, e.media], selected: nav.page == .home)
        }
    }
}

/// The places of the labels in the strip, as the ring needs them.
@MainActor
final class TabFrames: ObservableObject {
    private(set) var frames: [AppPage: CGRect] = [:]
    func set(_ new: [AppPage: CGRect]) { if new != frames { frames = new } }
}

private struct TabFrameKey: PreferenceKey {
    static var defaultValue: [AppPage: CGRect] = [:]
    static func reduce(value: inout [AppPage: CGRect], nextValue: () -> [AppPage: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
