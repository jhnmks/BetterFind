import Foundation
import BetterFindIPC

private struct SearchResult {
    let name: String
    let path: String
    let isDirectory: Bool
    let relevance: Int
    let nameLength: Int
    let depth: Int
    let typeSortKey: String
}

private struct AlfredIcon: Encodable {
    let type = "fileicon"
    let path: String
}

private struct AlfredModifier: Encodable {
    let valid: Bool
    let arg: String?
    let subtitle: String
}

private struct AlfredModifiers: Encodable {
    let ctrl: AlfredModifier
}

private struct AlfredItem: Encodable {
    let uid: String
    let title: String
    let subtitle: String
    let arg: String
    let type = "file"
    let icon: AlfredIcon
    let mods: AlfredModifiers
}

private struct AlfredOutput: Encodable {
    let items: [AlfredItem]
}

private struct AlfredStatusItem: Encodable {
    let title: String
    let subtitle: String
    let valid = false
}

private struct AlfredStatusOutput: Encodable {
    let items: [AlfredStatusItem]
    let rerun: Double
}

private struct AlfredPromptOutput: Encodable {
    let items: [AlfredStatusItem]
}

private enum WorkflowAdapterError: Error, CustomStringConvertible {
    case invalid(String)
    case backend(String)

    var description: String {
        switch self {
        case .invalid(let message), .backend(let message): return message
        }
    }
}

private struct WorkflowOptions {
    var query = ""
    var root: String
    var includeSubfolders: Bool
    var includeHidden: Bool
    var caseSensitive: Bool
    var excludeSystemFolders: Bool
    var systemFolders: Set<String>
    var excludedPaths: [String]
    var limit: Int?
    var sortBy: ConfiguredSortBy
    var sortOrder: ConfiguredSortOrder
    var indexPath: String?

    init(defaults: WorkflowConfiguration) {
        root = defaults.root
        includeSubfolders = defaults.includeSubfolders
        includeHidden = defaults.includeHiddenFiles
        caseSensitive = defaults.caseSensitive
        excludeSystemFolders = defaults.excludeSystemFolders
        systemFolders = defaults.systemFolders
        excludedPaths = defaults.excludedPaths
        limit = defaults.limit
        sortBy = defaults.sortBy
        sortOrder = defaults.sortOrder
    }
}

private func parseWorkflowOptions(_ arguments: [String]) throws -> WorkflowOptions {
    var options = WorkflowOptions(defaults: WorkflowConfiguration())
    var queryParts: [String] = []
    var index = 0

    func nextValue(after option: String) throws -> String {
        index += 1
        guard index < arguments.count else {
            throw WorkflowAdapterError.invalid("Missing value after \(option)")
        }
        return arguments[index]
    }

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--root":
            options.root = try nextValue(after: argument)
        case "--include-subfolders":
            options.includeSubfolders = true
        case "--no-subfolders":
            options.includeSubfolders = false
        case "--include-hidden":
            options.includeHidden = true
        case "--exclude-hidden":
            options.includeHidden = false
        case "--case-sensitive":
            options.caseSensitive = true
        case "--case-insensitive":
            options.caseSensitive = false
        case "--exclude-system":
            options.excludeSystemFolders = true
        case "--include-system":
            options.excludeSystemFolders = false
        case "--system-folders-yaml":
            options.systemFolders = Set(try WorkflowConfigurationParser.parseStringSequenceYAML(
                try nextValue(after: argument),
                setting: "system folder setting"
            ))
        case "--excluded-paths-yaml":
            options.excludedPaths = try WorkflowConfigurationParser.parseStringSequenceYAML(
                try nextValue(after: argument),
                setting: "excluded path setting"
            )
        case "--limit":
            let value = try nextValue(after: argument)
            guard let limit = Int(value), limit >= 0 else {
                throw WorkflowAdapterError.invalid("Alfred result limit must be a nonnegative integer")
            }
            options.limit = limit == 0 ? nil : limit
        case "--sort-by":
            let value = try nextValue(after: argument)
            guard let sortBy = ConfiguredSortBy(rawValue: value) else {
                throw WorkflowAdapterError.invalid("Invalid Alfred sort field: \(value)")
            }
            options.sortBy = sortBy
        case "--sort-order":
            let value = try nextValue(after: argument)
            guard let sortOrder = ConfiguredSortOrder(rawValue: value) else {
                throw WorkflowAdapterError.invalid("Invalid Alfred sort order: \(value)")
            }
            options.sortOrder = sortOrder
        case "--index-path":
            options.indexPath = try nextValue(after: argument)
        case "--":
            queryParts.append(contentsOf: arguments.dropFirst(index + 1))
            index = arguments.count
            continue
        default:
            throw WorkflowAdapterError.invalid("Unknown Alfred adapter option: \(argument)")
        }
        index += 1
    }

    guard !queryParts.isEmpty else {
        throw WorkflowAdapterError.invalid("Missing Alfred query")
    }
    guard options.indexPath != nil else {
        throw WorkflowAdapterError.invalid("Missing Alfred workflow index path")
    }
    options.query = queryParts.joined(separator: " ")
    return options
}

