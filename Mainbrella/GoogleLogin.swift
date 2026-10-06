import GoogleSignIn
import UIKit

enum GoogleLogin {
    @MainActor static func credential() async throws -> String {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var presenter = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            throw SignInError.invalidSession
        }
        while let presented = presenter.presentedViewController { presenter = presented }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let token = result.user.idToken?.tokenString else { throw SignInError.invalidSession }
            return token
        } catch {
            let failure = error as NSError
            if failure.domain == kGIDSignInErrorDomain && failure.code == GIDSignInError.canceled.rawValue {
                throw CancellationError()
            }
            throw SignInError.response("google_unavailable")
        }
    }
}
