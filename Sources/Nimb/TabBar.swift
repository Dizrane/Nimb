import SwiftUI

/// Three switches at the top of the window. A green dot shows which of the three is working right now.
struct TabBar: View {
    @Binding var selection: AppTab
    let isOn: (AppTab) -> Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(AppTab.allCases.enumerated()), id: \.element.id) { index, tab in
                if index > 0 { Spacer(minLength: 0) }
                segment(tab)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.black.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .padding(.horizontal, 12)
    }

    /// A segment is as wide as its name; the free room is shared evenly between the segments.
    private func segment(_ tab: AppTab) -> some View {
        let selected = selection == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { selection = tab }
        } label: {
            HStack(spacing: 4) {
                if tab == .home {
                    Image(systemName: "house")
                        .font(.system(size: 13, weight: .regular))
                        .padding(.horizontal, 3)
                } else {
                    Text(tab.title)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                    // The dot always takes its room, so that nothing shifts when a service turns on.
                    Circle()
                        .fill(isOn(tab) ? Theme.ok : Color.clear)
                        .frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(selected ? 0.12 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(tab.title + (isOn(tab) ? ", включено" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
