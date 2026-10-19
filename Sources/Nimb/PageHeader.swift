import SwiftUI

/// The top of a page that replaces the tabs (the settings): the title in the serif and a button on the right.
struct PageHeader: View {
    let title: String
    let buttonTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 22, weight: .regular, design: .serif))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let buttonTitle {
                Button(action: action) {
                    Text(buttonTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, Space.s)
                        .padding(.vertical, Space.xs + 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, Space.page)
        .padding(.top, 20)
        .padding(.bottom, Space.m)
    }
}
