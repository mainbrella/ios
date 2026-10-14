import SwiftUI

struct ComputeCreditView: View {
    @EnvironmentObject private var credits: ComputeCreditStore
    @State private var showingFunding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let balance = credits.balance {
                LabeledContent("Available compute credit", value: balance.formatted)
                    .font(.subheadline).accessibilityIdentifier("compute-balance")
            }
            if let balance = credits.balance, balance.availableBalanceCents <= 0 {
                Text("Add at least \(credits.product?.displayPrice ?? "$4.99") to get started.")
                    .font(.subheadline).foregroundStyle(Theme.muted)
                    .accessibilityIdentifier("compute-funding-required")
            }
            Button("Add funds") { showingFunding = true }
                .font(.subheadline).frame(minHeight: 44)
                .accessibilityIdentifier("add-compute-funds")
            if let message = credits.message {
                Text(message).font(.subheadline).foregroundStyle(Theme.muted)
                    .accessibilityIdentifier("compute-purchase-message")
            }
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showingFunding) { ComputeFundingView() }
    }
}

private struct ComputeFundingView: View {
    @EnvironmentObject private var credits: ComputeCreditStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let balance = credits.balance {
                        LabeledContent("Available compute credit", value: balance.formatted)
                    }
                    if let quote = credits.quote, let product = credits.product {
                        Button {
                            Task { await credits.purchase() }
                        } label: {
                            HStack(spacing: 8) {
                                if credits.purchasing { ProgressView() }
                                Text("Add funds · \(product.displayPrice)")
                            }.frame(minHeight: 44)
                        }.disabled(!credits.canPurchase).accessibilityIdentifier("buy-compute-credit")
                        Text("Adds \(quote.formattedCredit) after App Store fees and taxes. One-time purchase for building and running websites.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    } else if credits.loading {
                        ProgressView("Loading purchase options…").frame(minHeight: 44)
                    } else if let error = credits.availabilityError {
                        Text(error).font(.subheadline).foregroundStyle(Theme.muted)
                            .accessibilityIdentifier("compute-availability-error")
                    }
                    if let message = credits.message {
                        Text(message).font(.subheadline).foregroundStyle(Theme.muted)
                    }
                    if let error = credits.error {
                        Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.orange)
                            .accessibilityIdentifier("compute-purchase-error")
                    }
                    Button(credits.checking ? "Checking purchases…" : credits.quote == nil ? "Try again" : "Check purchases") {
                        Task { await credits.refresh() }
                    }.frame(minHeight: 44).disabled(credits.loading || credits.busy)
                        .accessibilityIdentifier("check-compute-purchases")
                }.listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Add funds").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task { await credits.refresh() }
        .interactiveDismissDisabled(credits.purchasing)
    }
}
