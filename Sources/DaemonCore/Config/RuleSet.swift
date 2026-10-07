import Foundation
import MailCore

/// One condition of a rule (design §7.2), tagged by `"type"` in JSON.
public enum RuleCondition: Codable, Sendable, Equatable {
    /// The header has a non-empty trimmed value. Names are case-insensitive.
    case headerPresent(header: String)
    /// Unanchored search on the normalised From address.
    case fromAddress(pattern: String)
    /// `Auto-Submitted` is present and its normalised value is not in the list.
    case autoSubmitted(notIn: [String])
    /// Whole match against any subject token.
    case subjectToken(pattern: String)
    /// Whole match against any sender token (display name and the address's local part).
    case senderToken(pattern: String)
    /// The From address is in the sent cache and is not one of mine.
    case fromInSentCache
    /// Whole match, case-insensitive, against any of the decider's user-label names.
    case hasLabel(pattern: String)
    /// The decider carries this system label ID.
    case hasSystemLabel(id: String)

    public var type: String {
        switch self {
        case .headerPresent: "headerPresent"
        case .fromAddress: "fromAddress"
        case .autoSubmitted: "autoSubmitted"
        case .subjectToken: "subjectToken"
        case .senderToken: "senderToken"
        case .fromInSentCache: "fromInSentCache"
        case .hasLabel: "hasLabel"
        case .hasSystemLabel: "hasSystemLabel"
        }
    }

    /// The regex source, for conditions that have one.
    public var pattern: String? {
        switch self {
        case .fromAddress(let p), .subjectToken(let p), .senderToken(let p), .hasLabel(let p): p
        default: nil
        }
    }

    private enum CodingKeys: String, CodingKey { case type, header, pattern, notIn, id }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        func strict(_ keys: [String]) throws { try StrictKeys.check(decoder, ["type"] + keys) }
        switch type {
        case "headerPresent":
            try strict(["header"]); self = .headerPresent(header: try c.decode(String.self, forKey: .header))
        case "fromAddress":
            try strict(["pattern"]); self = .fromAddress(pattern: try c.decode(String.self, forKey: .pattern))
        case "autoSubmitted":
            try strict(["notIn"]); self = .autoSubmitted(notIn: try c.decodeIfPresent([String].self, forKey: .notIn) ?? [])
        case "subjectToken":
            try strict(["pattern"]); self = .subjectToken(pattern: try c.decode(String.self, forKey: .pattern))
        case "senderToken":
            try strict(["pattern"]); self = .senderToken(pattern: try c.decode(String.self, forKey: .pattern))
        case "fromInSentCache":
            try strict([]); self = .fromInSentCache
        case "hasLabel":
            try strict(["pattern"]); self = .hasLabel(pattern: try c.decode(String.self, forKey: .pattern))
        case "hasSystemLabel":
            try strict(["id"]); self = .hasSystemLabel(id: try c.decode(String.self, forKey: .id))
        default:
            throw StrictKeys.UnknownType(path: StrictKeys.path(decoder.codingPath), type: type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .headerPresent(let h): try c.encode(h, forKey: .header)
        case .fromAddress(let p), .subjectToken(let p), .senderToken(let p), .hasLabel(let p): try c.encode(p, forKey: .pattern)
        case .autoSubmitted(let notIn): try c.encode(notIn, forKey: .notIn)
        case .fromInSentCache: break
        case .hasSystemLabel(let id): try c.encode(id, forKey: .id)
        }
    }
}

public struct RuleDefinition: Codable, Sendable, Equatable {
    public var id: String
    public var enabled: Bool
    public var label: String
    public var note: String?
    public var any: [RuleCondition]

    public init(id: String, enabled: Bool = true, label: String, note: String? = nil, any: [RuleCondition]) {
        self.id = id
        self.enabled = enabled
        self.label = label
        self.note = note
        self.any = any
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case id, enabled, label, note, any }

    public init(from decoder: any Decoder) throws {
        try StrictKeys.check(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        label = try c.decode(String.self, forKey: .label)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        any = try c.decode([RuleCondition].self, forKey: .any)
    }
}

public struct RuleOptions: Codable, Sendable, Equatable {
    /// Q8: an out-of-office reply in a thread I wrote to does not classify it.
    public var deferAutoReplyInMyThreads = true

