import SwiftUI

/// The page of the neural networks: the planet under its halo, and the list of the DNS services below.
struct AIPage: View {
    @ObservedObject var model: DNSViewModel

    var body: some View {
        VStack(spacing: 0) {
            DNSHero(model: model)
            ScrollView {
                ProvidersSection(model: model)
                    .padding(.horizontal, Space.page)
                    .padding(.vertical, Space.s)
            }
            .scrollIndicators(.hidden)
        }
    }
}
