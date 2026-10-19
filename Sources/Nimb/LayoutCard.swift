import SwiftUI

/// One of the two layouts of the window in the settings: a small scheme of it, its name and a line about it. The chosen one has
/// a light border.
struct LayoutCard: View {
    let option: WindowLayout
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 8) {
                scheme
                    .frame(height: 62)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title).font(Typo.name).foregroundStyle(Theme.textPrimary)
                    Text(option.detail).font(Typo.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.68)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(selected ? 0.6 : 0.14), lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A drawing of the window: a list on the left, or tabs on top.
    private var scheme: some View {
        Canvas { ctx, size in
            let bar = Color.white.opacity(0.22)
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6), with: .color(Color.black.opacity(0.7)))
            if option == .sidebar {
                let side = size.width * 0.3
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: side, height: size.height), cornerRadius: 6), with: .color(Color.white.opacity(0.08)))
                for i in 0..<3 {
                    ctx.fill(Path(roundedRect: CGRect(x: 6, y: 9 + CGFloat(i) * 12, width: side - 12, height: 5), cornerRadius: 2.5), with: .color(bar))
                }
                ctx.fill(Path(roundedRect: CGRect(x: side + 10, y: 12, width: (size.width - side) * 0.55, height: 6), cornerRadius: 3), with: .color(bar))
                ctx.fill(Path(roundedRect: CGRect(x: side + 10, y: 26, width: (size.width - side) * 0.75, height: 6), cornerRadius: 3), with: .color(bar))
            } else {
                ctx.fill(Path(roundedRect: CGRect(x: 6, y: 6, width: size.width * 0.14, height: 8), cornerRadius: 3), with: .color(bar))
                ctx.fill(Path(roundedRect: CGRect(x: size.width * 0.26, y: 6, width: size.width * 0.22, height: 8), cornerRadius: 3), with: .color(Color.white.opacity(0.4)))
                ctx.fill(Path(roundedRect: CGRect(x: size.width * 0.52, y: 6, width: size.width * 0.18, height: 8), cornerRadius: 3), with: .color(bar))
                ctx.fill(Path(roundedRect: CGRect(x: 10, y: 26, width: size.width - 20, height: 6), cornerRadius: 3), with: .color(bar))
                ctx.fill(Path(roundedRect: CGRect(x: 10, y: 40, width: (size.width - 20) * 0.65, height: 6), cornerRadius: 3), with: .color(bar))
            }
        }
    }
}
