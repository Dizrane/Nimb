import SwiftUI

/// The page of the neural networks: the planet under its halo on the left, the DNS services in a grid on the right.
struct AIPage: View {
    @ObservedObject var model: DNSViewModel

    var body: some View {
        TwoColumns {
            DNSHero(model: model)
        } right: {
            ProvidersSection(model: model)
        }
    }
}
