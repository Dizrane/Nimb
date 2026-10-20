import SwiftUI

/// A switch drawn by the app: green when on, dark when off, the same whether the window is the one in front or not. The system
/// switch goes grey in a window that is not in front, which is what the panel of the menu bar usually is.
struct PillSwitch: View {
    let isOn: Bool
    var disabled = false
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.ok : Color.white.opacity(0.16))
                Circle()
                    .fill(Color.white.opacity(0.94))
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                    .padding(2)
            }
            .frame(width: 38, height: 22)
            .animation(.easeOut(duration: 0.15), value: isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .accessibilityRepresentation {
            Toggle("", isOn: Binding(get: { isOn }, set: { _ in toggle() })).disabled(disabled)
        }
    }
}
