import Foundation
import Testing
@testable import MailCore

@Suite struct SignatureInserterTests {
    let long = Signature(name: "Pitkä", text: "Maija Meikalainen\nEsimerkki Oy")
    let short = Signature(name: "Lyhyt", text: "-S")

    @Test func swapsUntouchedSignature() {
        let body = "Hei!\n\n-- \nMaija Meikalainen\nEsimerkki Oy\n\nPe 1.9.2026 klo 9.00 Matti kirjoitti:\n> moi"
        let out = SignatureInserter.replace(long, with: short, in: body, insertionPoint: nil)
        #expect(out == "Hei!\n\n-- \n-S\n\nPe 1.9.2026 klo 9.00 Matti kirjoitti:\n> moi")
    }

    @Test func removingSignatureDropsBlockAndItsLeadingBlankLines() {
        let body = "Hei!\n\n-- \nMaija Meikalainen\nEsimerkki Oy"
        #expect(SignatureInserter.replace(long, with: nil, in: body, insertionPoint: nil) == "Hei!")
    }

    @Test func editedSignatureIsKeptAndNewOneInsertedAtPoint() {
        let body = "Hei!\n\n-- \nMaija M. (muokattu)"
        let point = body.index(body.startIndex, offsetBy: 4)
        let out = SignatureInserter.replace(long, with: short, in: body, insertionPoint: point)
        #expect(out == "Hei!\n\n-- \n-S\n\n-- \nMaija M. (muokattu)")
    }

    @Test func noInsertionPointAppends() {
        #expect(SignatureInserter.replace(nil, with: short, in: "Hei!", insertionPoint: nil) == "Hei!\n\n-- \n-S")
    }

    @Test func onlyFirstOccurrenceIsReplaced() {
        let dash = Signature(name: "Viiva", text: "-- \nx")
        let body = "a\n\n-- \n-- \nx\n\n-- \n-- \nx"
        let out = SignatureInserter.replace(dash, with: short, in: body, insertionPoint: nil)
        #expect(out == "a\n\n-- \n-S\n\n-- \n-- \nx")
    }

    @Test func sameSignatureIsNoOp() {
        let body = "a\n\n-- \n-S"
        #expect(SignatureInserter.replace(short, with: short, in: body, insertionPoint: nil) == body)
        #expect(SignatureInserter.replace(nil, with: nil, in: body, insertionPoint: nil) == body)
    }

    @Test func signatureFollowedByTypedTextCountsAsEdited() {
        let body = "Hei!\n\n-- \n-Maija"
        let out = SignatureInserter.replace(short, with: long, in: body, insertionPoint: nil)
        #expect(out == "Hei!\n\n-- \n-Maija\n\n-- \nMaija Meikalainen\nEsimerkki Oy")
    }
}
