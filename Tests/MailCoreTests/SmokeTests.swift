import Testing
@testable import MailCore

@Test func versionIsSet() {
    #expect(!MailCoreInfo.version.isEmpty)
}
