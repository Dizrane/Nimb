import SwiftUI

/// The graphite power button of the pages without a figure (the home page): a disc in a thin ring that turns green when on.
struct PowerDisc: View {
    let isOn: Bool
    let isBusy: Bool
    let hover: Double

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder((isOn ? Theme.ok : Color.white).opacity(isOn ? 0.55 : 0.12 + 0.16 * hover), lineWidth: 1)
                .frame(width: 146, height: 146)
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                .overlay(
                    Circle().strokeBorder(
                        LinearGradient(colors: [(isOn ? Theme.ok : Color.white).opacity(0.55 + 0.3 * hover), Color.white.opacity(0.10 + 0.1 * hover)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1.2
                    )
                )
                .frame(width: 120, height: 120)
                .shadow(color: .black.opacity(0.6), radius: 16, y: 9)
            if isBusy {
                ProgressView().controlSize(.regular).tint(.white)
            } else {
                Image(systemName: "power")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(isOn ? Theme.ok : Color.white.opacity(0.9 + 0.1 * hover))
            }
        }
    }
}
