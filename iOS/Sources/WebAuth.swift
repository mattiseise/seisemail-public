import AuthenticationServices
import MailCore
import UIKit

/// Shows Google's consent page in an ASWebAuthenticationSession and returns the redirect URL.
@MainActor
enum WebAuth {
    private static var current: ASWebAuthenticationSession?
    private static let anchor = PresentationAnchor()

    static func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { callback, error in
                    current = nil
                    if let callback {
                        continuation.resume(returning: callback)
                    } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: error ?? AuthError.badResponse)
                    }
                }
                session.presentationContextProvider = anchor
                current = session
                if !session.start() {
                    current = nil
                    continuation.resume(throwing: AuthError.badResponse)
                }
            }
        } onCancel: {
            Task { @MainActor in current?.cancel() }
        }
    }
}

private final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
        }
    }
}
