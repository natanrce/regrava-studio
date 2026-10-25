import CoreGraphics
import Foundation
import RegravaCore
import Testing
@testable import RegravaRender

struct SensitiveTextTests {
    struct Expect: Equatable, CustomStringConvertible {
        var kind: String
        var priority: Int
        var location: Int
        var length: Int
        var description: String { "\(kind) p\(priority) \(location)+\(length)" }
    }

    static func E(_ kind: String, _ priority: Int, _ location: Int, _ length: Int) -> Expect {
        Expect(kind: kind, priority: priority, location: location, length: length)
    }

    // Expected values are reference outputs of findSensitiveSpans(in:) on the same strings.
    static let lineCases: [(String, [Expect])] = [
        // emails
        ("Contact: john.doe@example.com for details", [E("email", 2, 9, 20)]),
        ("john.doe©example.com", [E("email", 2, 0, 20)]),
        ("mail me jane_smith [at] gmail [dot] com", [E("email", 2, 8, 31)]),
        ("logo@2x.png", []),
        ("Reply to ab@cd.io", []),
        ("user@Example.Com", []),
        // phones
        ("Call me at (415) 555-2671", [E("identifier", 1, 11, 14)]),
        ("+44 20 7946 0958", [E("phone", 3, 0, 16)]),
        ("Phone: 06 12 34 56 78", [E("identifier", 1, 7, 14)]),
        ("call 555 555 555", []),
        ("Order 123 456 789 shipped", []),
        // cards: Luhn-valid run, Luhn-invalid run, and a Luhn-invalid one printed 4-4-4-4 (still a card)
        ("card 4111111111111111", [E("card", 1, 5, 16)]),
        ("card 4111111111111112", []),
        ("Card: 4111 1111 1111 1111", [E("card", 1, 6, 19)]),
        ("Card: 4111 1111 1111 1112", [E("card", 1, 6, 19)]),
        ("1234 5678 9012 3456", []),
        ("IMEI 490154203237518", []),
        ("order #4111111111111111", []),
        // ibans
        ("GB82 WEST 1234 5698 7654 32", [E("iban", 1, 0, 27)]),
        ("GB82 WEST 1234 5698 7654 3", []),
        ("DE89 3704 0044 0532 0130 00 12", [E("iban", 1, 0, 27)]),
        ("DE89 3704 0044 0532 0130 00 Hello", []),
        ("PL61 1090 1014 0000 0712 1981 2874", [E("iban", 1, 0, 34)]),
        ("XX89 3704 0044 0532 0130 00", []),
        // nationalIDs
        ("SSN: 123-45-6789", [E("identifier", 1, 5, 11)]),
        ("SSN 000-12-3456", [E("identifier", 1, 4, 11)]),
        ("SSN 900-12-3456", [E("identifier", 1, 4, 11)]),
        ("DNI 12345678Z", [E("identifier", 1, 4, 9)]),
        ("DNI 12345678A", [E("identifier", 1, 4, 9)]),
        ("NIE X1234567L", [E("identifier", 1, 4, 9)]),
        ("CPF 529.982.247-25", [E("identifier", 1, 4, 14)]),
        ("CPF 529.982.247-24", [E("identifier", 1, 4, 14)]),
        ("NINO: AB 12 34 56 C", [E("identifier", 1, 6, 13)]),
        ("NIR 1 85 05 78 006 084 36", [E("identifier", 1, 4, 21)]),
        ("License: ABCDE-12345-FGHIJ-67890", [E("secret", 1, 9, 23)]),
        ("Key XXXXX-XXXXX-XXXXX-XXXXX", []),
        // addresses
        ("123 Main St, Springfield, IL 62704", [E("address", 2, 0, 34)]),
        ("Hauptstraße 5", [E("address", 2, 0, 13)]),
        ("Springfield, IL 62704", [E("address", 2, 0, 21)]),
        // network
        ("login from 203.0.113.42", [E("identifier", 2, 11, 12)]),
        ("from 192.168.1.10", []),
        ("inet6 2001:db8:85a3::8a2e:370:7334", [E("identifier", 2, 6, 28)]),
        ("inet6 2001:db8::1", []),
        ("MAC 00:1A:2B:3C:4D:5E", [E("identifier", 2, 4, 17)]),
        ("aa:bb:cc:dd:ee:ff", []),
        // vendorKeys
        ("sk_" + "live_51HxYzAbCdEf12345678", [E("apiKey", 0, 0, 28)]),
        ("gh" + "p_16C7e42F292c6912E7710c838347Ae178B4a", [E("apiKey", 0, 0, 40)]),
        ("AKIA" + "IOSFODNN7EXAMPLE", [E("apiKey", 0, 0, 20)]),
        ("xo" + "xb-123456789012-1234567890123-AbCdEfGhIjKlMnOpQrStUvWx", [E("apiKey", 0, 0, 56)]),
        ("sk-this-is-not-a-key", []),
        ("sk_live_YOUR_KEY_HERE", []),
        ("glpat-xxxxxxxxxxxxxxxxxxxx", []),
        // credentials
        ("password=hunter2abc", [E("secret", 1, 9, 10)]),
        ("password: hunter2", [E("secret", 1, 10, 7)]),
        ("my password is hunter2", [E("secret", 1, 15, 7)]),
        ("PASSWORD=changeme", []),
        ("password: ${PASSWORD}", []),
        ("token: true", []),
        ("secret = process.env.SECRET", []),
        ("the key is in the drawer", []),
        ("postgres://admin:s3cr3tP4ss@db.example.com:5432/app", [E("secret", 0, 0, 51)]),
        ("mongodb+srv://user:<password>@cluster0.mongodb.net", []),
        ("<password>MyS3cretP@ss</password>", [E("secret", 1, 10, 12)]),
        ("mysql -u root -pS3cretPass db", [E("secret", 1, 16, 10)]),
        ("https://api.example.com/v1?token=abc123XYZ789&x=1", [E("secret", 1, 33, 16)]),
        // randomAndCodes
        ("Token 9f8e7d6c5b4a39281706f5e4d3c2b1a0", [E("secret", 1, 6, 32)]),
        ("commit 9f8e7d6c5b4a39281706f5e4d3c2b1a0", []),
        ("aB3dE5fG7hJ9kL1mN2pQ", [E("secret", 1, 0, 20)]),
        ("AbCdEfGhIjKlMnOpQrSt", []),
        ("Your code is 123 456", [E("secret", 1, 13, 7)]),
        ("550e8400-e29b-41d4-a716-446655440000", [E("secret", 1, 0, 36)]),
        // seedPhrases
        ("abandon ability able about above absent absorb abstract absurd abuse access accident", [E("secret", 1, 0, 84)]),
        ("the quick brown fox jumps over the lazy dog again and again", []),
        ("1. abandon 2. ability 3. able 4. about", [E("secret", 1, 3, 35)]),
        // negatives
        ("Hello world", []),
        ("The meeting is at 10:30 tomorrow", []),
        ("Total: $1,234.56", []),
        ("Version 2.4.1 released", []),
        ("function getUserById(id) { return users[id]; }", []),
    ]

