import AppKit
import Darwin
import Foundation

enum ParsedHostKind {
    case domain, ipv4, ipv6
}

struct ParsedHost {
    let kind: ParsedHostKind
    let value: String
    var isIP: Bool { kind != .domain }
}

enum HostParser {
    static func parse(_ input: String) -> ParsedHost? {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.count >= 2, (raw.hasPrefix("\"") && raw.hasSuffix("\"")) || (raw.hasPrefix("'") && raw.hasSuffix("'")) {
            raw = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !raw.isEmpty, raw.count <= 2048, raw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        if let cidr = parseCIDR(raw) { return cidr }
        if looksLikeCidr(raw) { return nil }
        if raw.contains("://") || raw.hasPrefix("//") || raw.lowercased().hasPrefix("www.") || raw.contains("/") {
            guard let host = hostFromURL(raw) else { return nil }
            raw = host
        } else if let split = stripPort(raw) {
            raw = split
        }
        raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !raw.isEmpty, raw.count <= 253 else { return nil }
        if let ip = parseIP(raw) { return ip }
        return parseDomain(raw)
    }

    static func normalize(_ input: String) -> String? { parse(input)?.value }

    private static func hostFromURL(_ raw: String) -> String? {
        var candidate = raw
        if candidate.hasPrefix("//") { candidate = "http:" + candidate }
        else if !candidate.contains("://") { candidate = "http://" + candidate }
        guard let url = URL(string: candidate), let scheme = url.scheme, ["http", "https", "ws", "wss"].contains(scheme) else { return nil }
        var host = url.host ?? ""
        if host.hasPrefix("["), host.hasSuffix("]"), host.count > 2 { host = String(host.dropFirst().dropLast()) }
        return host.isEmpty ? nil : host
    }

    private static func stripPort(_ raw: String) -> String? {
        if raw.hasPrefix("["), let close = raw.firstIndex(of: "]") {
            let host = String(raw[raw.index(after: raw.startIndex)..<close])
            let rest = raw[raw.index(after: close)...]
            if rest.isEmpty { return host }
            guard rest.first == ":", let port = Int(rest.dropFirst()), (1...65535).contains(port) else { return nil }
            return host
        }
        guard let colon = raw.lastIndex(of: ":"), raw.firstIndex(of: ":") == colon else { return nil }
        guard let port = Int(raw[raw.index(after: colon)...]), (1...65535).contains(port) else { return nil }
        return String(raw[..<colon])
    }

    private static func looksLikeCidr(_ raw: String) -> Bool {
        guard let slash = raw.lastIndex(of: "/"), slash != raw.startIndex else { return false }
        var addr = String(raw[..<slash])
        if addr.hasPrefix("["), addr.hasSuffix("]"), addr.count > 2 { addr = String(addr.dropFirst().dropLast()) }
        return isIPv4(addr) || isIPv6(addr)
    }

    private static func parseCIDR(_ raw: String) -> ParsedHost? {
        guard let slash = raw.lastIndex(of: "/"), slash != raw.startIndex else { return nil }
        var addr = String(raw[..<slash])
        let prefixText = String(raw[raw.index(after: slash)...])
        guard let prefix = Int(prefixText) else { return nil }
        if addr.hasPrefix("["), addr.hasSuffix("]"), addr.count > 2 { addr = String(addr.dropFirst().dropLast()) }
        if isIPv4(addr), (0...32).contains(prefix) { return ParsedHost(kind: .ipv4, value: "\(addr)/\(prefix)") }
        if isIPv6(addr), (0...128).contains(prefix) { return ParsedHost(kind: .ipv6, value: "\(addr)/\(prefix)") }
        return nil
    }

    private static func parseIP(_ raw: String) -> ParsedHost? {
        var value = raw
        if value.hasPrefix("["), value.hasSuffix("]"), value.count > 2 { value = String(value.dropFirst().dropLast()) }
        if isIPv4(value) { return ParsedHost(kind: .ipv4, value: value) }
        if isIPv6(value) { return ParsedHost(kind: .ipv6, value: value) }
        return nil
    }

    private static func parseDomain(_ raw: String) -> ParsedHost? {
        let ascii: String
        if raw.unicodeScalars.allSatisfy({ $0.isASCII }) {
            ascii = raw.lowercased()
        } else if let host = URL(string: "http://\(raw)")?.host, !host.isEmpty {
            ascii = host.lowercased()
        } else {
            return nil
        }
        let labels = ascii.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ (1...63).contains($0.count) }) else { return nil }
        if labels.count == 4, labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return nil }
        guard ascii.range(of: "^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$", options: .regularExpression) != nil else { return nil }
        return ParsedHost(kind: .domain, value: ascii)
    }

    private static func isIPv4(_ text: String) -> Bool {
        var addr = in_addr()
        return text.withCString { inet_pton(AF_INET, $0, &addr) == 1 }
    }

    private static func isIPv6(_ text: String) -> Bool {
        var addr = in6_addr()
        return text.withCString { inet_pton(AF_INET6, $0, &addr) == 1 }
    }
}

