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
        /// Byte forms used by the ASCII fast path. Nil when any configured value is non-ASCII,
        /// because String comparison then depends on Unicode canonical equivalence.
        let asciiRootPrefix: [UInt8]?
        let asciiExcludedPaths: [[UInt8]]
        let asciiSystemFolders: Set<[UInt8]>
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
        // Loading runs off the request path; doing this here keeps the first FSEvents
        // update from building the lookup table while searches wait on the engine lock.
        engine.preparePathIndex()
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
            _ = engine.walkDirectoryParallel(
                configuration.root,
                skipDir: { path in
                    !Self.shouldInclude(path, context: context)
                },
                includeFile: { path in
                    Self.shouldInclude(path, context: context)
                },
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
        if cancelled?() != true { engine.preparePathIndex() }
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
                    _ = engine.walkDirectoryParallel(
                        path,
                        skipDir: { candidate in
                            !Self.shouldInclude(candidate, context: context)
                        },
                        includeFile: { candidate in
                            Self.shouldInclude(candidate, context: context)
                        },
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
        let rootPrefix = configuration.root == "/" ? "/" : configuration.root + "/"
        let rootIsMacOS = configuration.excludeSystemFolders && rootLooksLikeMacOS(configuration.root)
        let allASCII = isASCII(rootPrefix)
            && configuration.excludedPaths.allSatisfy(isASCII)
            && (!rootIsMacOS || configuration.systemFolderNames.allSatisfy(isASCII))
        return InclusionContext(
            configuration: configuration,
            rootPrefix: rootPrefix,
            rootIsMacOS: rootIsMacOS,
            asciiRootPrefix: allASCII ? Array(rootPrefix.utf8) : nil,
            asciiExcludedPaths: allASCII ? configuration.excludedPaths.map { Array($0.utf8) } : [],
            asciiSystemFolders: allASCII ? Set(configuration.systemFolderNames.map { Array($0.utf8) }) : []
        )
    }


    private static func isASCII(_ value: String) -> Bool {
        value.utf8.allSatisfy { $0 < 0x80 }
    }

    private static func shouldInclude(_ path: String, context: InclusionContext) -> Bool {
        if let rootPrefix = context.asciiRootPrefix {
            var copy = path
            if let result = copy.withUTF8({ shouldIncludeASCII($0, rootPrefix: rootPrefix, context: context) }) {
                return result
            }
        }
        return shouldIncludeUnicode(path, context: context)
    }

    /// Byte-level twin of `shouldIncludeUnicode` for all-ASCII paths and settings, where String
    /// equality, prefix, split, and Character counts reduce exactly to byte operations.
    /// Returns nil for non-ASCII paths so the String implementation decides.
    private static func shouldIncludeASCII(
        _ path: UnsafeBufferPointer<UInt8>,
        rootPrefix: [UInt8],
        context: InclusionContext
    ) -> Bool? {
        let count = path.count
        var index = 0
        while index < count {
            if path[index] >= 0x80 { return nil }
            index &+= 1
        }
        let prefixCount = rootPrefix.count
        guard count > prefixCount,
              rootPrefix.withUnsafeBufferPointer({ memcmp(path.baseAddress!, $0.baseAddress!, prefixCount) == 0 })
        else { return false }

        for excluded in context.asciiExcludedPaths {
            let length = excluded.count
            guard count >= length,
                  excluded.withUnsafeBufferPointer({ memcmp(path.baseAddress!, $0.baseAddress!, length) == 0 })
            else { continue }
            if count == length || path[length] == 0x2F { return false }
        }

        let configuration = context.configuration
        var hasSlash = false
        var hiddenSegment = path[prefixCount] == 0x2E
        index = prefixCount
        while index < count {
            if path[index] == 0x2F {
                hasSlash = true
                if index + 1 < count, path[index + 1] == 0x2E { hiddenSegment = true }
            }
            index &+= 1
        }
        if !configuration.includeSubfolders, hasSlash { return false }
        if !configuration.includeHidden, hiddenSegment { return false }

        if context.rootIsMacOS {
            var start = prefixCount
            while start < count, path[start] == 0x2F { start &+= 1 }
            var end = start
            while end < count, path[end] != 0x2F { end &+= 1 }
            if end > start,
               context.asciiSystemFolders.contains(Array(UnsafeBufferPointer(rebasing: path[start ..< end]))) {
                return false
            }
        }
        return true
    }

    private static func shouldIncludeUnicode(_ path: String, context: InclusionContext) -> Bool {
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
