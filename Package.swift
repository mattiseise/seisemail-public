// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Mak8rMail",
    defaultLocalization: "fi",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .executable(name: "Mak8rMail", targets: ["Mak8rMail"]),
        .executable(name: "mak8r-daemon", targets: ["Mak8rDaemon"]),
        .library(name: "MailCore", targets: ["MailCore"]),
    ],
    targets: [
        .target(name: "MailCore"),
        // The Mac mini daemon's testable logic (docs/design/phase2-daemon.md §3).
        .target(name: "DaemonCore", dependencies: ["MailCore"]),
        .executableTarget(name: "Mak8rMail", dependencies: ["MailCore"]),
        // Thin glue: argv, signals, the notify hook `Process` and `/usr/bin/open` (§3, D1).
        .executableTarget(name: "Mak8rDaemon", dependencies: ["DaemonCore", "MailCore"]),
        .testTarget(
            name: "MailCoreTests",
            dependencies: ["MailCore", "DaemonCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