    public init(deferAutoReplyInMyThreads: Bool = true) {
        self.deferAutoReplyInMyThreads = deferAutoReplyInMyThreads
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case deferAutoReplyInMyThreads }

    public init(from decoder: any Decoder) throws {
        try StrictKeys.check(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deferAutoReplyInMyThreads = try c.decodeIfPresent(Bool.self, forKey: .deferAutoReplyInMyThreads) ?? true
    }
}

/// `rules.json`, schema 1 (design §7.2).
public struct RuleFile: Codable, Sendable, Equatable {
    public var schema: Int
    /// Extra own addresses; the profile address and send-as addresses are added automatically.
    public var me: [String]
    public var options: RuleOptions
    public var rules: [RuleDefinition]

    public init(schema: Int = 1, me: [String] = [], options: RuleOptions = RuleOptions(), rules: [RuleDefinition]) {
        self.schema = schema
        self.me = me
        self.options = options
        self.rules = rules
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case schema, me, options, rules }

    public init(from decoder: any Decoder) throws {
        try StrictKeys.check(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        me = try c.decodeIfPresent([String].self, forKey: .me) ?? []
        options = try c.decodeIfPresent(RuleOptions.self, forKey: .options) ?? RuleOptions()
        rules = try c.decode([RuleDefinition].self, forKey: .rules)
    }

    /// Pretty JSON with sorted keys.
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }
}

/// A compiled, case-insensitive pattern. Swift `Regex` is not `Sendable`; compiled values are never
/// mutated after construction, so sharing them across tasks is safe.
public struct RulePattern: @unchecked Sendable, Equatable {
    public let source: String
    let regex: Regex<AnyRegexOutput>

    init(_ source: String) throws {
        self.source = source
        self.regex = try Regex(source).ignoresCase()
    }

    /// Whole match.
    public func matchesWhole(_ text: String) -> Bool {
        (try? regex.wholeMatch(in: text)) != nil
    }

    /// Unanchored search.
    public func occurs(in text: String) -> Bool {
        (try? regex.firstMatch(in: text)) != nil
    }

    public static func == (a: RulePattern, b: RulePattern) -> Bool { a.source == b.source }
}

public enum CompiledCondition: Sendable, Equatable {
    case headerPresent(String)          // lowercased name
    case fromAddress(RulePattern)
    case autoSubmitted(notIn: Set<String>)
    case subjectToken(RulePattern)
    case senderToken(RulePattern)
    case fromInSentCache
    case hasLabel(RulePattern)
    case hasSystemLabel(String)
}

public struct CompiledRule: Sendable, Equatable {
    public var id: String
    public var enabled: Bool
    public var label: String
    public var conditions: [CompiledCondition]
}

/// The effective rules: validated and compiled, in file order.
public struct CompiledRules: Sendable, Equatable {
    public var file: RuleFile
    public var rules: [CompiledRule]
    /// `file.me`, lowercased.
    public var me: Set<String>
    public var options: RuleOptions { file.options }
    /// Labels of enabled rules, deduplicated, in rule order (the sorter creates these in live mode).
    public var enabledLabels: [String] {
        var seen: Set<String> = []
        return rules.filter(\.enabled).map(\.label).filter { seen.insert($0.lowercased()).inserted }
    }

    /// The built-in defaults (design §7.3), used while `rules.json` is absent.
    public static var defaults: CompiledRules { DefaultRules.compiled }
}

public struct RuleSetError: Error, Equatable, Sendable {
    /// Finnish, one per problem, naming the rule and condition.
    public var problems: [String]

    public init(problems: [String]) {
        self.problems = problems
    }
}

/// Loading and validation of `rules.json` (design §7.2). A file with any problem is refused as a whole.
public enum RuleSet {
    public static func decode(_ data: Data) throws(RuleSetError) -> RuleFile {
        do {
            return try JSONDecoder().decode(RuleFile.self, from: data)
        } catch {
            throw RuleSetError(problems: ["rules.json: " + ConfigError.describe(error)])
        }
    }

    public static func load(_ data: Data) throws(RuleSetError) -> CompiledRules {
        try compile(try decode(data))
    }

