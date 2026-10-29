import SwiftUI

/// The popover with everything the tunnel opens (behind the «i» of the page of the tunnel, like every other «i»): the sites that did not
/// open in Russia without it and open with it, from the most popular to the least. Measured by hand (the same address with the tunnel
/// off and on), so it is a list, not a live check.
struct TunnelSitesInfo: View {

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
        VStack(alignment: .leading, spacing: 8) {
            Text("Что открывает туннель").font(Typo.name)
            // Two columns, the first half on the left and the rest on the right, so that the list is seen at once.
            let half = (sites.count + 1) / 2
            HStack(alignment: .top, spacing: 22) {
                column(Array(sites.prefix(half)), from: 1)
                column(Array(sites.dropFirst(half)), from: half + 1)
            }
            Divider()
            Text("Туннель не поможет там, где сервис сам закрыт для российских IP-адресов.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .infoPanel(width: 560)
    }

    private func column(_ items: [Site], from first: Int) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, site in
                HStack(spacing: 8) {
                    Text("\(first + index)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, alignment: .trailing)
                    Text(site.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(site.kind)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(first + index). \(site.name), \(site.kind)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}
