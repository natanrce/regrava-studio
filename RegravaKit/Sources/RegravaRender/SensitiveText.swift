import CoreGraphics
import Foundation
import RegravaCore

// The text classifier that turns OCR lines into spans to cover.
//
// The regexes, lists and the BIP-39 wordlist live in Resources/SensitiveData/rules.json and
// bip39.txt and are looked up here by name.
//
// Kinds. The finders store these strings in `TextSpan.kind`, and `detectionObjects`
// reports them unchanged:
//   email, phone, card, iban, address, secret, apiKey, privateKey → the case of the same name;
//   ssn (US SSN 3-2-4)                                           → .ssn;
//   identifier (labelled IDs, VAT, NINO, PAN, CPF, DNI/NIE, NIR,
//               MRZ, DOB, card expiry/CVC, BIC, IP, MAC, wallets) → .ssn.
// `.ssn` is the public kind closest to "national/personal identifier" and is used for
// all of them.

/// One OCR'd line of a frame.
public struct SensitiveTextLine: Sendable {
    public var text: String
    /// Video pixels, top-left origin.
    public var rect: CGRect

    public init(text: String, rect: CGRect) {
        self.text = text
        self.rect = rect
    }
}

/// A part of one line to cover.
public struct SensitiveTextSpan: Hashable, Sendable {
    public var line: Int
    /// UTF-16 range in that line's text.
    public var range: NSRange
    public var kind: SensitiveDataKind
    /// Lower wins when spans overlap (`mergeSpans`).
    public var priority: Int

    public init(line: Int, range: NSRange, kind: SensitiveDataKind, priority: Int) {
        self.line = line
        self.range = range
        self.kind = kind
        self.priority = priority
    }
}

public enum SensitiveText {
    /// One OCR'd frame (lines in reading order) → spans to cover, merged by `mergeSpans`. Text
    /// spans come from `findSensitiveSpans(inFrame:)`; custom phrases from `PhraseLayer`,
    /// which form their own layer, so they are added after, unmerged.
    public static func spans(in lines: [SensitiveTextLine], customPhrases: [String]) -> [SensitiveTextSpan] {
        var out: [SensitiveTextSpan] = []
        for (index, lineSpans) in Classifier.frameSpans(lines).enumerated() {
            for span in lineSpans {
                out.append(SensitiveTextSpan(line: index, range: span.range, kind: publicKind(span.kind), priority: span.priority))
            }
        }
        let layers = customPhrases.compactMap(PhraseLayer.init(phrase:))
        for layer in layers {
            for (index, line) in lines.enumerated() {
                for range in layer.ranges(in: line.text) {
                    // Phrase findings are not TextSpans, so they have no priority; 1 is used.
                    out.append(SensitiveTextSpan(line: index, range: range, kind: .custom, priority: 1))
                }
            }
        }
        return out
    }

    /// Per-line entry point used by the above (`findSensitiveSpans(in:)`).
    public static func spans(inLine text: String) -> [(range: NSRange, kind: SensitiveDataKind, priority: Int)] {
        Classifier.findSensitiveSpans(in: text).map { (range: $0.range, kind: publicKind($0.kind), priority: $0.priority) }
    }

    static func publicKind(_ kind: String) -> SensitiveDataKind {
        switch kind {
        case "email": .email
        case "phone": .phone
        case "address": .address
        case "card": .card
        case "iban": .iban
        case "apiKey": .apiKey
        case "privateKey": .privateKey
        case "ssn", "identifier": .ssn
        default: .secret
        }
    }
}

// MARK: - Spans

/// `TextSpan { kind: String, priority: Int, range: NSRange }`.
struct TextSpan: Hashable {
    var kind: String
    var priority: Int
    var range: NSRange
}

extension NSRange {
    fileprivate var end: Int { location + length }
}

/// `mergeSpans(_:)`: drop empty ranges, stable sort by location, merge overlapping spans
/// (touching ones stay apart) into their union, keeping the kind and priority of the span with
/// the lower priority number (the earlier one on a tie).
func mergeSpans(_ spans: [TextSpan]) -> [TextSpan] {
    var kept = spans.filter { $0.range.length > 0 }
    kept = kept.enumerated().sorted { ($0.element.range.location, $0.offset) < ($1.element.range.location, $1.offset) }.map(\.element)
    var out: [TextSpan] = []
    for span in kept {
        guard var last = out.last, span.range.location < last.range.end else {
            out.append(span)
            continue
        }
        let end = max(span.range.end, last.range.end)
        if span.priority < last.priority {
            last.kind = span.kind
            last.priority = span.priority
        }
        last.range = NSRange(location: last.range.location, length: end - last.range.location)
        out[out.count - 1] = last
    }
    return out
}

// MARK: - Rules (rules.json, bip39.txt)

final class SensitiveRules: @unchecked Sendable {
    static let shared = SensitiveRules()

    private var single: [String: NSRegularExpression] = [:]
    private var arrays: [String: [NSRegularExpression]] = [:]
    private(set) var lists: [String: [String]] = [:]
    private(set) var ibanLengths: [String: Int] = [:]
    private(set) var dniLetters: [Character] = []
    private(set) var bip39: Set<String> = []
    private(set) var bip39List: [String] = []
    private(set) var phrasePrefix = ""
    private(set) var phraseSuffix = ""

    private init() {
        guard let url = Bundle.module.url(forResource: "rules", withExtension: "json", subdirectory: "SensitiveData"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        for entry in root["regexes"] as? [[String: Any]] ?? [] {
            guard let name = entry["name"] as? String else { continue }
            var options: NSRegularExpression.Options = []
            if (entry["options"] as? [String] ?? []).contains("caseInsensitive") { options.insert(.caseInsensitive) }
            if let pattern = entry["regex"] as? String, let re = try? NSRegularExpression(pattern: pattern, options: options) {
                single[name] = re
            } else if let patterns = entry["regexes"] as? [String] {
                arrays[name] = patterns.compactMap { try? NSRegularExpression(pattern: $0, options: options) }
            }
        }
        if let composed = root["composed"] as? [String: Any], let phrase = composed["phraseRegexTemplate"] as? [String: Any] {
            phrasePrefix = phrase["prefix"] as? String ?? ""
            phraseSuffix = phrase["suffix"] as? String ?? ""
        }
        for (name, value) in root["lists"] as? [String: Any] ?? [:] {
            guard let dict = value as? [String: Any] else { continue }
            if let items = dict["items"] as? [String] { lists[name] = items }
            if name == "ibanLengths", let items = dict["items"] as? [String: Int] { ibanLengths = items }
            if name == "dniLetters", let letters = dict["value"] as? String { dniLetters = Array(letters) }
        }
        if let url = Bundle.module.url(forResource: "bip39", withExtension: "txt", subdirectory: "SensitiveData"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            bip39List = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            bip39 = Set(bip39List)
        }
    }

    subscript(_ name: String) -> NSRegularExpression {
        if let re = single[name] { return re }
        // A missing rule must not match anything.
        return try! NSRegularExpression(pattern: "(?!)")
    }

    func array(_ name: String) -> [NSRegularExpression] { arrays[name] ?? [] }
    func set(_ name: String) -> Set<String> { Set(lists[name] ?? []) }
}

// MARK: - Regex helpers

private extension NSRegularExpression {
    func all(_ ns: NSString, options: NSRegularExpression.MatchingOptions = []) -> [NSTextCheckingResult] {
        matches(in: ns as String, options: options, range: NSRange(location: 0, length: ns.length))
    }