    public static func compile(_ file: RuleFile) throws(RuleSetError) -> CompiledRules {
        var problems: [String] = []
        if file.schema != 1 { problems.append("tuntematon skeema \(file.schema) (tuettu 1)") }
        var ids: Set<String> = []
        var compiled: [CompiledRule] = []
        for (index, rule) in file.rules.enumerated() {
            let name = "sääntö \(rule.id.isEmpty ? "#\(index + 1)" : rule.id)"
            if rule.id.wholeMatch(of: /[a-z0-9-]+/) == nil {
                problems.append("\(name): tunnisteen (id) oltava muotoa [a-z0-9-]+")
            }
            if !ids.insert(rule.id).inserted { problems.append("\(name): sama id kahdesti") }
            problems += labelProblems(rule.label).map { "\(name): \($0)" }
            if rule.any.isEmpty { problems.append("\(name): ehtolista any on tyhjä") }
            var conditions: [CompiledCondition] = []
            for (ci, condition) in rule.any.enumerated() {
                let where_ = "\(name), ehto \(ci + 1) (\(condition.type))"
                do {
                    conditions.append(try compile(condition))
                } catch let error as PatternProblem {
                    problems.append("\(where_): \(error.message)")
                } catch {
                    problems.append("\(where_): \(error)")
                }
            }
            compiled.append(CompiledRule(id: rule.id, enabled: rule.enabled, label: rule.label, conditions: conditions))
        }
        for address in file.me where !MailAddress(name: nil, email: address).isValid {
            problems.append("me: \(address) ei ole kelvollinen osoite")
        }
        guard problems.isEmpty else { throw RuleSetError(problems: problems) }
        return CompiledRules(file: file, rules: compiled, me: Set(file.me.map { $0.lowercased() }))
    }

    /// A rule may set only a `Lajittelu/` label, and neither the marker nor `Vaatii toimenpidettä`.
    static func labelProblems(_ label: String) -> [String] {
        let nfc = label.precomposedStringWithCanonicalMapping
        let reserved = [SeiseLabels.Sorting.classifiedMarker, SeiseLabels.Sorting.needsAction]
            .map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        if !nfc.hasPrefix(SeiseLabels.Sorting.prefix) || nfc.count <= SeiseLabels.Sorting.prefix.count {
            return ["tunnisteen oltava muotoa \(SeiseLabels.Sorting.prefix)…"]
        }
        if reserved.contains(nfc.lowercased()) { return ["tunnistetta \(label) ei saa asettaa säännöllä"] }
        return []
    }

    struct PatternProblem: Error {
        var message: String
    }

    static func compile(_ condition: RuleCondition) throws -> CompiledCondition {
        func pattern(_ source: String) throws -> RulePattern {
            if let problem = unsupported(source) { throw PatternProblem(message: problem) }
            do {
                return try RulePattern(source)
            } catch {
                throw PatternProblem(message: "säännöllinen lauseke ei käänny: \(source)")
            }
        }
        switch condition {
        case .headerPresent(let header):
            let name = header.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
                throw PatternProblem(message: "otsakkeen nimi ei kelpaa: \(header)")
            }
            return .headerPresent(name.lowercased())
        case .fromAddress(let p): return .fromAddress(try pattern(p))
        case .autoSubmitted(let notIn): return .autoSubmitted(notIn: Set(notIn.map { $0.lowercased() }))
        case .subjectToken(let p): return .subjectToken(try pattern(p))
        case .senderToken(let p): return .senderToken(try pattern(p))
        case .fromInSentCache: return .fromInSentCache
        case .hasLabel(let p): return .hasLabel(try pattern(p))
        case .hasSystemLabel(let id):
            guard !id.isEmpty else { throw PatternProblem(message: "tunnisteen id puuttuu") }
            return .hasSystemLabel(id)
        }
    }

    /// `\b`/`\B` and lookbehind are refused: ICU, JS and Swift disagree on them (the Windows port shares the file).
    public static func unsupported(_ source: String) -> String? {
        let chars = Array(source)
        var i = 0
        var inClass = false
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                if !inClass, chars[i + 1] == "b" || chars[i + 1] == "B" { return "\\b ja \\B eivät ole sallittuja" }
                i += 2
                continue
            }
            if c == "[" { inClass = true } else if c == "]" { inClass = false }
            if !inClass, c == "(", i + 3 < chars.count, chars[i + 1] == "?", chars[i + 2] == "<",
               chars[i + 3] == "=" || chars[i + 3] == "!" {
                return "lookbehind (?<= / ?<!) ei ole sallittu"
            }
            i += 1
        }
        return nil
    }
}
