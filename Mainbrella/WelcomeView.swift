import SwiftUI

struct WelcomeView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    Image("BrandLogo").resizable().scaledToFit().frame(width: 40, height: 40).accessibilityHidden(true)
                    Text("Mainbrella").font(.title2.weight(.bold))
                }
                Text("Make a website.\nFrom your phone.").font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("welcome-headline")
                Text("Describe what you want, follow the build as it happens, and open your live website without leaving the app.")
                    .foregroundStyle(Theme.muted)
                VStack(alignment: .leading, spacing: 16) {
                    Label("Describe it in your own words", systemImage: "text.bubble")
                    Label("Follow messages and build progress", systemImage: "waveform.path")
                    Label("Try it, then ask for a change", systemImage: "rectangle.on.rectangle")
                }.font(.subheadline).padding(.vertical, 8)
                Text("Your websites and conversations stay saved to your account.")
                    .font(.subheadline).foregroundStyle(Theme.muted)
            }.padding(24).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                NavigationLink { AccountView() } label: {
                    HStack {
                        Text("Get started").fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "arrow.right").accessibilityHidden(true)
                    }.padding(.horizontal, 20).frame(minHeight: 52)
                        .foregroundStyle(.white).background(Theme.actionBlue, in: RoundedRectangle(cornerRadius: 10))
                }.accessibilityIdentifier("welcome-get-started")
                Text("Sign in or create an account").font(.footnote).foregroundStyle(Theme.muted)
            }.padding(24).dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .frame(maxWidth: 560).frame(maxWidth: .infinity).background(Theme.background)
        }
        .navigationTitle("Welcome").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .navigationBar)
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