private func exclusionsIncludingIndexStorage(_ paths: [String], indexURL: URL) -> [String] {
    let generatedFiles = [
        indexURL.path,
        indexURL.path + ".json",
        indexURL.path + ".json.tmp",
        indexURL.deletingLastPathComponent().appendingPathComponent("better-find-backend.log").path
    ]
    return Array(Set(paths.map(standardizePath) + generatedFiles)).sorted()
}

private func makeBackendConfiguration(
    options: WorkflowOptions,
    rootPath: String,
    indexURL: URL
) -> BackendIndexConfiguration {
    BackendIndexConfiguration(
        root: rootPath,
        includeSubfolders: options.includeSubfolders,
        includeHidden: options.includeHidden,
        excludeSystemFolders: options.excludeSystemFolders,
        systemFolderNames: options.systemFolders.sorted(),
        excludedPaths: exclusionsIncludingIndexStorage(options.excludedPaths, indexURL: indexURL)
    )
}

private struct ResultEvaluator {
    let matcher: PreparedNameMatcher
    let scope: QueryScope

    init(query: ParsedSearchQuery, caseSensitive: Bool) {
        matcher = PreparedNameMatcher(
            mode: query.mode,
            query: query.text,
            caseSensitive: caseSensitive
        )
        scope = query.scope
    }

    func result(for entry: BackendSearchResult) -> SearchResult? {
        let url = URL(fileURLWithPath: entry.path)
        let name = url.lastPathComponent
        guard matcher.matches(name) else { return nil }

        switch scope {
        case .filesAndFolders:
            break
        case .filesOnly where entry.isDirectory:
            return nil
        case .foldersOnly where !entry.isDirectory:
            return nil
        default:
            break
        }

        return SearchResult(
            name: name,
            path: entry.path,
            isDirectory: entry.isDirectory,
            relevance: entry.rank,
            nameLength: name.count,
            depth: entry.path.reduce(into: 0) { if $1 == "/" { $0 += 1 } },
            typeSortKey: entry.isDirectory ? "folder" : url.pathExtension
        )
    }
}

private func resultComesBefore(
    _ left: SearchResult,
    _ right: SearchResult,
    by field: ConfiguredSortBy,
    order: ConfiguredSortOrder
) -> Bool {
    if field == .relevance {
        if left.relevance != right.relevance {
            return order == .ascending
                ? left.relevance < right.relevance
                : left.relevance > right.relevance
        }
        if left.nameLength != right.nameLength { return left.nameLength < right.nameLength }
        if left.depth != right.depth { return left.depth < right.depth }
        let nameComparison = left.name.localizedCaseInsensitiveCompare(right.name)
        if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
        return left.path.localizedCaseInsensitiveCompare(right.path) == .orderedAscending
    }

    let comparison: ComparisonResult
    switch field {
    case .relevance:
        comparison = .orderedSame
    case .name:
        comparison = left.name.localizedCaseInsensitiveCompare(right.name)
    case .type:
        comparison = left.typeSortKey.localizedCaseInsensitiveCompare(right.typeSortKey)
    case .path:
        comparison = left.path.localizedCaseInsensitiveCompare(right.path)
    }
    if comparison == .orderedSame {
        return left.path.localizedCaseInsensitiveCompare(right.path) == .orderedAscending
    }
    return order == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending
}

private struct BoundedResultCollector {
    let limit: Int?
    let sortBy: ConfiguredSortBy
    let sortOrder: ConfiguredSortOrder
    private(set) var results: [SearchResult] = []

    mutating func insert(_ result: SearchResult) {
        guard let limit else {
            results.append(result)
            return
        }
        guard limit > 0 else { return }

        if results.count < limit {
            results.append(result)
            siftUp(from: results.count - 1)
        } else if resultComesBefore(result, results[0], by: sortBy, order: sortOrder) {
            results[0] = result
            siftDown(from: 0)
        }
    }

    private func isWorse(_ left: SearchResult, than right: SearchResult) -> Bool {
        resultComesBefore(right, left, by: sortBy, order: sortOrder)
    }

    private mutating func siftUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard isWorse(results[child], than: results[parent]) else { return }
            results.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from index: Int) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            guard left < results.count else { return }
            let right = left + 1
            var worseChild = left
            if right < results.count, isWorse(results[right], than: results[left]) {
                worseChild = right
            }
            guard isWorse(results[worseChild], than: results[parent]) else { return }
            results.swapAt(parent, worseChild)
            parent = worseChild
        }
    }
}

