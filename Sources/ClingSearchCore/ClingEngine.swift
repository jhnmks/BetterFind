import Foundation

public struct ClingBuildConfiguration: Equatable, Sendable {
    public let root: String
    public let includeSubfolders: Bool
    public let includeHidden: Bool
    public let excludeSystemFolders: Bool
    public let systemFolderNames: Set<String>
    public let excludedPaths: [String]

    public init(
        root: String,
        includeSubfolders: Bool,
        includeHidden: Bool,
        excludeSystemFolders: Bool,
        systemFolderNames: Set<String>,
        excludedPaths: [String]
    ) {
        self.root = URL(fileURLWithPath: root).standardizedFileURL.path
        self.includeSubfolders = includeSubfolders
        self.includeHidden = includeHidden
        self.excludeSystemFolders = excludeSystemFolders
        self.systemFolderNames = systemFolderNames
        self.excludedPaths = excludedPaths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
    }
}

public struct ClingRankedResult: Sendable {
    public let path: String
    public let isDirectory: Bool
    public let score: Int
    public let quality: Int
    public let rank: Int
}

public final class ClingEngine: @unchecked Sendable {
    private struct InclusionContext {
        let configuration: ClingBuildConfiguration
        let rootPrefix: String
        let rootIsMacOS: Bool
    }

    private let engine: SearchEngine
    private let configurationLock = NSLock()
    private var inclusionContext: InclusionContext?

    public init() {
        engine = SearchEngine()
    }

    public var count: Int {
        engine.count
    }

    public func load(from url: URL, configuration: ClingBuildConfiguration) -> Bool {
        guard engine.loadBinaryIndex(from: url) else { return false }
        let context = Self.makeInclusionContext(configuration)
        configurationLock.withLock { inclusionContext = context }
        return true
    }

    public func save(to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        engine.saveBinaryIndex(to: url)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    @discardableResult
    public func build(
        configuration: ClingBuildConfiguration,
        progress: ((Int, String) -> Void)? = nil,
        cancelled: (() -> Bool)? = nil
    ) -> Int {
        engine.clear()
        engine.reserveCapacity(100_000)
        let context = Self.makeInclusionContext(configuration)
        configurationLock.withLock { inclusionContext = context }

        if configuration.includeSubfolders {
            _ = engine.walkDirectory(
                configuration.root,
                skipDir: { path in
                    !Self.shouldInclude(path, context: context)
                },
                includeFile: { path in
                    Self.shouldInclude(path, context: context)
                },
                applyBlocklist: false,
                discoverGitignore: false,
                skipGitDirectories: !configuration.includeHidden,
                progress: progress,
                cancelled: cancelled
            )
        } else {
            let options: FileManager.DirectoryEnumerationOptions = configuration.includeHidden
                ? []
                : [.skipsHiddenFiles]
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: configuration.root),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: options
            )) ?? []
            for url in urls {
                if cancelled?() == true { break }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                let isDirectory = values?.isDirectory ?? url.hasDirectoryPath
                let path = url.standardizedFileURL.path
                guard Self.shouldInclude(path, context: context) else { continue }
                engine.addPath(path, isDir: isDirectory)
            }
        }
        return engine.count
    }

    public func search(
        query: String,
        maxResults: Int,
        directoriesOnly: Bool,
        literalDefault: Bool
    ) -> [ClingRankedResult] {
        engine.search(
            query: query,
            maxResults: max(1, min(maxResults, 10_000)),
            dirsOnly: directoriesOnly,
            literalDefault: literalDefault,
            parseOperators: false
        ).map {
            ClingRankedResult(
                path: $0.path,
                isDirectory: $0.isDir,
                score: $0.score,
                quality: $0.quality,
                rank: $0.rank
            )
        }
    }

    @discardableResult
    public func applyFilesystemChange(path rawPath: String) -> Bool {
        guard let context = configurationLock.withLock({ inclusionContext }) else { return false }
        let configuration = context.configuration
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        guard Self.isInsideRoot(path, root: configuration.root) else { return false }
        let countBefore = engine.count

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            guard Self.shouldInclude(path, context: context) else {
                _ = engine.removePathAndDescendants(path)
                return engine.count != countBefore
            }

            if isDirectory.boolValue {
                engine.addPath(path, isDir: true)
                if configuration.includeSubfolders {
                    _ = engine.walkDirectory(
                        path,
                        skipDir: { candidate in
                            !Self.shouldInclude(candidate, context: context)
                        },
                        includeFile: { candidate in
                            Self.shouldInclude(candidate, context: context)
                        },
                        applyBlocklist: false,
                        discoverGitignore: false,
                        skipGitDirectories: !configuration.includeHidden
                    )
                }
            } else {
                engine.addPath(path, isDir: false)
            }
        } else {
            _ = engine.removePathAndDescendants(path)
        }
        return engine.count != countBefore
    }

    private static func makeInclusionContext(_ configuration: ClingBuildConfiguration) -> InclusionContext {
        InclusionContext(
            configuration: configuration,
            rootPrefix: configuration.root == "/" ? "/" : configuration.root + "/",
            rootIsMacOS: configuration.excludeSystemFolders && rootLooksLikeMacOS(configuration.root)
        )
    }

    private static func shouldInclude(_ path: String, context: InclusionContext) -> Bool {
        let configuration = context.configuration
        guard path.hasPrefix(context.rootPrefix), path.count > context.rootPrefix.count else { return false }

        if configuration.excludedPaths.contains(where: {
            path == $0 || path.hasPrefix($0 + "/")
        }) {
            return false
        }

        let relative = path.dropFirst(context.rootPrefix.count)
        if !configuration.includeSubfolders, relative.contains("/") {
            return false
        }
        if !configuration.includeHidden,
           relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
            return false
        }

        if context.rootIsMacOS,
           let first = relative.split(separator: "/", maxSplits: 1).first,
           configuration.systemFolderNames.contains(String(first)) {
            return false
        }
        return true
    }

    private static func isInsideRoot(_ path: String, root: String) -> Bool {
        if root == "/" { return path.hasPrefix("/") && path != "/" }
        return path.hasPrefix(root + "/")
    }


    private static func rootLooksLikeMacOS(_ root: String) -> Bool {
        ["System", "Users", "Library"].allSatisfy { name in
            var isDirectory: ObjCBool = false
            let path = URL(fileURLWithPath: root).appendingPathComponent(name).path
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }
}
