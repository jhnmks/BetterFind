import Foundation

enum QueryMatchMode {
    case smart
    case contains
}

enum QueryScope {
    case filesAndFolders
    case filesOnly
    case foldersOnly
}

struct ParsedSearchQuery {
    let mode: QueryMatchMode
    let scope: QueryScope
    let text: String

    init(_ rawQuery: String) {
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

    var promptTitle: String {
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

struct PreparedNameMatcher {
    let mode: QueryMatchMode
    let caseSensitive: Bool
    let normalizedNeedle: String
    let foldedQuery: [UnicodeScalar]

    init(mode: QueryMatchMode, query: String, caseSensitive: Bool) {
        self.mode = mode
        self.caseSensitive = caseSensitive
        normalizedNeedle = normalized(query, caseSensitive: caseSensitive)
        foldedQuery = foldedScalars(query, caseSensitive: caseSensitive)
    }

    func matches(_ name: String) -> Bool {
        switch mode {
        case .contains:
            return !normalizedNeedle.isEmpty
                && normalized(name, caseSensitive: caseSensitive).contains(normalizedNeedle)
        case .smart:
            guard !foldedQuery.isEmpty else { return false }
            var queryIndex = 0
            for scalar in foldedScalars(name, caseSensitive: caseSensitive) where queryIndex < foldedQuery.count {
                if scalar == foldedQuery[queryIndex] { queryIndex += 1 }
            }
            return queryIndex == foldedQuery.count
        }
    }
}

private func normalized(_ value: String, caseSensitive: Bool) -> String {
    caseSensitive ? value : value.lowercased()
}

private func foldedScalars(_ value: String, caseSensitive: Bool) -> [UnicodeScalar] {
    var options: String.CompareOptions = [.widthInsensitive]
    if !caseSensitive { options.insert(.caseInsensitive) }
    return value.folding(options: options, locale: Locale(identifier: "en_US_POSIX"))
        .unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
}
