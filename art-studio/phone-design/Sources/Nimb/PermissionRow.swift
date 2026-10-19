import SwiftUI

/// A permission Nimb can hold: what it is for, what it costs, and a button to give or take it back.
struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let disabled: Bool
    var note: String? = nil
    var extraTitle: String? = nil
    var extraAction: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s + 2) {
            HStack(spacing: Space.s) {
                Image(systemName: granted ? "lock.open" : "lock")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(granted ? Theme.warn : Theme.textSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(Typo.name)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: Space.s)
                Text(granted ? "Без пароля" : "С паролем")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.0)
                    .textCase(.uppercase)
                    .foregroundStyle(granted ? Theme.warn : Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder((granted ? Theme.warn : Color.white).opacity(0.35), lineWidth: 1))
            }
            Text(detail)
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let note {
                Text(note)
                    .font(Typo.small)
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.s) {
                Spacer()
                if let extraTitle, let extraAction {
                    OutlineButton(title: extraTitle, color: Theme.textPrimary, action: extraAction)
                        .disabled(disabled)
                }
                OutlineButton(title: granted ? "Забрать" : "Разрешить", color: Theme.textPrimary, action: action)
                    .disabled(disabled)
            }
        }
        .card()
    }
}
