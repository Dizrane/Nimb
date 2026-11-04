import SwiftUI

/// What the check asked of one site and what it got, in a popover next to the result.
struct CheckDetails: View {
    let check: SiteCheck

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(check.name).font(Typo.name)
            ForEach(check.probes) { probe in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Image(systemName: probe.answered ? "checkmark" : "xmark").accessibilityHidden(true)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(probe.answered ? Theme.ok : Theme.bad)
                            .frame(width: 11)
                        Text(probe.name).font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 12)
                        Text(probe.summary).font(Typo.mono).foregroundStyle(.secondary)
                    }
                    Text(probe.host)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 17)
                }
            }
            Divider()
            Text("Проверяются несколько адресов сайта: страница, картинки, видео, файлы. Если ответила только часть, чаще всего это случайная задержка. Неудачный адрес проверяется повторно.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .infoPanel(width: 320)
    }
}