    @Test func perLineMatchesReference() {
        for (text, expected) in Self.lineCases {
            let got = Classifier.findSensitiveSpans(in: text).map { Expect(kind: $0.kind, priority: $0.priority, location: $0.range.location, length: $0.range.length) }
            #expect(got == expected, "\(text)")
        }
    }

    @Test func publicKindsAndLineEntryPoint() {
        let spans = SensitiveText.spans(inLine: "SSN: 123-45-6789")
        #expect(spans.count == 1)
        #expect(spans.first?.kind == .ssn)
        #expect(SensitiveText.spans(inLine: "sk_" + "live_51HxYzAbCdEf12345678").first?.kind == .apiKey)
        #expect(SensitiveText.spans(inLine: "Email: a.person@example.org").first?.kind == .email)
        #expect(SensitiveText.spans(inLine: "Hi").isEmpty)
    }

    @Test func checksums() {
        #expect(Classifier.isLuhnValid(Classifier.digitsOf("4111111111111111")))
        #expect(!Classifier.isLuhnValid(Classifier.digitsOf("4111111111111112")))
        #expect(Classifier.isIBANChecksumValid("GB82WEST12345698765432"))
        #expect(!Classifier.isIBANChecksumValid("GB82WEST12345698765433"))
        #expect(Classifier.isCPFValid(Classifier.digitsOf("529.982.247-25")))
        #expect(!Classifier.isCPFValid(Classifier.digitsOf("111.111.111-11")))
    }

