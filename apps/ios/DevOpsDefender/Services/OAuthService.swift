import AuthenticationServices
import Foundation
import UIKit

enum OAuthError: LocalizedError {
    case cancelled
    case missingToken
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign in cancelled"
        case .missingToken: return "Sign-in did not return a token"
        case .underlying(let m): return m
        }
    }
}

/// Wraps `ASWebAuthenticationSession` for the iOS-side GitHub OAuth
/// dance. The CP at `<baseURL>/oauth/ios/start?pubkey=&label=` runs the
/// usual GitHub flow then 302s back to `devopsdefender://oauth/callback?token=<jwt>`
/// — we parse the token from the callback URL and hand it back.
@MainActor
final class OAuthService: NSObject {
    static let callbackScheme = "devopsdefender"
    static let callbackHost = "oauth"
    static let callbackPath = "/callback"

    private var session: ASWebAuthenticationSession?

    /// Open the OAuth flow. Returns the bearer token from the callback.
    func signIn(baseURL: URL, pubkey: String, label: String) async throws -> String {
        let start = baseURL
            .appendingPathComponent("/oauth/ios/start")
        var components = URLComponents(url: start, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "pubkey", value: pubkey),
            URLQueryItem(name: "label", value: label)
        ]
        guard let url = components?.url else {
            throw OAuthError.underlying("Could not build OAuth start URL")
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: OAuthService.callbackScheme
            ) { callbackURL, error in
                if let error {
                    if let auth = error as? ASWebAuthenticationSessionError,
                       auth.code == .canceledLogin {
                        continuation.resume(throwing: OAuthError.cancelled)
                    } else {
                        continuation.resume(throwing: OAuthError.underlying(error.localizedDescription))
                    }
                    return
                }
                guard let callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
                      !token.isEmpty else {
                    continuation.resume(throwing: OAuthError.missingToken)
                    return
                }
                continuation.resume(returning: token)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: OAuthError.underlying("ASWebAuthenticationSession refused to start"))
            }
        }
    }
}

extension OAuthService: ASWebAuthenticationPresentationContextProviding {
    /// ASWebAuthenticationSession calls this delegate on the main thread.
    /// Using `DispatchQueue.main.sync` here deadlocks (re-entrant wait on
    /// the same queue) — that's the EXC_BREAKPOINT we hit. Use
    /// `MainActor.assumeIsolated` to access main-actor-isolated UIKit
    /// state without an async hop.
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let keyWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
            return keyWindow ?? ASPresentationAnchor()
        }
    }
}
