import Foundation

/// Classifies Gmail errors for the label code (conventions §0) and the daemon.
public enum GmailFailure {
    public static func status(_ error: any Error) -> Int? {
        if case .http(let status, _) = error as? GmailError { return status }
        return nil
    }

    /// `labels.create` refused the name: 409 (exists) or 400 (reserved or invalid).
    public static func isCreateConflict(_ error: any Error) -> Bool {
        status(error) == 409 || status(error) == 400
    }

    /// `modify` with an ID that may have been deleted elsewhere. Gmail's code for it is undocumented.
    public static func mayBeStaleLabelID(_ error: any Error) -> Bool {
        status(error) == 400 || status(error) == 404
    }

    public static func isNotFound(_ error: any Error) -> Bool {
        status(error) == 404
    }

    /// Task cancellation. URLSession reports it as URLError(.cancelled), not CancellationError.
    public static func isCancellation(_ error: any Error) -> Bool {
        if let e = error as? URLError, e.code == .cancelled { return true }
        return error is CancellationError
    }

    /// The quota transport gave up: Gmail kept rate limiting the request through its deadline.
    public static func isRateLimited(_ error: any Error) -> Bool {
        (error as? GmailError) == .rateLimited
    }

    /// Ends a wake pass: retrying other threads cannot succeed (offline, signed out, or Gmail
    /// rate limiting: each further GET would only wait out its own deadline).
    public static func abortsPass(_ error: any Error) -> Bool {
        if let e = error as? GmailError, e == .offline || e == .rateLimited { return true }
        return error is AuthError || isCancellation(error)
    }

    /// What an aborted pass throws: cancellation always as CancellationError.
    public static func passAbort(_ error: any Error) -> any Error {
        isCancellation(error) ? CancellationError() : error
    }
}
