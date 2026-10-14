import SwiftUI

struct ComputeCreditView: View {
    @EnvironmentObject private var credits: ComputeCreditStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let balance = credits.balance {
                LabeledContent("Available compute credit", value: balance.formatted)
                    .font(.subheadline).accessibilityIdentifier("compute-balance")
            }
            if let quote = credits.quote, let product = credits.product {
                Button {
                    Task { await credits.purchase() }
                } label: {
                    HStack(spacing: 8) {
                        if credits.purchasing { ProgressView() }
                        Text("Add compute credit · \(product.displayPrice)")
                    }.frame(minHeight: 44)
                }.disabled(!credits.canPurchase).accessibilityIdentifier("buy-compute-credit")
                Text("Adds \(quote.formattedCredit) after App Store fees and taxes. One-time purchase for building and running websites.")
                    .font(.caption).foregroundStyle(Theme.muted)
            } else if credits.loading {
                ProgressView("Loading compute credit…").font(.subheadline).frame(minHeight: 44)
            }
            if let message = credits.message {
                Text(message).font(.subheadline).foregroundStyle(Theme.muted)
                    .accessibilityIdentifier("compute-purchase-message")
            }
            if let error = credits.error {
                Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.orange)
                    .accessibilityIdentifier("compute-purchase-error")
            }
            Button(credits.checking ? "Checking purchases…" : "Check purchases") {
                Task { await credits.refresh() }
            }.font(.subheadline).frame(minHeight: 44).disabled(credits.loading || credits.busy)
                .accessibilityIdentifier("check-compute-purchases")
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
