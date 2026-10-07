/// `mak8r-daemon` exit codes (design §15; sysexits where one fits).
public enum DaemonExitCode: Int32, Sendable, CaseIterable {
    case ok = 0
    /// `status`: something needs Matti's attention (needsLogin, safe mode, config problem).
    case attention = 1
    /// `status`: the daemon is not running or its status is stale.
    case notRunning = 2
    /// `EX_USAGE`
    case usage = 64
    /// `EX_DATAERR`: e.g. `rules check` on an invalid file.
    case invalidData = 65
    /// `EX_UNAVAILABLE`: offline, OAuth config missing, timeout.
    case unavailable = 69
    /// `EX_TEMPFAIL`: the instance lock is held; launchd restarts a non-zero exit (`KeepAlive {SuccessfulExit=false}`).
    case lockHeld = 75
    /// `EX_NOPERM`: wrong account, consent denied or scope missing.
    case wrongAccount = 77
}
