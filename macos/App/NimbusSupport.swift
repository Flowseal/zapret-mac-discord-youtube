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

// MARK: - Panel helpers

struct LogLine: Identifiable, Equatable {
    let id: Int
    let source: String
    let time: String
    let level: String
    let text: String
}

enum LogParser {
    /// Turns raw log text into rows. A leading `HH:MM:SS`, `[HH:MM:SS]` or ISO date-time stamp becomes the time
    /// column; the level comes from an explicit tag or from error/warning keywords.
    static func parse(_ text: String, source: String, startID: Int = 0) -> [LogLine] {
        var out: [LogLine] = []
        var id = startID
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            var time = "--:--:--"
            if let match = line.range(of: #"^\[?(\d{4}-\d{2}-\d{2}[T ])?\d{2}:\d{2}:\d{2}(\.\d+)?([+-]\d{2}:?\d{2}|Z)?\]?\s*"#, options: .regularExpression) {
                let stamp = String(line[match])
                if let clock = stamp.range(of: #"\d{2}:\d{2}:\d{2}"#, options: .regularExpression) {
                    time = String(stamp[clock])
                }
                line = String(line[match.upperBound...])
            }
            var level = "INF"
            if let tag = line.range(of: #"^\[?(INF|INFO|WRN|WARN|WARNING|ERR|ERROR)\]?:?\s+"#, options: [.regularExpression, .caseInsensitive]) {
                let word = line[tag].uppercased()
                level = word.contains("E") && word.contains("R") && !word.contains("W") ? "ERR" : word.contains("W") ? "WRN" : "INF"
                line = String(line[tag.upperBound...])
            } else {
                let lower = line.lowercased()
                if lower.contains("error") || lower.contains("fail") || lower.contains("ошибк") || lower.contains("не удалось") || lower.contains("fatal") {
                    level = "ERR"
                } else if lower.contains("warn") || lower.contains("timeout") || lower.contains("retry") || lower.contains("предупрежд") {
                    level = "WRN"
                }
            }
            out.append(LogLine(id: id, source: source, time: time, level: level, text: line))
            id += 1
        }
        return out
    }

    /// Plain words must all appear; `level:wrn+` keeps warnings and errors, `level:err` errors only.
    static func matches(_ line: LogLine, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return true }
        for token in q.split(separator: " ") {
            if token.hasPrefix("level:") {
                let want = token.dropFirst("level:".count)
                let rank = ["inf": 0, "wrn": 1, "err": 2]
                let lineRank = rank[line.level.lowercased()] ?? 0
                if want.hasSuffix("+") {
                    guard let need = rank[String(want.dropLast())], lineRank >= need else { return false }
                } else {
                    guard let need = rank[String(want)], lineRank == need else { return false }
                }
                continue
            }
            if token.hasPrefix("source:") {
                if line.source.lowercased() != token.dropFirst("source:".count) { return false }
                continue
            }
            let hay = (line.text + " " + line.source + " " + line.time).lowercased()
            if !hay.contains(token) { return false }
        }
        return true
    }

    /// 52113 → "52 113" (thin non-breaking space).
    static func groupThousands(_ value: Int) -> String {
        let digits = String(abs(value))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append("\u{202F}") }
            out.append(ch)
        }
        return value < 0 ? "-" + out : out
    }
}

enum LatencyStats {
    /// Linear-interpolated percentile, p in 0…1.
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.filter { $0.isFinite }.sorted()
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let rank = min(max(p, 0), 1) * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = min(lo + 1, sorted.count - 1)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (rank - Double(lo))
    }
}

enum EngineClock {
    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    /// `ps` etime: [[dd-]hh:]mm:ss → seconds.
    static func parseElapsed(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var days = 0
        var rest = Substring(trimmed)
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Int(rest[..<dash]) else { return nil }
            days = d
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let nums = parts.compactMap { $0 }
        var total = 0
        for n in nums { total = total * 60 + n }
        return TimeInterval(days * 86_400 + total)
    }

    /// Start time of the running engine (utunws), read from `ps`.
    static func engineStartDate() -> Date? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "etime=,comm="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, parts[1].hasSuffix("utunws") else { continue }
            if let elapsed = parseElapsed(String(parts[0])) {
                return Date().addingTimeInterval(-elapsed)
            }
        }
        return nil
    }
}