private func printAlfred(_ results: [SearchResult]) throws {
    let items = results.map { result in
        AlfredItem(
            uid: result.path,
            title: result.name,
            subtitle: result.path,
            arg: result.path,
            icon: AlfredIcon(path: result.path),
            mods: AlfredModifiers(ctrl: AlfredModifier(
                valid: result.isDirectory,
                arg: result.isDirectory ? result.path : nil,
                subtitle: result.isDirectory
                    ? "Open this folder in Terminal"
                    : "Terminal action is available for folders only"
            ))
        )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let data = try encoder.encode(AlfredOutput(items: items))
    print(String(decoding: data, as: UTF8.self))
}

private func printAlfredPrompt(title: String, subtitle: String) throws {
    let data = try JSONEncoder().encode(AlfredPromptOutput(
        items: [AlfredStatusItem(title: title, subtitle: subtitle)]
    ))
    print(String(decoding: data, as: UTF8.self))
}

private func printAlfredIndexStatus(_ response: BackendResponse) throws {
    let title: String
    let defaultSubtitle: String
    let rerun: Double
    switch response.indexPhase {
    case .loading:
        title = "Loading Better Find index…"
        defaultSubtitle = "Reading the saved binary index"
        rerun = 0.25
    case .building:
        title = "Building Better Find index…"
        defaultSubtitle = "Creating the first index for this search root"
        rerun = 0.5
    case .rebuilding:
        title = "Rebuilding Better Find index…"
        defaultSubtitle = "Index settings changed; creating a compatible replacement"
        rerun = 0.5
    case .recovering:
        title = "Recovering Better Find index…"
        defaultSubtitle = "Repairing the index after an incomplete snapshot or event stream"
        rerun = 0.5
    case nil:
        title = "Preparing Better Find index…"
        defaultSubtitle = response.message ?? "Results will appear automatically when the index is ready"
        rerun = 0.5
    }

    var details: [String] = []
    if response.indexCount > 0 {
        details.append("\(response.indexCount.formatted()) items indexed")
    }
    if let path = response.indexProgressPath, !path.isEmpty {
        details.append(NSString(string: path).abbreviatingWithTildeInPath)
    }
    let subtitle = details.isEmpty ? defaultSubtitle : details.joined(separator: " — ")
    let output = AlfredStatusOutput(
        items: [AlfredStatusItem(title: title, subtitle: subtitle)],
        rerun: rerun
    )
    let data = try JSONEncoder().encode(output)
    print(String(decoding: data, as: UTF8.self))
}

do {
    let options = try parseWorkflowOptions(Array(CommandLine.arguments.dropFirst()))
    let rootPath = try validateDirectoryPath(options.root)
    let indexURL = URL(fileURLWithPath: standardizePath(options.indexPath!))
    let backendConfiguration = makeBackendConfiguration(
        options: options,
        rootPath: rootPath,
        indexURL: indexURL
    )

    let parsedQuery = ParsedSearchQuery(options.query)
    if parsedQuery.text.isEmpty {
        try printAlfredPrompt(
            title: parsedQuery.promptTitle,
            subtitle: "Normal search is smart; prefix with ', /, \\, '/, or '\\ to refine it"
        )
        exit(0)
    }

    let requiresCompleteCandidateWindow = options.sortBy != .relevance
        || options.caseSensitive
        || parsedQuery.mode == .contains
        || parsedQuery.scope == .filesOnly
    let candidateLimit: Int
    if let limit = options.limit, !requiresCompleteCandidateWindow {
        candidateLimit = min(10_000, max(limit, min(limit, 2_000) * 5))
    } else {
        candidateLimit = 10_000
    }

    let response = try BackendClient(indexURL: indexURL).send(BackendRequest(
        command: .search,
        configuration: backendConfiguration,
        query: parsedQuery.text,
        maxResults: candidateLimit,
        directoriesOnly: parsedQuery.scope == .foldersOnly,
        literalDefault: parsedQuery.mode == .contains
    ))

    switch response.state {
    case .indexing, .empty:
        try printAlfredIndexStatus(response)
        exit(0)
    case .error:
        throw WorkflowAdapterError.backend(
            response.message ?? "Better Find backend could not search the index"
        )
    case .stopping:
        throw WorkflowAdapterError.backend("Better Find backend is restarting")
    case .ready:
        break
    }

    let evaluator = ResultEvaluator(query: parsedQuery, caseSensitive: options.caseSensitive)
    var collector = BoundedResultCollector(
        limit: options.limit,
        sortBy: options.sortBy,
        sortOrder: options.sortOrder
    )
    for entry in response.results {
        if let result = evaluator.result(for: entry) {
            collector.insert(result)
        }
    }

    var results = collector.results.sorted {
        resultComesBefore($0, $1, by: options.sortBy, order: options.sortOrder)
    }
    if let limit = options.limit {
        results = Array(results.prefix(limit))
    }
    try printAlfred(results)
} catch {
    FileHandle.standardError.write(Data("better-find workflow adapter: \(error)\n".utf8))
    exit(1)
}
