import Foundation

public enum QueryMatchMode: Sendable {
    case smart
    case contains
}

public enum QueryScope: String, Codable, Sendable {
    case filesAndFolders
    case filesOnly
    case foldersOnly
}

public struct ParsedSearchQuery: Sendable {
    public let mode: QueryMatchMode
    public let scope: QueryScope
    public let text: String

    public init(_ rawQuery: String) {
        var remainder = rawQuery[...]
        if remainder.first == "'" {
            mode = .contains
            remainder = remainder.dropFirst()
        } else {
            mode = .smart
        }

        if remainder.first == "/" {
            scope = .filesOnly
            remainder = remainder.dropFirst()
        } else if remainder.first == "\\" {
            scope = .foldersOnly
            remainder = remainder.dropFirst()
        } else {
            scope = .filesAndFolders
        }

        text = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var promptTitle: String {
        switch (mode, scope) {
        case (.smart, .filesOnly):
            return "Type a smart file search after /"
        case (.smart, .foldersOnly):
            return "Type a smart folder search after \\"
        case (.contains, .filesOnly):
            return "Type contained file text after '/"
        case (.contains, .foldersOnly):
            return "Type contained folder text after '\\"
        case (.contains, .filesAndFolders):
            return "Type contained name text after '"
        case (.smart, .filesAndFolders):
            return "Type a filename or folder name"
        }
    }
}

public struct PreparedNameMatcher: Sendable {
    public let mode: QueryMatchMode
    public let caseSensitive: Bool
    let normalizedNeedle: String
    let foldedQuery: [UnicodeScalar]

    public init(mode: QueryMatchMode, query: String, caseSensitive: Bool) {
        self.mode = mode
        self.caseSensitive = caseSensitive
        normalizedNeedle = normalized(query, caseSensitive: caseSensitive)
        foldedQuery = foldedScalars(query, caseSensitive: caseSensitive)
    }

    public func matches(_ name: String) -> Bool {
        switch mode {
        case .contains:
            return !normalizedNeedle.isEmpty
                && normalized(name, caseSensitive: caseSensitive).contains(normalizedNeedle)
        case .smart:
            guard !foldedQuery.isEmpty else { return false }
            var queryIndex = 0
            let count = foldedQuery.count
            if let ascii = asciiFolded(name, caseSensitive: caseSensitive) {
                for byte in ascii where queryIndex < count {
                    if UnicodeScalar(byte) == foldedQuery[queryIndex] { queryIndex += 1 }
                }
            } else {
                for scalar in foldedScalars(name, caseSensitive: caseSensitive) where queryIndex < count {
                    if scalar == foldedQuery[queryIndex] { queryIndex += 1 }
                }
            }
            return queryIndex == count
        }
    }
}

/// Smart-mode result scope and name verification shared by the adapter and backend.
public struct ResultFilter: Sendable {
    public let matcher: PreparedNameMatcher
    public let scope: QueryScope

    public init(query: ParsedSearchQuery, caseSensitive: Bool) {
        matcher = PreparedNameMatcher(mode: query.mode, query: query.text, caseSensitive: caseSensitive)
        scope = query.scope
    }

    public init(mode: QueryMatchMode, text: String, scope: QueryScope, caseSensitive: Bool) {
        matcher = PreparedNameMatcher(mode: mode, query: text, caseSensitive: caseSensitive)
        self.scope = scope
    }

    @inline(__always)
    public func accepts(name: String, isDirectory: Bool) -> Bool {
        switch scope {
        case .filesOnly where isDirectory, .foldersOnly where !isDirectory:
            return false
        default:
            return matcher.matches(name)
        }
    }
}

/// The result name exactly as `URL(fileURLWithPath:).lastPathComponent` reports it.
/// For ASCII paths that is just the bytes after the final slash, so the costly URL
/// construction is skipped. Non-ASCII paths still go through URL, which returns the
/// file-system (decomposed) Unicode form that matching and display have always used.
@inline(__always)
public func indexedName(of path: String) -> String {
    let utf8 = path.utf8
    guard path.utf8.allSatisfy({ $0 < 0x80 }), utf8.last != 0x2F,
          let slash = utf8.lastIndex(of: 0x2F) else {
        return URL(fileURLWithPath: path).lastPathComponent
    }
    return String(path[path.index(after: slash)...])
}

/// Number of `/` separators, counted the same way as a Character scan of the path.
@inline(__always)
public func pathSlashCount(_ path: String) -> Int {
    if path.utf8.allSatisfy({ $0 < 0x80 }) {
        return path.utf8.reduce(into: 0) { if $1 == 0x2F { $0 += 1 } }
    }
    return path.reduce(into: 0) { if $1 == "/" { $0 += 1 } }
}

private func normalized(_ value: String, caseSensitive: Bool) -> String {
    caseSensitive ? value : value.lowercased()
}

/// Fast path equivalent to `foldedScalars` for pure-ASCII names: width folding is a no-op on
/// ASCII, case folding is ASCII lowercasing, and the ASCII members of
/// `CharacterSet.whitespacesAndNewlines` are tab, LF, VT, FF, CR, and space.
@inline(__always)
private func asciiFolded(_ value: String, caseSensitive: Bool) -> [UInt8]? {
    var output: [UInt8] = []
    output.reserveCapacity(value.utf8.count)
    for byte in value.utf8 {
        guard byte < 0x80 else { return nil }
        if byte == 0x20 || (byte >= 0x09 && byte <= 0x0D) { continue }
        if !caseSensitive, byte >= 0x41, byte <= 0x5A {
            output.append(byte | 0x20)
        } else {
            output.append(byte)
        }
    }
    return output
}

private let foldingLocale = Locale(identifier: "en_US_POSIX")

private func foldedScalars(_ value: String, caseSensitive: Bool) -> [UnicodeScalar] {
    var options: String.CompareOptions = [.widthInsensitive]
    if !caseSensitive { options.insert(.caseInsensitive) }
    return value.folding(options: options, locale: foldingLocale)
        .unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
}
