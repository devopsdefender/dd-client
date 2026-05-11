import SwiftUI
import UIKit

/// Initial screen when no session is linked. Two clear paths:
/// (1) sign in with GitHub and pick from the fleet, or (2) wait for a
/// desktop-generated `devopsdefender://session?...` deep link.
struct LaunchView: View {
    @ObservedObject var viewModel: ClientViewModel
    @State private var isAuthenticating = false
    @State private var authError: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(LaunchPalette.accent)
                Text("DevOps Defender")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(LaunchPalette.text)
                Text("Mobile client for live Claude Code sessions")
                    .font(.subheadline)
                    .foregroundStyle(LaunchPalette.muted)
            }

            Spacer()

            VStack(spacing: 14) {
                Button {
                    Task { await signIn() }
                } label: {
                    HStack(spacing: 10) {
                        if isAuthenticating {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                        } else {
                            Image(systemName: "logo.github")
                                .renderingMode(.template)
                        }
                        Text(isAuthenticating ? "Signing in…" : "Sign in with GitHub")
                            .font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(LaunchPalette.accent)
                .disabled(isAuthenticating)

                Text("or")
                    .font(.caption)
                    .foregroundStyle(LaunchPalette.muted)

                VStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.callout)
                        .foregroundStyle(LaunchPalette.muted)
                    Text("Open a devopsdefender:// link from your desktop CLI to attach to a specific session.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(LaunchPalette.muted)
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, 24)

            if let authError {
                Text(authError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LaunchPalette.background)
    }

    private func signIn() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        authError = nil
        defer { isAuthenticating = false }
        do {
            let pubkey = try AppKeyStore.shared.ensurePubkeyHex()
            let label = await MainActor.run { UIDevice.current.name }
            let service = await MainActor.run { OAuthService() }
            let token = try await service.signIn(
                baseURL: FleetAPIClient.defaultCPBaseURL,
                pubkey: pubkey,
                label: label
            )
            KeychainStore().setString(token, for: .bearerToken)
            viewModel.enterFleet()
        } catch let error as OAuthError {
            if case .cancelled = error { return }
            authError = error.localizedDescription
        } catch {
            authError = error.localizedDescription
        }
    }
}

private enum LaunchPalette {
    static let background = Color(red: 0.96, green: 0.94, blue: 0.90)
    static let text = Color(red: 0.16, green: 0.14, blue: 0.11)
    static let muted = Color(red: 0.42, green: 0.37, blue: 0.30)
    static let accent = Color(red: 0.32, green: 0.30, blue: 0.62)
}