    func first(_ s: String, options: NSRegularExpression.MatchingOptions = []) -> NSTextCheckingResult? {
        firstMatch(in: s, options: options, range: NSRange(location: 0, length: (s as NSString).length))
    }

    func test(_ s: String) -> Bool { first(s) != nil }

    /// `firstMatch(options: .anchored)` whose length is the whole string.
    func whole(_ s: String) -> Bool {
        let length = (s as NSString).length
        guard let m = firstMatch(in: s, options: .anchored, range: NSRange(location: 0, length: length)) else { return false }
        return m.range.length == length
    }
}

private extension NSString {
    func text(_ range: NSRange) -> String {
        guard range.location != NSNotFound, range.end <= length else { return "" }
        return substring(with: range)
    }
}

private extension NSTextCheckingResult {
    func has(_ group: Int) -> Bool { range(at: group).location != NSNotFound }
}

private let whitespaceSet = CharacterSet.whitespaces

// MARK: - GateLine

/// `GateLine.init`: the text, its NSString, the ASCII digit count, the space count and the set
/// of UTF-16 units.
struct GateLine {
    let text: String
    let ns: NSString
    let digits: Int
    let spaces: Int
    let units: Set<UInt16>

    init(_ text: String) {
        self.text = text
        ns = text as NSString
        var digits = 0
        var spaces = 0
        var units = Set<UInt16>()
        for u in text.utf16 {
            if u >= 0x30, u <= 0x39 { digits += 1 } else if u == 0x20 { spaces += 1 }
            units.insert(u)
        }
        self.digits = digits
        self.spaces = spaces
        self.units = units
    }

    var length: Int { ns.length }

    /// `GateLine.contains(anyOf:)`.
    func contains(anyOf chars: String) -> Bool { chars.utf16.contains { units.contains($0) } }
}

// MARK: - Classifier

enum Classifier {
    static var R: SensitiveRules { .shared }

    // MARK: Entry

    /// `findSensitiveSpans(in:)`.
    static func findSensitiveSpans(in text: String) -> [TextSpan] {
        let line = GateLine(text)
        guard line.length >= 3 else { return [] }
        var spans = findSecretSpans(in: line)
        var pii: [TextSpan] = []
        findPII(in: line, into: &pii)
        spans += pii
        let folded = foldDigitLookalikes(text)
        if folded != text {
            var foldedPII: [TextSpan] = []
            findPII(in: GateLine(folded), into: &foldedPII)
            spans += foldedPII
        }
        return mergeSpans(spans)
    }

    /// The PII half of `findSensitiveSpans(in:)`, run on the text and on its folded form.
    static func findPII(in line: GateLine, into spans: inout [TextSpan]) {
        let d = line.digits
        if d > 1 || line.text.range(of: "bic|swift", options: [.caseInsensitive, .regularExpression]) != nil {
            findLabelledIdentifiers(in: line, into: &spans)
        }
        if line.contains(anyOf: "@©[(") { findEmails(in: line, into: &spans) }
        if d >= 8 {
            findPhones(in: line, into: &spans)
            if d >= 12 {
                findCards(in: line, into: &spans)
                findBankAccounts(in: line, into: &spans)
            } else if d >= 10 {
                findBankAccounts(in: line, into: &spans)
            }
            findNationalIdentifiers(in: line, into: &spans)
        } else if d > 1 || line.contains(anyOf: "<") {
            findNationalIdentifiers(in: line, into: &spans)
        }
        if d >= 1 {
            findAddresses(in: line, into: &spans)
            if d >= 4, line.contains(anyOf: ".:") { findNetworkIdentifiers(in: line, into: &spans) }
        }
    }

