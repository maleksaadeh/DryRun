import StoreKit
import SwiftUI

/// The subscription screen.
///
/// Guideline 3.1.2 requires the price, the renewal term, a restore path, and links to the terms
/// and the privacy policy to all be visible before the purchase button.
struct PaywallView: View {

    let entitlements: Entitlements

    @Environment(\.dismiss) private var dismiss

    static let termsURL = URL(string: "https://example.com/dryrun/terms")!
    static let privacyURL = URL(string: "https://example.com/dryrun/privacy")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    benefits
                    Divider().overlay(.white.opacity(0.15))
                    disclosure
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) { actions }
            .navigationTitle("DryRun Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
            }
        }
        .task { await entitlements.load() }
        .onChange(of: entitlements.isUnlocked) { _, unlocked in
            if unlocked { dismiss() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Any colour, on any wall")
                .font(.title2.weight(.semibold))
            Text("The three built-in colours stay free. Pro adds the ones you specify yourself.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 14) {
            benefit("paintpalette", "Unlimited custom colours",
                    "Any brand, any custom mix. Enter the hex and the published LRV.")
            benefit("sun.max", "Rendered under the room's own light",
                    "The LRV drives the lightness, so the colour holds up as the light changes.")
            benefit("square.and.arrow.up", "Captures you can hand to a client",
                    "Every shot files the colour name, code and LRV alongside it.")
        }
    }

    private func benefit(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .frame(width: 26)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("""
                 Billed to your Apple Account. Renews yearly unless cancelled at least 24 hours \
                 before the period ends. Manage or cancel in Settings.
                 """)
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Link("Terms of Use", destination: Self.termsURL)
                Link("Privacy Policy", destination: Self.privacyURL)
            }
            .font(.caption2)
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if let failure = entitlements.failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await entitlements.purchase() }
            } label: {
                Group {
                    if entitlements.isWorking {
                        ProgressView()
                    } else if entitlements.product == nil {
                        Text("Loading…")
                    } else {
                        VStack(spacing: 1) {
                            Text(entitlements.offersTrial ? "Start free trial" : "Subscribe")
                                .font(.headline)
                            Text(entitlements.priceLine)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(entitlements.product == nil || entitlements.isWorking)

            Button("Restore purchases") {
                Task { await entitlements.restore() }
            }
            .font(.footnote)
            .disabled(entitlements.isWorking)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }
}
