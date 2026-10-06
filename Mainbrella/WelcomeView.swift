import SwiftUI

struct WelcomeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize = 36
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(spacing: 12) {
                    Image("BrandLogo").resizable().scaledToFit().frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                    Text("Mainbrella").font(.title2.weight(.bold))
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text("Close your laptop.")
                        .foregroundStyle(.primary)
                    + Text("\nKeep them working.")
                        .foregroundStyle(Theme.blue)
                }
                .font(.system(size: min(headlineSize, 64), weight: .bold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("welcome-headline")

                Text("A cloud home for your coding agents. Stay close to their work, wherever you are.")
                    .font(.title3).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, -16)

                AgentJourneyView()
                    .padding(.vertical, 8)

                VStack(alignment: .leading, spacing: 24) {
                    Text("Your phone. The remote control.")
                        .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    feature("Follow the work", symbol: "waveform.path", description: "See running tasks, results, and execution output.")
                    feature("Open the preview", symbol: "rectangle.on.rectangle", description: "Check the build. Mark up a screenshot to show what needs fixing.")
                    feature("Send the next instruction", symbol: "paperplane", description: "Share a note, link, photo, or file with a running workspace.")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("A home for agents that stay with you.")
                        .font(.headline).accessibilityAddTraits(.isHeader)
                    Text("Coming next: persistent Codex and Claude Code sessions, laptop-to-cloud handoff, approval requests, and completion alerts.")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 32)
            .frame(maxWidth: 620, alignment: .leading).frame(maxWidth: .infinity)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 8)
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                NavigationLink {
                    AccountView()
                } label: {
                    HStack {
                        Text("Get started").fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "arrow.right").accessibilityHidden(true)
                    }
                    .padding(.horizontal, 20).frame(minHeight: 52)
                    .foregroundStyle(.white).background(Theme.actionBlue, in: RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityIdentifier("welcome-get-started")
                Text("Sign in or create an account")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            // Keep the pinned action from consuming the viewport at the largest text sizes.
            // The scrollable marketing content continues to use the user's full text size.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .frame(maxWidth: 620).frame(maxWidth: .infinity)
            .background(Theme.background)
        }
        .navigationTitle("Welcome").navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { appeared = true }
        }
    }

    private func feature(_ title: String, symbol: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Theme.blue)
                .frame(width: 24, height: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(description).font(.subheadline).foregroundStyle(Theme.muted)
            }
        }.accessibilityElement(children: .combine)
    }
}

/// A product illustration, rather than simulated account activity.
private struct AgentJourneyView: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("THE IDEA").font(.caption.weight(.medium)).tracking(2).foregroundStyle(Theme.muted)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    stage("Mac closed", symbol: "laptopcomputer", detail: "Step away")
                    connector
                    stage("Cloud agent", symbol: "cloud", detail: "Keep working", highlighted: true)
                    connector
                    stage("Your phone", symbol: "iphone", detail: "Stay in control")
                }
                VStack(spacing: 20) {
                    stage("Laptop closed", symbol: "laptopcomputer", detail: "Step away")
                    Image(systemName: "arrow.down").foregroundStyle(Theme.muted).accessibilityHidden(true)
                    stage("Agent in the cloud", symbol: "cloud", detail: "Keep working", highlighted: true)
                    Image(systemName: "arrow.down").foregroundStyle(Theme.muted).accessibilityHidden(true)
                    stage("Phone in hand", symbol: "iphone", detail: "Stay in control")
                }
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The idea: close your laptop, keep your agent working in the cloud, and stay in control from your phone.")
    }

    private var connector: some View {
        Image(systemName: "arrow.right").font(.caption).foregroundStyle(Theme.muted).accessibilityHidden(true)
    }

    private func stage(_ title: String, symbol: String, detail: String, highlighted: Bool = false) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: highlighted ? 42 : 32, weight: .light))
                .foregroundStyle(highlighted ? Theme.blue : Theme.muted)
                .frame(height: 52)
            Text(title).font(.caption.weight(.semibold)).fixedSize()
            Text(detail).font(.caption).foregroundStyle(Theme.muted).fixedSize()
        }
    }
}

struct SplashView: View {
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 12) {
                Image("BrandLogo").resizable().scaledToFit().frame(width: 112, height: 112)
                    .accessibilityHidden(true)
                Text("Mainbrella").font(.system(size: 24, weight: .bold))
            }
            VStack {
                Spacer()
                ProgressView("Opening Mainbrella…").font(.footnote).tint(Theme.blue)
                    .foregroundStyle(Theme.muted).padding(.bottom, 32)
            }
        }
        .accessibilityIdentifier("launch-splash")
    }
}