    /// `foldDigitLookalikes(_:)`: I, l, | → 1 and O, o → 0 where the UTF-16 unit before or
    /// after (in the unfolded text) is an ASCII digit.
    static func foldDigitLookalikes(_ text: String) -> String {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return text }
        var out = units
        func isDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }
        for i in units.indices {
            let replacement: UInt16
            switch units[i] {
            case 0x49, 0x6C, 0x7C: replacement = 0x31
            case 0x4F, 0x6F: replacement = 0x30
            default: continue
            }
            if (i > 0 && isDigit(units[i - 1])) || (i + 1 < units.count && isDigit(units[i + 1])) {
                out[i] = replacement
            }
        }
        return String(utf16CodeUnits: out, count: out.count)
    }

    // MARK: Secrets

    /// `findSecretSpans(in:)`.
    static func findSecretSpans(in line: GateLine) -> [TextSpan] {
        var spans: [TextSpan] = []
        findKnownPrefixes(in: line, into: &spans)
        if line.contains(anyOf: ":") { findCredentialURLs(in: line, into: &spans) }
        if line.contains(anyOf: "=") { findSecretQueryParameters(in: line, into: &spans) }
        if mayNameACredential(line) { findCredentialAssignments(in: line, into: &spans) }
        if line.length > 15 { findRandomStrings(in: line, into: &spans) }
        if line.digits > 0, line.contains(anyOf: "-") {
            for m in R["uuidRegex"].all(line.ns) { spans.append(TextSpan(kind: "secret", priority: 1, range: m.range)) }
        }
        findCodes(in: line, into: &spans)
        if line.spaces > 4, let range = findSeedPhrase(in: line, minWords: 10) {
            spans.append(TextSpan(kind: "secret", priority: 1, range: range))
        }
        if line.digits > 0, line.contains(anyOf: "!#$%&*?~@^") { findPasswordShapedTokens(in: line, into: &spans) }
        return spans
    }

    /// `findKnownPrefixes(in:into:)`: vendor key prefixes, then webhook URLs.
    static func findKnownPrefixes(in line: GateLine, into spans: inout [TextSpan]) {
        for m in R["knownPrefixRegex"].all(line.ns) {
            let s = line.ns.text(m.range)
            if R["placeholderInsideRegex"].test(s) { continue }
            let prefixLength = R["knownPrefixAtStartRegex"].first(s)?.range.length ?? 0
            var body = (s as NSString).substring(from: prefixLength).replacingOccurrences(of: " ", with: "")
            let isCut = body.hasSuffix("…")
            if isCut { body.removeLast() }
            guard body.count >= 4 else { continue }
            guard body.contains(where: { $0.isNumber || $0.isUppercase }) else { continue }
            guard body.count >= 10 || isCut else { continue }
            let wordSegments = body.split(whereSeparator: { "_-./".contains($0) })
                .filter { $0.count >= 3 && $0.allSatisfy(\.isLowercase) }
            guard wordSegments.count < 2 else { continue }
            if s.hasPrefix("ey"), line.ns.substring(to: m.range.location).hasSuffix("base64,") { continue }
            spans.append(TextSpan(kind: "apiKey", priority: 0, range: m.range))
        }
        for m in R["webhookURLRegex"].all(line.ns) where !R["placeholderInsideRegex"].test(line.ns.text(m.range)) {
            spans.append(TextSpan(kind: "apiKey", priority: 0, range: m.range))
        }
    }

    /// `findCredentialURLs(in:into:)`.
    static func findCredentialURLs(in line: GateLine, into spans: inout [TextSpan]) {
        for m in R["credentialURLRegex"].all(line.ns) where !R["angleNameRegex"].test(line.ns.text(m.range)) {
            spans.append(TextSpan(kind: "secret", priority: 0, range: m.range))
        }
        for m in R["pgpassRegex"].all(line.ns) where m.has(1) {
            spans.append(TextSpan(kind: "secret", priority: 0, range: m.range(at: 1)))
        }
    }

    /// `findSecretQueryParameters(in:into:)`.
    static func findSecretQueryParameters(in line: GateLine, into spans: inout [TextSpan]) {
        for m in R["secretParameterRegex"].all(line.ns) where m.has(1) {
            let value = line.ns.text(m.range(at: 1))
            if R["placeholderValueRegex"].whole(value) { continue }
            if R["tokenishRegex"].test(value) {
                spans.append(TextSpan(kind: "secret", priority: 1, range: m.range(at: 1)))
            }
        }
    }

    /// `mayNameACredential(_:)`.
    static func mayNameACredential(_ line: GateLine) -> Bool {
        if line.contains(anyOf: "-$") { return true }
        let lower = line.text.lowercased()
        let nouns = ["pass", "pwd", "pw", "secret", "token", "key", "auth", "credential", "salt", "dsn", "sid",
                     "signature", "mnemonic", "cookie", "sess", "otp", "bearer", "basic", "connectionstring"]
        return nouns.contains { lower.contains($0) }
    }

    /// `findCredentialAssignments(in:into:)`.
    static func findCredentialAssignments(in line: GateLine, into spans: inout [TextSpan]) {
        let ns = line.ns
        let bareNouns = R.set("bareNouns")
        let wordValuedNouns = R.set("wordValuedNouns")
        let passwordNouns = R.set("passwordNouns")
        var position = 0
        while position < ns.length {
            guard let m = R["credentialAssignmentRegex"].firstMatch(in: line.text, options: [], range: NSRange(location: position, length: ns.length - position)) else { break }
            let nounRange = m.range(at: 1)
            let noun = ns.text(nounRange)
            let before = ns.substring(to: nounRange.location)
            position = nounRange.location + 1
            // A noun inside a lowercase word ("monkey").
            if let last = before.last, last.isLowercase, let first = noun.first, first.isLowercase { continue }
            // Inside an unclosed `${…`.
            if let open = before.range(of: "${", options: .backwards), !before[open.lowerBound...].contains("}") { continue }
            let lowerNoun = noun.lowercased()
            if bareNouns.contains(lowerNoun), noun == lowerNoun {
                if !R["letterJustBeforeRegex"].test(before), !R["qualifierBeforeNounRegex"].test(before) { continue }
            }
            let separator = ns.text(m.range(at: 2))
            let raw = ns.text(m.range(at: 3))
            guard let value = credentialValue(raw, separator: separator) else { continue }
            let trimmedSeparator = separator.trimmingCharacters(in: whitespaceSet)
            if trimmedSeparator == ":", R["lowercaseWordRegex"].test(value) { continue }
            if wordValuedNouns.contains(lowerNoun), !R["digitOrColonRegex"].test(value), pronounceableLetterRatio(value) >= 0.8 { continue }
            if trimmedSeparator == ":" {
                let words = value.split(whereSeparator: \.isWhitespace)
                if words.count >= 4, !passwordNouns.contains(lowerNoun) {
                    let tokens = words.filter { isTokenShaped(String($0)) }
                    if tokens.count * 2 < words.count { continue }
                }
            }
            let needle = value.trimmingCharacters(in: whitespaceSet)
            let from = m.range(at: 3).location
            let found = ns.range(of: needle, options: [], range: NSRange(location: from, length: ns.length - from))
            guard found.location != NSNotFound else { continue }
            spans.append(TextSpan(kind: "secret", priority: 1, range: found))
        }
        for m in R["xmlCredentialRegex"].all(ns) where m.has(1) {
            spans.append(TextSpan(kind: "secret", priority: 1, range: m.range(at: 1)))
        }
        for re in R.array("credentialFlagRegexes") {
            for m in re.all(ns) {
                let range = re.numberOfCaptureGroups >= 1 ? m.range(at: 1) : m.range
                guard range.location != NSNotFound else { continue }
                spans.append(TextSpan(kind: "secret", priority: 1, range: range))
            }
        }
    }

    /// `credentialValue(_:separator:)`: the value of `noun<separator>raw`, or nil when it is
    /// empty, a placeholder or code.
    static func credentialValue(_ raw: String, separator: String) -> String? {
        let value = raw.trimmingCharacters(in: whitespaceSet)
        guard !value.isEmpty else { return nil }
        let quotes: Set<Character> = ["\"", "'", "`"]
        let sep = separator.trimmingCharacters(in: whitespaceSet)
        if sep.isEmpty || sep == "is" {
            // `key value` / `key is value`: one token-shaped word.
            let first = value.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            let token = first.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,;"))
            let minLength = separator.count == 1 ? 16 : 6
            guard isTokenShaped(token), let head = token.first, !"/~".contains(head),
                  token.count >= minLength, !isCodeReference(token),
                  !R["placeholderInsideRegex"].test(token)
            else { return nil }
            return token
        }
        var v = value
        if sep == "=", let head = v.first, !quotes.contains(head) {
            v = v.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? v
        }
        guard let head = v.first else { return nil }
        let quoted = quotes.contains(head)
        if quoted {
            let rest = v.dropFirst()
            let close = rest.firstIndex(of: head) ?? rest.endIndex
            v = String(rest[..<close])
        } else {
            if let end = R["unquotedValueEndRegex"].first(v) { v = (v as NSString).substring(to: end.range.location) }
            v = trimmingTrailing(v, ",;\\")
        }
        var t = v.trimmingCharacters(in: whitespaceSet)
        t = trimmingTrailing(t, "\",")
        t = trimmingTrailing(t, " };,")
        guard t.count > 2 else { return nil }
        if R["placeholderValueRegex"].whole(t) { return nil }
        if R["placeholderInsideRegex"].test(t) { return nil }
        if quoted { return t }
        if isCodeReference(t) { return nil }
        if let tail = R["unquotedValueTailRegex"].first(t) { t = (t as NSString).substring(to: tail.range.location) }
        t = trimmingTrailing(t.trimmingCharacters(in: whitespaceSet), " };,")
        guard t.count > 2, !R["placeholderValueRegex"].whole(t), !isCodeReference(t) else { return nil }
        return t
    }

    /// `trimmingTrailing(_:_:)`: drops trailing characters found in the set.
    static func trimmingTrailing(_ s: String, _ chars: String) -> String {
        var s = s
        while let last = s.last, chars.contains(last) { s.removeLast() }
        return s
    }

    /// `isCodeReference(_:)`.
    static func isCodeReference(_ s: String) -> Bool {
        if R["codeReferenceRegex"].test(s) { return true }
        if R["memberPathRegex"].test(s), !s.contains(where: \.isNumber) { return true }
        guard R["camelIdentifierRegex"].test(s) else { return false }
        return pronounceableLetterRatio(s) >= 0.8
    }

    /// `isTokenShaped(_:)`.
    static func isTokenShaped(_ s: String) -> Bool {
        guard s.count >= 6 else { return false }
        if s.contains(where: \.isNumber), s.contains(where: \.isLetter) { return true }
        return R["mixedCaseRegex"].test(s)
    }

    /// `isOneRepeatedCharacter(_:)`: at most one distinct letter or digit.
    static func isOneRepeatedCharacter(_ s: String) -> Bool {
        Set(s.filter { $0.isLetter || $0.isNumber }).count < 2
    }

    /// `pronounceableLetterRatio(_:)`: letters in runs (split at an uppercase letter and at
    /// non-letters) that have 2+ letters and a vowel, over all letters.
    static func pronounceableLetterRatio(_ s: String) -> Double {
        var run: [Character] = []
        var pronounceable = 0
        var letters = 0
        func flush() {
            if run.count > 1, run.contains(where: { "aeiouyAEIOUY".contains($0) }) { pronounceable += run.count }
            run.removeAll(keepingCapacity: true)
        }
        for c in s {
            if c.isLetter { letters += 1 }
            if c.isUppercase {
                flush()
                run.append(c)
            } else if c.isLowercase {
                run.append(c)
            } else {
                flush()
            }
        }
        flush()
        return Double(pronounceable) / Double(max(letters, 1))
    }

    /// `letterDigitSwitchCount(_:)`.
    static func letterDigitSwitchCount(_ s: String) -> Int {
        var count = 0
        var previous: Character?
        for c in s {
            if let p = previous, (p.isLetter && c.isNumber) || (p.isNumber && c.isLetter) { count += 1 }
            previous = c
        }
        return count
    }

    /// `digitRunCount(_:)`.
    static func digitRunCount(_ s: String) -> Int {
        var runs = 0
        var inRun = false
        for c in s {
            if c.isNumber {
                if !inRun { runs += 1 }
                inRun = true
            } else {
                inRun = false
            }
        }
        return runs
    }

    /// `classSwitchRatio(_:)`: among neighbouring letters/digits, the share whose class (digit,
    /// uppercase, other letter) changes.
    static func classSwitchRatio(_ s: String) -> Double {
        func cls(_ c: Character) -> Int { c.isNumber ? 0 : (c.isUppercase ? 1 : 2) }
        var pairs = 0
        var switches = 0
        var previous: Character?
        for c in s {
            guard c.isLetter || c.isNumber else {
                previous = nil
                continue
            }
            if let p = previous {
                pairs += 1
                if cls(p) != cls(c) { switches += 1 }
            }
            previous = c
        }
        return pairs == 0 ? 0 : Double(switches) / Double(pairs)
    }

    /// `findRandomStrings(in:into:)`.
    static func findRandomStrings(in line: GateLine, into spans: inout [TextSpan]) {
        let urls = R["urlRegex"].all(line.ns).map(\.range)
        for m in R["randomCandidateRegex"].all(line.ns) {
            let s = line.ns.text(m.range)
            if R["hashTokenRegex"].test(s) { continue }
            if R["hashContextBeforeRegex"].test(line.ns.substring(to: m.range.location)) { continue }
            if urls.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) { continue }
            let core = s.trimmingCharacters(in: CharacterSet(charactersIn: ".-_/"))
            if R["hexRegex"].test(core), R["hashWordRegex"].test(line.text) { continue }
            if looksRandom(s) { spans.append(TextSpan(kind: "secret", priority: 1, range: m.range)) }
        }
    }

    /// `looksRandom(_:)`.
    static func looksRandom(_ candidate: String) -> Bool {
        var s = candidate
        while s.hasSuffix("=") { s.removeLast() }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ".-_/"))
        if s.hasPrefix("0x") { s.removeFirst(2) }
        guard s.count >= 16, Set(s).count >= 10, !s.contains(".."), !s.contains("//") else { return false }
        let scalars = Array(s.unicodeScalars)
        let ascending = zip(scalars, scalars.dropFirst()).filter { $1.value == $0.value &+ 1 }.count
        guard ascending * 2 < scalars.count else { return false }
        let separated = R["segmentSeparatorRegex"].stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "\u{0}")
        let segments = separated.split(separator: "\u{0}").map(String.init)
        let total = segments.reduce(0) { $0 + $1.count }
        guard total >= 14 else { return false }
        let randomLength = segments.filter(isRandomSegment).reduce(0) { $0 + $1.count }
        let hasDigit = s.contains(where: \.isNumber)
        var hasWord = false
        for segment in segments {
            if R["plainWordSegmentRegex"].test(segment)
                || (R["upperWordRegex"].test(segment) && segment.contains(where: { "AEIOUY".contains($0) }))
                || (segment.count >= 6 && pronounceableLetterRatio(segment) >= 0.8) {
                hasWord = true
                break
            }
        }
        // Without digits only long runs count; a run with a word in it needs digits.
        if hasWord {
            guard hasDigit else { return false }
        } else if !hasDigit, s.count <= 23 {
            return false
        }
        if s.filter(\.isLetter).count * 4 < total { return false }
        if total <= randomLength * 2 { return true }
        if hasWord { return false }
        return isRandomSegment(segments.joined())
    }

    /// `isRandomSegment(_:)`.
    static func isRandomSegment(_ s: String) -> Bool {
        guard s.count >= 10 else { return false }
        if R["hexRegex"].test(s) {
            return s.count >= 24 && s.contains(where: \.isNumber) && s.contains(where: \.isLetter)
        }
        let switches = letterDigitSwitchCount(s)
        if R["upperDigitRegex"].test(s) {
            if switches > 2 {
                let letters = s.filter(\.isLetter).count
                if letters > 2 { return s.count <= letters * 4 }
            }
            return s.count > 23 && s.contains(where: \.isNumber) && s.contains(where: \.isLetter)
        }
        if !R["lowerDigitRegex"].test(s) {
            let ratio = pronounceableLetterRatio(s)
            if s.count >= 12, ratio < 0.65 { return true }
            if ratio < 0.8 { return switches > 2 }
        }
        guard s.count >= 16, switches >= 4 else { return false }
        return digitRunCount(s) > 2
    }

    /// `findCodes(in:into:)`: one-time and recovery codes.
    static func findCodes(in line: GateLine, into spans: inout [TextSpan]) {
        guard line.digits > 1 || line.spaces > 4 else { return }
        let groups = [0, 1, 1, 0, 0]
        for (re, group) in zip(R.array("codeRegexes"), groups) {
            for m in re.all(line.ns) {
                let range = group < 1 ? m.range : m.range(at: group)
                guard range.location != NSNotFound else { continue }
                if !isOneRepeatedCharacter(line.ns.text(range)) {
                    spans.append(TextSpan(kind: "secret", priority: 1, range: range))
                }
            }
        }
    }

    /// `findSeedPhrase(in:minWords:)`: 10 words in a line, 5 under a seed label.
    static func findSeedPhrase(in line: GateLine, minWords: Int) -> NSRange? {
        let ns = line.ns
        let words = R.bip39
        let numbered = R["numberedWordRegex"].all(ns)
        if numbered.count > 2 {
            let hits = numbered.filter { words.contains(ns.text($0.range(at: 1))) }
            if hits.count > 2, let first = numbered.first?.range(at: 1), let last = numbered.last?.range(at: 1) {
                return NSRange(location: first.location, length: last.end - first.location)
            }
        }
        let tokens = R["wordRegex"].all(ns).map(\.range)
        var best: [NSRange] = []
        var current: [NSRange] = []
        func close() {
            if current.count > best.count { best = current }
            current = []
        }
        for token in tokens {
            if let last = current.last {
                let end = last.end
                if !(end + 1 == token.location && ns.text(NSRange(location: end, length: 1)) == " ") { close() }
            }
            let word = ns.text(token)
            if word == word.lowercased(), words.contains(word) {
                current.append(token)
            } else {
                close()
            }
        }
        close()
        // A last word cut by the line end that starts a BIP-39 word.
        if let lastToken = tokens.last, let bestLast = best.last, bestLast != lastToken, tokens.count > 1,
           tokens[tokens.count - 2] == bestLast,
           lastToken.end == (line.text.trimmingCharacters(in: whitespaceSet) as NSString).length {
            let partial = ns.text(lastToken).lowercased()
            if partial.count > 1, R.bip39List.contains(where: { $0.hasPrefix(partial) }) { best.append(lastToken) }
        }
        guard best.count >= minWords, let first = best.first, let last = best.last else { return nil }
        return NSRange(location: first.location, length: last.end - first.location)
    }

    /// `findPasswordShapedTokens(in:into:)`.
    static func findPasswordShapedTokens(in line: GateLine, into spans: inout [TextSpan]) {
        for m in R["passwordShapedRegex"].all(line.ns) {
            let token = line.ns.text(m.range)
            if token.contains(".") || token.contains("_") { continue }
            if token.hasPrefix("$") || token.hasPrefix("#") || token.hasPrefix("@") { continue }
            if token.filter(\.isLetter).count * 2 < token.count { continue }
            let alone = line.text.trimmingCharacters(in: whitespaceSet) == token
            if alone || R["passwordContextBeforeRegex"].test(line.ns.substring(to: m.range.location)) {
                spans.append(TextSpan(kind: "secret", priority: 1, range: m.range))
            }
        }
    }

    // MARK: PII

    /// `digitsOf(_:)`.
    static func digitsOf(_ s: String) -> [Int] { s.compactMap(\.wholeNumberValue) }

    /// `findLabelledIdentifiers(in:into:)`.
    static func findLabelledIdentifiers(in line: GateLine, into spans: inout [TextSpan]) {
        let ns = line.ns
        let shortLabels = R.set("shortNumberLabels")
        let longLabels = R.set("longNumberLabels")
        for m in R["labelledValueRegex"].all(ns) where m.has(1) && m.has(2) {
            let label = ns.text(m.range(at: 1)).lowercased()
            let valueRange = m.range(at: 2)
            let value = ns.text(valueRange)
            let firstWord = label.split(separator: " ").first.map(String.init) ?? ""
            let minDigits = shortLabels.contains(firstWord) ? 2 : (longLabels.contains(label) ? 7 : 4)
            let percentAfter = valueRange.end < ns.length && ns.text(NSRange(location: valueRange.end, length: 1)) == "%"
            if digitsOf(value).count >= minDigits, !isOneRepeatedCharacter(value), !percentAfter {
                spans.append(TextSpan(kind: "identifier", priority: 1, range: valueRange))
            }
        }
        for name in ["dateOfBirthRegex", "cardExpiryRegex", "cardSecurityCodeRegex", "bicLabelledRegex"] {
            for m in R[name].all(ns) where m.has(1) {
                spans.append(TextSpan(kind: "identifier", priority: 1, range: m.range(at: 1)))
            }
        }
    }

    /// `findEmails(in:into:)`.
    static func findEmails(in line: GateLine, into spans: inout [TextSpan]) {
        let ns = line.ns
        let fileExtensions = R.set("fileExtensions")
        for m in R["emailRegex"].all(ns) where m.has(3) {
            let tld = ns.text(m.range(at: 3))
            if fileExtensions.contains(tld.lowercased()) { continue }
            guard tld == tld.lowercased() || tld == tld.uppercased() else { continue }
            // A short ASCII address (`ab@cd.io`) is too likely a misread.
            if m.range(at: 1).length + m.range(at: 2).length < 5, ns.text(m.range).allSatisfy(\.isASCII) { continue }
            spans.append(TextSpan(kind: "email", priority: 2, range: m.range))
        }
        for name in ["cutEmailRegex", "obfuscatedEmailRegex"] {
            for m in R[name].all(ns) { spans.append(TextSpan(kind: "email", priority: 2, range: m.range)) }
        }
    }

    /// `isBinaryOrRun(_:)`: only 0/1 digits, or digits that count up by one.
    static func isBinaryOrRun(_ s: String) -> Bool {
        let d = digitsOf(s)
        if d.allSatisfy({ $0 <= 1 }) { return true }
        return zip(d, d.dropFirst()).allSatisfy { $1 == $0 + 1 }
    }

    /// `findPhones(in:into:)`.
    static func findPhones(in line: GateLine, into spans: inout [TextSpan]) {
        let ns = line.ns
        for m in R["internationalPhoneRegex"].all(ns) where digitsOf(ns.text(m.range)).count >= 8 {
            spans.append(TextSpan(kind: "phone", priority: 3, range: m.range))
        }
        for re in R.array("nationalPhoneRegexes") {
            for m in re.all(ns) {
                let s = ns.text(m.range)
                let count = digitsOf(s).count
                guard count > 8, count < 13 else { continue }
                let groups = s.split(whereSeparator: { !$0.isNumber })
                if groups.count >= 2, Set(groups).count == 1 { continue }
                if isOneRepeatedCharacter(s) || R["dateInNumberRegex"].test(s) || isBinaryOrRun(s) { continue }
                spans.append(TextSpan(kind: "phone", priority: 3, range: m.range))
            }
        }
    }

    /// `isLuhnValid(_:)`.
    static func isLuhnValid(_ digits: [Int]) -> Bool {
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            var v = d
            if i % 2 == 1 {
                v *= 2
                if v > 9 { v -= 9 }
            }
            sum += v
        }
        return sum % 10 == 0
    }

    /// `findCards(in:into:)`.
    static func findCards(in line: GateLine, into spans: inout [TextSpan]) {
        let ns = line.ns
        for m in R["cardRunRegex"].all(ns) {
            let s = ns.text(m.range)
            let digits = digitsOf(s)
            guard (13...19).contains(digits.count), let lead = digits.first, (2...6).contains(lead) else { continue }
            if isOneRepeatedCharacter(s) { continue }
            let groups = s.replacingOccurrences(of: "…", with: "").split(whereSeparator: { $0 == " " || $0 == "-" })
            let luhn = isLuhnValid(digits)
            if groups.count >= 2, Set(groups).count == 1, !luhn { continue }
            if R["imeiBeforeRegex"].test(ns.substring(to: m.range.location)) { continue }
            if groups.count == 1, m.range.location > 0, "/#-".contains(ns.text(NSRange(location: m.range.location - 1, length: 1))) { continue }
            if !luhn {
                // A non-Luhn number still counts when printed as 4-4-4….
                guard groups.count >= 3, groups.prefix(3).allSatisfy({ $0.count == 4 }) else { continue }
            }
            spans.append(TextSpan(kind: "card", priority: 1, range: m.range))
        }
        for m in R["cutCardRegex"].all(ns) { spans.append(TextSpan(kind: "card", priority: 1, range: m.range)) }
    }

    /// `isIBANChecksumValid(_:)`: the first 4 characters moved to the end, letters as 10…35,
    /// running mod 97 == 1.
    static func isIBANChecksumValid(_ iban: String) -> Bool {
        let chars = Array(iban.uppercased())
        guard chars.count >= 5 else { return false }
        var remainder = 0
        for c in chars[4...] + chars[..<4] {
            if let d = c.wholeNumberValue, c.isASCII {
                remainder = (remainder * 10 + d) % 97
            } else if c.isASCII, c.isLetter, let v = c.asciiValue {
                remainder = (remainder * 100 + Int(v) - 55) % 97
            } else {
                return false
            }
        }
        return remainder == 1
    }

    /// `findBankAccounts(in:into:)`: IBANs (length per country, mod 97) and Polish NRB accounts.
    static func findBankAccounts(in line: GateLine, into spans: inout [TextSpan]) {
        let ns = line.ns
        matches: for m in R["ibanRegex"].all(ns) where m.has(1) {
            guard let expected = R.ibanLengths[ns.text(m.range(at: 1)).uppercased()] else { continue }
            let isCut = m.has(4)
            let full = ns.text(m.range)
            let letters = full.filter(\.isLetter)
            guard letters == letters.uppercased() || letters == letters.lowercased() else { continue }
            let groups = full.replacingOccurrences(of: "…", with: "").split(separator: " ")
            // A following word (a group without digits longer than 4, or with lowercase) is not
            // part of an IBAN.
            for group in groups.dropFirst() where !group.contains(where: \.isNumber) {
                if group.count > 4 || group.contains(where: { !$0.isUppercase }) { continue matches }
            }
            let compact = String(full.filter { !$0.isWhitespace && $0 != "…" }).uppercased()
            if compact.count >= expected, isIBANChecksumValid(String(compact.prefix(expected))) {
                // Cover up to the expected-th non-space UTF-16 unit.
                var seen = 0
                var end = m.range.location
                for (i, u) in full.utf16.enumerated() {
                    if u != 0x20 { seen += 1 }
                    if seen == expected {
                        end = m.range.location + i + 1
                        break
                    }
                }
                spans.append(TextSpan(kind: "iban", priority: 1, range: NSRange(location: m.range.location, length: end - m.range.location)))
            } else if compact.count == expected || (isCut && compact.count >= 12) {
                // The right length without a valid checksum (a misread digit), or cut by an ellipsis.
                spans.append(TextSpan(kind: "iban", priority: 1, range: m.range))
            }
        }
        for m in R["polishAccountRegex"].all(ns) {
            let digits = digitsOf(ns.text(m.range)).map(String.init).joined()
            if isIBANChecksumValid("PL" + digits) { spans.append(TextSpan(kind: "iban", priority: 1, range: m.range)) }
        }
    }

    /// `isCPFValid(_:)`: 11 digits, not all equal, both mod-11 check digits.
    static func isCPFValid(_ d: [Int]) -> Bool {
        guard d.count == 11, Set(d).count > 1 else { return false }
        func check(_ n: Int) -> Int {
            var sum = 0
            for i in 0..<n { sum += d[i] * (n + 1 - i) }
            let r = sum * 10 % 11
            return r == 10 ? 0 : r
        }
        return check(9) == d[9] && check(10) == d[10]
    }

    /// `findNationalIdentifiers(in:into:)`.
    static func findNationalIdentifiers(in line: GateLine, into spans: inout [TextSpan]) {
        let ns = line.ns
        for m in R["vatRegex"].all(ns) { spans.append(TextSpan(kind: "identifier", priority: 1, range: m.range)) }
        for m in R["ssnRegex"].all(ns) {
            let area = ns.text(m.range(at: 1)), group = ns.text(m.range(at: 2)), serial = ns.text(m.range(at: 3))
            if area == "000" || area == "666" || area.hasPrefix("9") || group == "00" || serial == "0000" { continue }
            spans.append(TextSpan(kind: "ssn", priority: 1, range: m.range))
        }
        for re in R.array("shapedIdentifierRegexes") {
            for m in re.all(ns) { spans.append(TextSpan(kind: "identifier", priority: 1, range: m.range)) }
        }
        for m in R["cpfRegex"].all(ns) where isCPFValid(digitsOf(ns.text(m.range))) {
            spans.append(TextSpan(kind: "identifier", priority: 1, range: m.range))
        }
        let letters = R.dniLetters
        for m in R["dniRegex"].all(ns) where !letters.isEmpty {
            let prefix = m.has(1) ? (["X": "0", "Y": "1", "Z": "2"][ns.text(m.range(at: 1))] ?? "") : ""
            guard let n = Int(prefix + ns.text(m.range(at: 2))) else { continue }
            if String(letters[n % 23]) == ns.text(m.range(at: 3)) {
                spans.append(TextSpan(kind: "identifier", priority: 1, range: m.range))
            }
        }
        for m in R["frenchSocialSecurityRegex"].all(ns) {
            let s = ns.text(m.range).replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "2A", with: "19").replacingOccurrences(of: "2B", with: "18")
            guard s.count == 15, let n = Int(s.prefix(13)), let key = Int(s.suffix(2)) else { continue }
            if 97 - n % 97 == key { spans.append(TextSpan(kind: "identifier", priority: 1, range: m.range)) }
        }
        let trimmed = line.text.trimmingCharacters(in: whitespaceSet)
        if trimmed.contains("<<"), R["machineReadableZoneRegex"].test(trimmed) {
            spans.append(TextSpan(kind: "identifier", priority: 1, range: NSRange(location: 0, length: ns.length)))
        }
        let placeholderChars: Set<Character> = ["X", "*", "•"]
        for m in R["licenceKeyRegex"].all(ns) {
            let s = ns.text(m.range)
            let isPlaceholder = s.split(separator: "-").contains { group in
                let chars = Set(group.trimmingCharacters(in: whitespaceSet))
                return !chars.isEmpty && chars.isSubset(of: placeholderChars)
            }
            if s.filter(\.isNumber).count >= 2, s.filter(\.isLetter).count >= 2, !isOneRepeatedCharacter(s), !isPlaceholder {
                spans.append(TextSpan(kind: "secret", priority: 1, range: m.range))
            }
        }
    }

    /// `findAddresses(in:into:)`.
    static func findAddresses(in line: GateLine, into spans: inout [TextSpan]) {
        let ns = line.ns
        for re in R.array("streetRegexes") {
            for m in re.all(ns) {
                var start = m.range.location
                var end = m.range.end
                // Comma segments that continue the address.
                while end < ns.length,
                      let seg = R["addressSegmentRegex"].firstMatch(in: line.text, options: .anchored, range: NSRange(location: end, length: ns.length - end)),
                      seg.has(1), seg.range(at: 1).length > 0 {
                    end = seg.range(at: 1).end
                }
                // A flat/unit segment before it.
                let before = ns.substring(to: start)
                if before.hasSuffix(", ") {
                    let head = String(before.dropLast(2))
                    if let unit = R["unitSegmentRegex"].first(head) { start = unit.range.location }
                }
                spans.append(TextSpan(kind: "address", priority: 2, range: NSRange(location: start, length: end - start)))
            }
        }
        for re in R.array("addressLineRegexes") {
            for m in re.all(ns) { spans.append(TextSpan(kind: "address", priority: 2, range: m.range)) }
        }
    }

    /// `findNetworkIdentifiers(in:into:)`.
    static func findNetworkIdentifiers(in line: GateLine, into spans: inout [TextSpan]) {
        let ns = line.ns
        for m in R["ipv4Regex"].all(ns) {
            let octets = (1...4).compactMap { Int(ns.text(m.range(at: $0))) }
            guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { continue }
            let a = octets[0], b = octets[1]
            if [0, 10, 127].contains(a) || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) { continue }
            if R["ipContextBeforeRegex"].test(ns.substring(to: m.range.location)) {
                spans.append(TextSpan(kind: "identifier", priority: 2, range: m.range))
            }
        }
        for m in R["userAtHostIPRegex"].all(ns) { spans.append(TextSpan(kind: "identifier", priority: 2, range: m.range)) }
        for m in R["ipv6Regex"].all(ns) {
            let s = ns.text(m.range)
            let groups = s.split(separator: ":", omittingEmptySubsequences: false)
            guard s.filter({ $0 == ":" }).count >= 5, !s.lowercased().hasPrefix("fe80") else { continue }
            if !s.contains("::"), !groups.contains(where: { $0.count > 2 }) { continue }
            spans.append(TextSpan(kind: "identifier", priority: 2, range: m.range))
        }
        for m in R["macRegex"].all(ns) {
            let s = ns.text(m.range)
            if !isOneRepeatedCharacter(s), s.lowercased() != "aa:bb:cc:dd:ee:ff" {
                spans.append(TextSpan(kind: "identifier", priority: 2, range: m.range))
            }
        }
        for m in R["walletRegex"].all(ns) where !isOneRepeatedCharacter(String(ns.text(m.range).dropFirst(2))) {
            spans.append(TextSpan(kind: "identifier", priority: 1, range: m.range))
        }
    }
}