enum UserListIO {
    static let bypassDomains = "list-general-user.txt"
    static let bypassIpset = "ipset-all-user.txt"
    static let excludeDomains = "list-exclude-user.txt"
    static let excludeIpset = "ipset-exclude-user.txt"

    static func file(isIP: Bool, exclude: Bool) -> String {
        switch (isIP, exclude) {
        case (false, false): return bypassDomains
        case (false, true): return excludeDomains
        case (true, false): return bypassIpset
        case (true, true): return excludeIpset
        }
    }

    static func entries(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if seen.insert(line.lowercased()).inserted { result.append(line) }
        }
        return result
    }

    static func add(_ text: String, entry: String) -> String {
        if entries(text).contains(where: { $0.caseInsensitiveCompare(entry) == .orderedSame }) {
            return normalize(text)
        }
        var body = normalize(text)
        if !body.isEmpty, !body.hasSuffix("\n") { body += "\n" }
        return body + entry + "\n"
    }

    static func remove(_ text: String, entry: String) -> String {
        let kept = normalize(text).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(entry) != .orderedSame }
            .map(String.init)
        let trimmed = kept.reversed().drop(while: \.isEmpty).reversed()
        if trimmed.isEmpty { return "" }
        return trimmed.joined(separator: "\n") + "\n"
    }

    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}

enum UpstreamLists {
    static let baseURL = "https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/lists/"
    static let files = [
        "list-general.txt",
        "list-google.txt",
        "list-exclude.txt",
        "ipset-all.txt",
        "ipset-exclude.txt",
    ]

    static func isUser(_ name: String) -> Bool { name.contains("-user") }
    static func isUpstream(_ name: String) -> Bool { files.contains(name) }

    static func validate(name: String, text: String) -> String? {
        if isUser(name) { return "Пользовательские списки не обновляются из upstream." }
        if !isUpstream(name) { return "Неизвестный список: \(name)" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "\(name): пустой файл." }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("<!doctype") || lower.hasPrefix("<html") || lower.contains("<head>") || lower.contains("404: not found") {
            return "\(name): ответ не похож на список (HTML)."
        }
        var total = 0, valid = 0
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            total += 1
            if HostParser.parse(line) != nil { valid += 1 }
        }
        if valid == 0 { return "\(name): нет ни одной корректной записи." }
        if total > 0, valid * 5 < total * 4 { return "\(name): слишком много битых строк." }
        return nil
    }
}

enum StrategyOrdering {
    static let preferredIDs = [
        "general-simple-fake",
        "general",
        "general-alt",
        "general-fake-tls-auto",
        "general-alt2",
    ]

    static func smartOrder(_ all: [Strategy], currentID: String, winners: [String]) -> [Strategy] {
        var remaining = all
        var ordered: [Strategy] = []
        func take(_ match: (Strategy) -> Bool) {
            var i = remaining.startIndex
            while i < remaining.endIndex {
                if match(remaining[i]) {
                    ordered.append(remaining[i])
                    remaining.remove(at: i)
                } else {
                    remaining.formIndex(after: &i)
                }
            }
        }
        if !currentID.isEmpty { take { $0.id == currentID } }
        for winner in winners {
            let name = winner.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            take { $0.id == name || $0.name == name }
        }
        for id in preferredIDs { take { $0.id == id } }
        ordered.append(contentsOf: remaining)
        return ordered
    }

    static func parseWinners(_ text: String) -> [String] {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("Лучшая: ") { body = String(body.dropFirst("Лучшая: ".count)) }
        if body.hasPrefix("не определена") { return [] }
        if let paren = body.range(of: " (", options: .backwards), body.hasSuffix(")") {
            body = String(body[..<paren.lowerBound])
        }
        return body.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func progressFraction(_ text: String) -> Double {
        guard let match = text.range(of: "(\\d+)\\s*/\\s*(\\d+)", options: .regularExpression) else { return 0 }
        let parts = text[match].split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let current = Double(parts[0]), let total = Double(parts[1]), total > 0 else { return 0 }
        return min(max(current / total, 0), 1)
    }
}

struct DiagnosticItem: Identifiable, Equatable {
    let level: String
    let name: String
    let detail: String
    var id: String { level + ":" + name }
    var isFail: Bool { level == "FAIL" }
    var isWarn: Bool { level == "WARN" }
}

enum VpnProbe {
    static func defaultInterface() -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", "default"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count >= 2, parts[0] == "interface:" { return String(parts[1]) }
        }
        return ""
    }

    static func warning(for iface: String, nimbus: String = "utun50") -> String? {
        let name = iface.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == nimbus { return nil }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") || name == "wg0" {
            return "маршрут по умолчанию через \(name)"
        }
        return nil
    }
}

enum MotionSettings {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
