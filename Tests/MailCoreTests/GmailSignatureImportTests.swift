import Foundation
import Testing
@testable import MailCore

@Suite struct GmailSignatureImportTests {
    @Test func convertsHTMLAndSkipsEmptyAndDuplicates() {
        let remote = [
            SendAsSignature(email: "maija@example.fi", html: "<div>Maija Meikalainen<br>Esimerkki&nbsp;Oy</div>"),
            SendAsSignature(email: "alias@example.fi", html: ""),
            SendAsSignature(email: "tyhja@example.fi", html: "<div> </div>"),
        ]
        let first = GmailSignatureImport.newSignatures(from: remote, existing: [])
        #expect(first.map(\.name) == ["maija@example.fi"])
        #expect(first.map(\.text) == ["Maija Meikalainen\nEsimerkki Oy"])
        #expect(GmailSignatureImport.newSignatures(from: remote, existing: first).isEmpty)
    }
}