// MARK: - Frame layout

/// `ContextLabel` returned by `pureLabel(_:)`.
enum ContextLabel {
    case secret, phrase, identifier
}

extension Classifier {
    /// `findSensitiveSpans(inFrame:)`: per-line spans, then the multi-line rules (private key
    /// blocks, label → value cells, dangling labels, printed secrets, wrapped values, seed phrases
    /// under a label), visiting lines top to bottom, left to right.
    static func frameSpans(_ lines: [SensitiveTextLine]) -> [[TextSpan]] {
        var spans = lines.map { findSensitiveSpans(in: $0.text) + findMergedLabelValueSpans(in: GateLine($0.text)) }
        let layout = FrameLayout(lines: lines)
        let order = lines.indices.sorted { a, b in
            let ra = lines[a].rect, rb = lines[b].rect
            if ra.minY != rb.minY { return ra.minY < rb.minY }
            if ra.minX != rb.minX { return ra.minX < rb.minX }
            return a < b
        }
        func cover(_ line: Int, _ range: NSRange, _ kind: String) {
            guard range.length > 0 else { return }
            spans[line] = mergeSpans(spans[line] + [TextSpan(kind: kind, priority: 1, range: range)])
        }

        for i in order {
            let line = GateLine(lines[i].text)
            let trimmed = lines[i].text.trimmingCharacters(in: whitespaceSet)

            // `-----BEGIN … PRIVATE KEY-----` covers the aligned lines under it up to the END line.
            if R["privateKeyHeaderRegex"].test(trimmed) {
                var current = i
                for _ in 0..<80 {
                    guard let next = layout.lineBelow(current, aligned: true) else { break }
                    current = next
                    if lines[next].text.contains("-----END") { break }
                    cover(next, wholeTextRange(of: lines[next].text), "privateKey")
                }
            }

            // A cell that is only a label: its value is beside it or below it.
            if let label = pureLabel(trimmed), let cell = layout.valueCell(besideOrBelow: i),
               let range = labelledValueRange(GateLine(lines[cell].text), label: label) {
                cover(cell, range, label == .identifier ? "identifier" : "secret")
            }

            // `token:` with nothing after it: the next line's first token.
            if R["danglingLabelRegex"].test(trimmed), pureLabel(trimmed) == nil,
               !spans[i].contains(where: { reachesEnd($0.range, of: line) }),
               let next = layout.lineBelow(i, aligned: false) {
                let below = GateLine(lines[next].text)
                if let m = R["leadingTokenRegex"].first(below.text), m.has(1) {
                    let token = below.ns.text(m.range(at: 1))
                    if token.count >= 8, !isWordy(token), !R["chromeRegex"].test(token), !R["maskedRegex"].test(token) {
                        cover(next, m.range(at: 1), "secret")
                    }
                }
            }

            // `echo $TOKEN`, `gh auth token`…: the output line below.
            if R["printedSecretCommandRegex"].test(trimmed), let next = layout.lineBelow(i, aligned: true) {
                let below = GateLine(lines[next].text)
                if let m = R["firstWordRegex"].first(below.text), m.has(1) {
                    let word = below.ns.text(m.range(at: 1))
                    if word.count >= 6, !isWordy(word), !R["placeholderValueRegex"].whole(word) {
                        cover(next, m.range(at: 1), "secret")
                    }
                }
            }

            // A value that reaches the end of a full line continues on the next one.
            if let span = spans[i].last(where: { reachesEnd($0.range, of: line) }),
               line.length >= 20, layout.isFull(i), let next = layout.lineBelow(i, aligned: true) {
                let below = GateLine(lines[next].text)
                var covered = false
                if ["email", "iban", "phone", "card", "identifier"].contains(span.kind),
                   let m = R["identifierContinuationRegex"].first(below.text), m.has(1),
                   below.ns.text(m.range(at: 1)).contains(where: { $0.isNumber || $0 == "." }) {
                    cover(next, m.range(at: 1), span.kind)
                    covered = true
                }
                if !covered, let m = R["leadingTokenRegex"].first(below.text), m.has(1),
                   isWrappedContinuation(below.ns.text(m.range(at: 1)), ofWholeLine: below) {
                    cover(next, m.range(at: 1), span.kind)
                }
            }

            // Seed phrases: under a short seed label, or continuing a phrase found on this line.
            var seedBelow = false
            if R["seedLabelRegex"].test(trimmed), trimmed.count < 61 {
                seedBelow = true
            } else {
                for span in spans[i] {
                    let text = line.ns.text(span.range)
                    guard text.split(separator: " ").count >= 5 else { continue }
                    if findSeedPhrase(in: GateLine(text), minWords: 5) != nil {
                        seedBelow = true
                        break
                    }
                }
            }
            if seedBelow, let next = layout.lineBelow(i, aligned: false),
               let range = findSeedPhrase(in: GateLine(lines[next].text), minWords: 5) {
                cover(next, range, "secret")
            }
        }
        return spans
    }