enum SystemInfo {
    static var summary: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let version = v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return "macOS \(version) · \(arch)"
    }

    /// First IPv4 address of an interface (en0 …) via getifaddrs.
    static func ipv4Address(of interface: String) -> String {
        guard !interface.isEmpty else { return "" }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return "" }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            guard String(cString: entry.pointee.ifa_name) == interface else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return ""
    }
}

// MARK: - Release versions

/// Semver-style order for release tags: 1.5.0 < 1.6.0-beta.1 < 1.6.0-beta.2 < 1.6.0-rc.1 < 1.6.0.
/// A leading "v" and "+build" metadata are ignored. Same rules as Versioning.Compare on Windows.
enum ReleaseVersion {
    static func display(_ version: String) -> String {
        version.first == "v" || version.first == "V" ? String(version.dropFirst()) : version
    }

    /// "v1.6.0-beta.1" -> "1.6.0", the part that goes into CFBundleShortVersionString.
    static func numeric(_ version: String) -> String {
        split(version).core
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, installed) == .orderedDescending
    }

    /// Index of the release to offer from the GitHub /releases list: the highest version above `installed`
    /// that is not a draft and has our asset. Pre-releases count, so 1.5.0 gets a beta and the beta gets the release.
    static func pickUpdate(_ releases: [(tag: String, draft: Bool, hasAsset: Bool)], installed: String) -> Int? {
        var best: Int?
        for (index, release) in releases.enumerated() where !release.draft && release.hasAsset && isNewer(release.tag, than: installed) {
            if let current = best, compare(release.tag, releases[current].tag) != .orderedDescending { continue }
            best = index
        }
        return best
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let lhs = split(a)
        let rhs = split(b)
        let core = compareParts(lhs.core.components(separatedBy: "."), rhs.core.components(separatedBy: "."), padWithZero: true)
        if core != .orderedSame { return core }
        switch (lhs.pre.isEmpty, rhs.pre.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending // 1.6.0 > 1.6.0-beta.1
        case (false, true): return .orderedAscending
        case (false, false):
            return compareParts(lhs.pre.components(separatedBy: "."), rhs.pre.components(separatedBy: "."), padWithZero: false)
        }
    }

    private static func split(_ version: String) -> (core: String, pre: String) {
        var value = display(version.trimmingCharacters(in: .whitespaces))
        if let plus = value.firstIndex(of: "+") { value = String(value[..<plus]) }
        guard let dash = value.firstIndex(of: "-") else { return (value, "") }
        return (String(value[..<dash]), String(value[value.index(after: dash)...]))
    }

    private static func compareParts(_ a: [String], _ b: [String], padWithZero: Bool) -> ComparisonResult {
        for i in 0..<max(a.count, b.count) {
            if !padWithZero && i >= a.count { return .orderedAscending }
            if !padWithZero && i >= b.count { return .orderedDescending }
            let sa = i < a.count ? a[i] : "0"
            let sb = i < b.count ? b[i] : "0"
            let result: ComparisonResult
            switch (Int(sa), Int(sb)) {
            case let (na?, nb?): result = na == nb ? .orderedSame : (na < nb ? .orderedAscending : .orderedDescending)
            case (.some, nil): result = .orderedAscending // "beta.1" < "beta.x"
            case (nil, .some): result = .orderedDescending
            case (nil, nil): result = sa.caseInsensitiveCompare(sb)
            }
            if result != .orderedSame { return result }
        }
        return .orderedSame
    }
}

/// The kernel process table, read with sysctl (no subprocess).
enum ProcessTable {
    /// Whether a process with this exact short name (p_comm, like `pgrep -x`) is running; nil if sysctl failed.
    static func contains(_ name: String) -> Bool? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        let stride = MemoryLayout<kinfo_proc>.stride
        // the table can grow between the two calls
        var count = size / stride + 32
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return nil }
        count = size / stride
        let wanted = Array(name.utf8.prefix(Int(MAXCOMLEN)))
        for i in 0..<count {
            let match = withUnsafeBytes(of: procs[i].kp_proc.p_comm) { raw in
                Array(raw.prefix { $0 != 0 }) == wanted
            }
            if match { return true }
        }
        return false
    }
}
