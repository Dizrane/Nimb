import SwiftUI

/// The window with everything the tunnel opens: the sites that did not open in Russia without it and open with it, from the most
/// popular to the least. Measured by hand (the same address with the tunnel off and on), so it is a list, not a live check.
struct TunnelSitesWindow: View {
    static let windowID = "tunnel-sites"

    private struct Site: Identifiable {
        let name: String
        let kind: String
        var id: String { name }
    }

    /// From the most to the least popular.
    private let sites: [Site] = [
        Site(name: "YouTube", kind: "Видео"),
        Site(name: "Instagram", kind: "Соцсеть"),
        Site(name: "WhatsApp", kind: "Мессенджер"),
        Site(name: "Facebook", kind: "Соцсеть"),
        Site(name: "X (Twitter)", kind: "Соцсеть"),
        Site(name: "Discord", kind: "Мессенджер"),
        Site(name: "LinkedIn", kind: "Соцсеть"),
        Site(name: "YouTube Music", kind: "Музыка"),
        Site(name: "Messenger", kind: "Мессенджер"),
        Site(name: "Threads", kind: "Соцсеть"),
        Site(name: "SoundCloud", kind: "Музыка"),
        Site(name: "Signal", kind: "Мессенджер"),
        Site(name: "Coursera", kind: "Курсы"),
        Site(name: "BBC", kind: "Новости"),
        Site(name: "Speedtest", kind: "Скорость интернета"),
        Site(name: "Proton Mail", kind: "Почта"),
        Site(name: "Zello", kind: "Рация"),
        Site(name: "Dailymotion", kind: "Видео"),
        Site(name: "Bluesky", kind: "Соцсеть"),
        Site(name: "Wattpad", kind: "Книги"),
        Site(name: "Goodreads", kind: "Книги"),
        Site(name: "DeviantArt", kind: "Рисунки"),
        Site(name: "Euronews", kind: "Новости"),
        Site(name: "Meduza", kind: "Новости"),
        Site(name: "Substack", kind: "Блоги"),
        Site(name: "Настоящее Время", kind: "Новости"),
        Site(name: "The Insider", kind: "Новости"),
        Site(name: "Новая газета Европа", kind: "Новости"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Что открывает туннель")
                .font(.system(size: 24, weight: .regular, design: .serif))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.bottom, 12)

            // Two columns, the first eleven on the left and the rest on the right, so that the list is seen at once.
            let half = (sites.count + 1) / 2
            HStack(alignment: .top, spacing: 28) {
                column(Array(sites.prefix(half)), from: 1)
                column(Array(sites.dropFirst(half)), from: half + 1)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .top)

            Text("Туннель не поможет там, где сервис сам закрыт для российских IP-адресов.")
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.04))
                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
        }
        .frame(width: 720)
        .background(Theme.base)
        .preferredColorScheme(.dark)
        .background(FloatAboveMainWindow())
    }

    private func column(_ items: [Site], from first: Int) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, site in
                HStack(spacing: 10) {
                    Text("\(first + index)")
                        .font(Typo.mono)
                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                        .frame(width: 20, alignment: .trailing)
                    Text(site.name)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(site.kind)
                        .font(Typo.small)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 6.5)
                if index < items.count - 1 {
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// Keeps its window above the main window of Nimb, so that it is not left behind it; it goes away with the program when Nimb is not
/// the program in front.
private struct FloatAboveMainWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            view.window?.level = .floating
            view.window?.hidesOnDeactivate = true
        }
    }
}