    /// `wholeTextRange(of:)`: the line without leading/trailing spaces and tabs.
    static func wholeTextRange(of text: String) -> NSRange {
        let units = Array(text.utf16)
        var start = 0
        var end = units.count
        while start < end, units[start] == 0x20 || units[start] == 0x09 { start += 1 }
        while end > start, units[end - 1] == 0x20 || units[end - 1] == 0x09 { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// `reachesEnd(_:of:)`: the range ends at the line end, ignoring trailing spaces, tabs,
    /// quotes, commas, backslashes, semicolons and `)`.
    static func reachesEnd(_ range: NSRange, of line: GateLine) -> Bool {
        let trailing: Set<UInt16> = Set(" \t\"',\\;)".utf16)
        let units = Array(line.text.utf16)
        var end = line.length
        while end >= 1, trailing.contains(units[end - 1]) { end -= 1 }
        return range.end >= end
    }

    /// `pureLabel(_:)`: the cell is only a label.
    static func pureLabel(_ s: String) -> ContextLabel? {
        let words = s.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, words.count <= 4 else { return nil }
        if R["codeStartRegex"].test(s) || R["labelDisqualifierRegex"].test(s) { return nil }
        if s.contains(where: \.isNumber), !s.hasPrefix("2FA"), !s.lowercased().contains("2fa") { return nil }
        if words.contains(where: { looksRandom(String($0)) }) { return nil }
        if R["secretLabelRegex"].test(s) { return R["phraseLabelRegex"].test(s) ? .phrase : .secret }
        if R["identifierLabelOnlyRegex"].whole(s) { return .identifier }
        return nil
    }

    /// `isWordy(_:)`: prose, not a value.
    static func isWordy(_ s: String) -> Bool {
        var t = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"',\\"))
        while t.hasSuffix("=") { t.removeLast() }
        if R["wordyRegex"].whole(t) { return true }
        if t.contains(where: \.isNumber) { return false }
        if t.count >= 4, pronounceableLetterRatio(t) >= 0.8 { return true }
        if classSwitchRatio(t) >= 0.2 { return false }
        if t.contains("+") { return false }
        return !t.contains("/")
    }

