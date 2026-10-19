import SwiftUI

/// The switch of one service, the same in the sidebar, on the home page and in the menu bar panel: a green switch, or a small
/// spinner while the service is being switched, so that its state is never shown half way.
struct ServiceSwitch: View {
    let page: AppPage
    @ObservedObject private var all = AllServices.shared

    var body: some View {
        Group {
            if all.isPending(page) {
                ProgressView().controlSize(.small).frame(width: 38)
            } else {
                PillSwitch(isOn: all.isOn(page), disabled: all.isLocked(page)) { all.toggle(page) }
            }
        }
    }
}