    @Test func digitLookalikesAreFolded() {
        #expect(Classifier.foldDigitLookalikes("4l11 1111 1111 1111") == "4111 1111 1111 1111")
        #expect(Classifier.foldDigitLookalikes("Hello") == "Hello")
        #expect(SensitiveText.spans(inLine: "Card: 4111 1111 1111 111l").first?.kind == .card)
    }

    private func line(_ text: String, _ x: CGFloat, _ y: CGFloat, width: CGFloat? = nil) -> SensitiveTextLine {
        SensitiveTextLine(text: text, rect: CGRect(x: x, y: y, width: width ?? CGFloat(max(8 * text.count, 8)), height: 20))
    }

    private func frame(_ lines: [SensitiveTextLine]) -> [[Expect]] {
        Classifier.frameSpans(lines).map { $0.map { Expect(kind: $0.kind, priority: $0.priority, location: $0.range.location, length: $0.range.length) } }
    }

    // Expected values below are reference outputs of findSensitiveSpans(inFrame:).
    @Test func labelOnOneLineValueOnTheNext() {
        #expect(frame([line("Password", 10, 10), line("Xk9mP2vLqR", 10, 40)]) == [[], [Self.E("secret", 1, 0, 10)]])
        #expect(frame([line("Password", 10, 10), line("hunter2abc", 200, 10)]) == [[], [Self.E("secret", 1, 0, 10)]])
        #expect(frame([line("VAT number:", 10, 10), line("DE 123 456 789", 150, 10)]) == [[], [Self.E("identifier", 1, 0, 14)]])
        // Chrome is skipped, masked values and prose are left alone.
        #expect(frame([line("Client Secret", 10, 10), line("Reveal", 200, 10), line("8f14e45fceea167a5a36", 300, 10)]) == [[], [], [Self.E("secret", 1, 0, 20)]])
        #expect(frame([line("Client Secret", 10, 10), line("••••••••••", 200, 10)]) == [[], []])
        #expect(frame([line("Name", 10, 10), line("John Smith", 150, 10)]) == [[], []])
        #expect(frame([line("Secret", 10, 10), line("Hello there friend", 10, 40)]) == [[], []])
    }

    @Test func multiLineRules() {
        #expect(frame([line("export TOKEN=", 10, 10), line("ghx_abcdefghijklmnopqrstuv12", 10, 40)]) == [[], [Self.E("secret", 1, 0, 28)]])
        #expect(frame([line("$ echo $API_TOKEN", 10, 10), line("Zx81kLmQ9vT3pRw7", 10, 40)]) == [[], [Self.E("secret", 1, 0, 16)]])
        #expect(frame([line("Seed phrase", 10, 10), line("abandon ability able about above absent", 10, 40)]) == [[], [Self.E("secret", 1, 0, 39)]])
        #expect(frame([line("token = ab12cd34ef56gh78ij90kl12mn34op56qr78", 10, 10, width: 400), line("st90uv12wx34yz56", 10, 32, width: 400)])
                == [[Self.E("secret", 1, 8, 36)], [Self.E("secret", 1, 0, 16)]])
        #expect(frame([line("-----BEGIN RSA PRIVATE KEY-----", 10, 10), line("MIIEowIBAAKCAQEAu1SU1LfVLPHCozMxH2Mo", 10, 40),
                       line("4lgOEePzNm0tRgeLezV6ffAt0gunVTLw7onL", 10, 70), line("-----END RSA PRIVATE KEY-----", 10, 100)])
                == [[], [Self.E("secret", 1, 0, 36)], [Self.E("secret", 1, 0, 36)], []])
    }

    @Test func privateKeyBlockIsCovered() {
        // Lines with nothing else on them become privateKey spans.
        let spans = frame([line("-----BEGIN PRIVATE KEY-----", 10, 10), line("ab cd ef gh", 10, 40), line("-----END PRIVATE KEY-----", 10, 70)])
        #expect(spans == [[], [Self.E("privateKey", 1, 0, 11)], []])
    }

    @Test func customPhrasesIgnoreCaseAndAccents() {
        let lines = [line("Meeting with José Álvarez today", 10, 10), line("josé alvarez called", 10, 40), line("Joséphine", 10, 70)]
        let spans = SensitiveText.spans(in: lines, customPhrases: ["Jose Alvarez"]).filter { $0.kind == .custom }
        #expect(spans.map(\.line) == [0, 1])
        #expect(spans.first?.range == NSRange(location: 13, length: 12))
    }
}