    /// `labelledValueRange(_:label:)`: where the value of a label is in its cell.
    static func labelledValueRange(_ line: GateLine, label: ContextLabel) -> NSRange? {
        let t = line.text.trimmingCharacters(in: whitespaceSet)
        let words = t.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, words.count < 7, pureLabel(t) == nil, !t.isEmpty,
              !R["chromeRegex"].test(t), !R["maskedRegex"].test(t), !R["secretLabelRegex"].test(t),
              let head = t.first, !"/~".contains(head), !t.hasSuffix(":")
        else { return nil }
        if label == .identifier, t.filter(\.isNumber).count < 3 { return nil }
        let symbols = "#$%&*+/=@^_~|\\-"
        let valueLike = words.contains { word in
            word.count >= 3 && (word.contains(where: \.isNumber) || word.contains(where: { symbols.contains($0) }) || R["mixedCaseRegex"].test(String(word)))
        }
        if valueLike || words.count == 1 || label == .phrase { return wholeTextRange(of: line.text) }
        return nil
    }

    /// `findMergedLabelValueSpans(in:)`: OCR merged "Label value" into one line.
    static func findMergedLabelValueSpans(in line: GateLine) -> [TextSpan] {
        guard let m = R["mergedLabelValueRegex"].first(line.text), m.has(1), m.has(2) else { return [] }
        let label = line.ns.text(m.range(at: 1))
        guard let first = label.first, first.isUppercase, let kind = pureLabel(label) else { return [] }
        let value = line.ns.text(m.range(at: 2))
        guard !isWordy(value), labelledValueRange(GateLine(value), label: kind) != nil else { return [] }
        return [TextSpan(kind: "secret", priority: 1, range: m.range(at: 2))]
    }

    /// `isWrappedContinuation(_:ofWholeLine:)`: the first token of the next line is the rest
    /// of a value cut by the line end.
    static func isWrappedContinuation(_ token: String, ofWholeLine line: GateLine) -> Bool {
        if R["assignmentStartRegex"].test(token) || isWordy(token) { return false }
        if R["gutterNumberRegex"].test(token) { return false }
        if token.allSatisfy(\.isNumber) { return false }
        if R["placeholderValueRegex"].whole(token) { return false }
        let wholeLine = line.text.trimmingCharacters(in: whitespaceSet).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`,;)\\ "))
        var alone = false
        if !wholeLine.hasSuffix(token) {
            alone = line.text.split(whereSeparator: \.isWhitespace).count == 1
        }
        let quoted = token.first.map { "\"'`".contains($0) } ?? false
        let minLength = quoted ? 4 : 6
        var mixed = false
        if token.count >= minLength, token.contains(where: \.isNumber) {
            if alone { return true }
            mixed = classSwitchRatio(token) >= 0.3
        } else if alone {
            return true
        }
        return token.count > 11 || mixed
    }
}

/// `FrameLayout`: geometry over the frame's lines.
struct FrameLayout {
    let lines: [SensitiveTextLine]

    private func charWidth(_ i: Int) -> Double {
        Double(lines[i].rect.width) / Double(max(lines[i].text.count, 1))
    }

    /// `FrameLayout.lineBelow(_:aligned:)`: the nearest line under `i` whose top is within 0.9
    /// line heights, of similar height (0.65–1.55), left-aligned within 1.5 characters (or, when
    /// not `aligned`, overlapping it horizontally).
    func lineBelow(_ i: Int, aligned: Bool) -> Int? {
        let r = lines[i].rect
        var best: Int?
        var bestGap = 0.0
        for j in lines.indices where j != i {
            let o = lines[j].rect
            guard r.maxY < o.midY else { continue }
            let gap = Double(o.minY - r.maxY)
            guard gap <= Double(r.height) * 0.9 else { continue }
            let ratio = r.height >= 1 ? Double(o.height / r.height) : Double(o.height)
            guard ratio > 0.65, ratio < 1.55 else { continue }
            var ok = !aligned && o.minX < r.maxX && r.minX < o.maxX
            if !ok {
                let cw = max(charWidth(j), charWidth(i))
                ok = abs(Double(o.minX - r.minX)) <= cw * 1.5
            }
            guard ok else { continue }
            if best == nil || gap < bestGap {
                best = j
                bestGap = gap
            }
        }
        return best
    }

    /// `FrameLayout.valueCell(besideOrBelow:)`: the nearest cell to the right on the same row
    /// (skipping empty, chrome and masked cells), else the aligned line below.
    func valueCell(besideOrBelow i: Int) -> Int? {
        let r = lines[i].rect
        var candidates: [Int] = []
        for j in lines.indices where j != i {
            let o = lines[j].rect
            let overlap = Double(min(r.maxY, o.maxY) - max(r.minY, o.minY))
            let ratio = Double(r.height / o.height)
            guard overlap >= Double(min(r.height, o.height)) * 0.5, ratio > 0.65, ratio < 1.55 else { continue }
            guard Double(r.maxX) - charWidth(i) <= Double(o.minX), Double(o.minX - r.maxX) <= Double(r.height) * 25 else { continue }
            candidates.append(j)
        }
        guard !candidates.isEmpty else { return lineBelow(i, aligned: true) }
        let sorted = candidates.enumerated().sorted { (lines[$0.element].rect.minX, $0.offset) < (lines[$1.element].rect.minX, $1.offset) }.map(\.element)
        for j in sorted {
            let t = lines[j].text.trimmingCharacters(in: whitespaceSet)
            if t.isEmpty || Classifier.R["chromeRegex"].test(t) || Classifier.R["maskedRegex"].test(t) { continue }
            return j
        }
        return nil
    }

    /// `FrameLayout.isFull(_:)`: the line reaches (within two characters) the right edge of
    /// the left-aligned block it belongs to.
    func isFull(_ i: Int) -> Bool {
        let r = lines[i].rect
        let cw = charWidth(i)
        var right = Double(r.maxX)
        for j in lines.indices where j != i {
            let o = lines[j].rect
            guard abs(Double(o.minX - r.minX)) <= cw * 1.5, abs(Double(o.midY - r.midY)) <= Double(r.height) * 4 else { continue }
            let ratio = r.height >= 1 ? Double(o.height / r.height) : Double(o.height)
            guard ratio > 0.65, ratio < 1.55 else { continue }
            right = max(right, Double(o.maxX))
        }
        return right - 2 * cw <= Double(r.maxX)
    }
}

// MARK: - Custom phrases

/// `PhraseLayer.init(phrase:)`: whole words, ignoring case, accents and width.
/// `readPhrase(_:lines:phrase:)` matches it against each line folded the same way when folding
/// keeps the line's UTF-16 and character counts, else against the line as read.
struct PhraseLayer {
    let regex: NSRegularExpression

    init?(phrase: String) {
        let folded = phrase.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        let words = folded.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return nil }
        let rules = SensitiveRules.shared
        let pattern = rules.phrasePrefix + words.joined(separator: "\\s*") + rules.phraseSuffix
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        self.regex = regex
    }

    func ranges(in text: String) -> [NSRange] {
        let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        let subject = folded.utf16.count == text.utf16.count && folded.count == text.count ? folded : text
        return regex.matches(in: subject, range: NSRange(location: 0, length: (subject as NSString).length)).map(\.range)
    }
}
