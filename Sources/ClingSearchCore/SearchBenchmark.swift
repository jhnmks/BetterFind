import Foundation

public struct SearchBenchmarkQuery: Sendable {
    public let query: String
    public let literalDefault: Bool
    public let parseOperators: Bool

    public init(
        _ query: String,
        literalDefault: Bool = false,
        parseOperators: Bool = false
    ) {
        self.query = query
        self.literalDefault = literalDefault
        self.parseOperators = parseOperators
    }
}

public struct SearchBenchmarkRow: Sendable {
    public let query: String
    public let limit: Int
    public let exhaustiveMilliseconds: Double
    public let boundedMilliseconds: Double
    public let resultCount: Int

    public var speedup: Double {
        exhaustiveMilliseconds / max(boundedMilliseconds, 0.001)
    }
}

public struct SearchBenchmarkReport: Sendable {
    public let entryCount: Int
    public let corpusSeed: UInt64
    public let queryCount: Int
    public let rows: [SearchBenchmarkRow]
}

public struct ByteSearchBenchmarkReport: Sendable {
    public let iterations: Int
    public let legacyMilliseconds: Double
    public let optimizedMilliseconds: Double
    public let checksum: Int

    public var speedup: Double {
        legacyMilliseconds / max(optimizedMilliseconds, 0.001)
    }
}

public enum SearchBenchmarkError: Error, CustomStringConvertible {
    case mismatch(seed: UInt64, query: String, limit: Int, details: String)
    case lifecycle(String)

    public var description: String {
        switch self {
        case .mismatch(let seed, let query, let limit, let details):
            return "Bounded scoring changed ordered results for seed \(seed), query \"\(query)\", limit \(limit).\n\(details)"
        case .lifecycle(let details):
            return "Path-metadata lifecycle validation failed: \(details)"
        }
    }
}

public enum SearchBenchmark {
    public static func run(
        entryCount: Int = 30_000,
        queries: [SearchBenchmarkQuery] = defaultQueries,
        stressQueryCount: Int = 0,
        corpusSeed: UInt64 = 0xB377_EF1D_CAFE_F00D,
        limits: [Int] = [10, 100, 1_000]
    ) throws -> SearchBenchmarkReport {
        let engine = makeEngine(entryCount: entryCount, seed: corpusSeed)
        let allQueries = queries + stressQueries(count: stressQueryCount, seed: corpusSeed ^ 0x51A7_5EED_D1FF_1234)
        var rows: [SearchBenchmarkRow] = []
        rows.reserveCapacity(allQueries.count * limits.count)

        for queryCase in allQueries {
            for limit in limits {
                let exhaustive = timedSearch(
                    engine: engine,
                    query: queryCase.query,
                    limit: limit,
                    literalDefault: queryCase.literalDefault,
                    parseOperators: queryCase.parseOperators,
                    exhaustiveScoring: true
                )
                let bounded = timedSearch(
                    engine: engine,
                    query: queryCase.query,
                    limit: limit,
                    literalDefault: queryCase.literalDefault,
                    parseOperators: queryCase.parseOperators,
                    exhaustiveScoring: false
                )

                let exhaustiveSnapshots = exhaustive.results.map(Snapshot.init)
                let boundedSnapshots = bounded.results.map(Snapshot.init)
                guard exhaustiveSnapshots == boundedSnapshots else {
                    throw SearchBenchmarkError.mismatch(
                        seed: corpusSeed,
                        query: queryCase.query,
                        limit: limit,
                        details: mismatchDescription(
                            exhaustive: exhaustiveSnapshots,
                            bounded: boundedSnapshots
                        )
                    )
                }
                rows.append(SearchBenchmarkRow(
                    query: queryCase.query,
                    limit: limit,
                    exhaustiveMilliseconds: exhaustive.milliseconds,
                    boundedMilliseconds: bounded.milliseconds,
                    resultCount: bounded.results.count
                ))
            }
        }
        return SearchBenchmarkReport(
            entryCount: entryCount,
            corpusSeed: corpusSeed,
            queryCount: allQueries.count,
            rows: rows
        )
    }

    public static func validatePathMetadataLifecycle() throws -> Int {
        let engine = SearchEngine()
        let home = NSHomeDirectory()
        let paths: [(String, Bool)] = [
            (home + "/Documents/SearchEngine.swift", false),
            (home + "/Library/VisibleNotes.md", false),
            (home + "/.config/better-find/settings.yaml", false),
            (home + "/Downloads/.hidden-result.json", false),
            ("/Applications/Better Find.app", true),
            ("/System/Library/Frameworks/SearchKit.framework", true),
        ]
        for (path, isDirectory) in paths {
            engine.addPath(path, isDir: isDirectory)
        }

        let queries = ["search", ".swift", ".hidden", "settings", "engine$"]
        var comparisons = try compareCachedPathMetadata(engine: engine, queries: queries)
        let swiftPool = engine.prefilter(extensions: ".swift", dirsOnly: false)
        comparisons += try compareCachedPathMetadata(
            engine: engine,
            queries: ["search .swift"],
            candidatePool: swiftPool
        )
        engine.buildSortedPathIndex()
        comparisons += try compareCachedPathMetadata(
            engine: engine,
            queries: ["search .swift"],
            folderPrefixes: [home + "/Documents"]
        )

        let indexURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("better-find-metadata-\(UUID().uuidString).index")
        defer { try? FileManager.default.removeItem(at: indexURL) }
        engine.saveBinaryIndex(to: indexURL)

        let loaded = SearchEngine()
        guard loaded.loadBinaryIndex(from: indexURL) else {
            throw SearchBenchmarkError.lifecycle("failed to reload binary index")
        }
        comparisons += try compareCachedPathMetadata(engine: loaded, queries: queries)

        guard loaded.removePath(home + "/Documents/SearchEngine.swift") else {
            throw SearchBenchmarkError.lifecycle("failed to remove lifecycle test path")
        }
        loaded.addPath(home + "/Documents/ReusedSearchEngine.swift", isDir: false)
        comparisons += try compareCachedPathMetadata(engine: loaded, queries: queries)
        return comparisons
    }

    public static func runByteSearch(iterations: Int = 5_000_000) -> ByteSearchBenchmarkReport {
        var bytes = Array(repeating: UInt8(ascii: "a"), count: 256)
        bytes[31] = UInt8(ascii: "s")
        bytes[95] = UInt8(ascii: "e")
        bytes[191] = UInt8(ascii: "x")
        let needles: [UInt8] = [UInt8(ascii: "s"), UInt8(ascii: "e"), UInt8(ascii: "x"), UInt8(ascii: "z")]

        func measure(_ finder: (UnsafePointer<UInt8>, Int, UInt8, Int) -> Int) -> (Double, Int) {
            var checksum = 0
            let start = ContinuousClock.now
            bytes.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                var index = 0
                while index < iterations {
                    let from = index & 15
                    checksum &+= finder(base, buffer.count, needles[index & 3], from)
                    index &+= 1
                }
            }
            let components = start.duration(to: .now).components
            return (
                Double(components.seconds) * 1_000
                    + Double(components.attoseconds) / 1_000_000_000_000_000,
                checksum
            )
        }

        let legacy = measure(legacySIMDFindByte)
        let optimized = measure(simdFindByte)
        precondition(legacy.1 == optimized.1, "byte-search implementations disagree")
        return ByteSearchBenchmarkReport(
            iterations: iterations,
            legacyMilliseconds: legacy.0,
            optimizedMilliseconds: optimized.0,
            checksum: optimized.1
        )
    }

    public static let defaultQueries = [
        SearchBenchmarkQuery("a"),
        SearchBenchmarkQuery("se"),
        SearchBenchmarkQuery("src"),
        SearchBenchmarkQuery("search"),
        SearchBenchmarkQuery("sr eng"),
        SearchBenchmarkQuery("mask local"),
        SearchBenchmarkQuery("docs/read"),
        SearchBenchmarkQuery("cafe"),
        SearchBenchmarkQuery("café"),
        SearchBenchmarkQuery("東京"),
        SearchBenchmarkQuery("한글"),
        SearchBenchmarkQuery("makefile"),
        SearchBenchmarkQuery(".swift", parseOperators: true),
        SearchBenchmarkQuery(".json .yaml", parseOperators: true),
        SearchBenchmarkQuery("search .swift", parseOperators: true),
        SearchBenchmarkQuery("settings .yaml .json", parseOperators: true),
        SearchBenchmarkQuery("'search", parseOperators: true),
        SearchBenchmarkQuery("^search", parseOperators: true),
        SearchBenchmarkQuery("engine$", parseOperators: true),
        SearchBenchmarkQuery("search !archive", parseOperators: true),
        SearchBenchmarkQuery(".swift !search", parseOperators: true),
        SearchBenchmarkQuery("search !/", parseOperators: true),
        SearchBenchmarkQuery("read me", literalDefault: true),
        SearchBenchmarkQuery("this-query-should-not-match-anything")
    ]

    private struct Snapshot: Equatable, CustomStringConvertible {
        let path: String
        let isDirectory: Bool
        let score: Int
        let quality: Int
        let rank: Int
        let hasBase: Bool
        let segmentMatches: Int
        let pathImportance: Int
        let prefixMatch: Bool
        let depth: Int

        init(_ result: SearchResult) {
            path = result.path
            isDirectory = result.isDir
            score = result.score
            quality = result.quality
            rank = result.rank
            hasBase = result.hasBase
            segmentMatches = result.segmentMatches
            pathImportance = result.pathImportance
            prefixMatch = result.prefixMatch
            depth = result.depth
        }

        var description: String {
            "\(path) [rank=\(rank), score=\(score), quality=\(quality), base=\(hasBase), segments=\(segmentMatches), importance=\(pathImportance), prefix=\(prefixMatch), depth=\(depth)]"
        }
    }

    @inline(never) private static func legacySIMDFindByte(
        _ base: UnsafePointer<UInt8>,
        _ count: Int,
        _ needle: UInt8,
        _ from: Int
    ) -> Int {
        let needleVector = SIMD16<UInt8>(repeating: needle)
        var index = from
        while index &+ 16 <= count {
            let block = UnsafeRawPointer(base + index).loadUnaligned(as: SIMD16<UInt8>.self)
            let comparison = block .== needleVector
            var lane = 0
            while lane < 16 {
                if comparison[lane] { return index &+ lane }
                lane &+= 1
            }
            index &+= 16
        }
        while index < count {
            if base[index] == needle { return index }
            index &+= 1
        }
        return -1
    }

    private static func compareCachedPathMetadata(
        engine: SearchEngine,
        queries: [String],
        candidatePool: [Int]? = nil,
        folderPrefixes: [String]? = nil
    ) throws -> Int {
        var comparisons = 0
        for query in queries {
            let parseOperators = query.hasPrefix(".") || query.hasSuffix("$")
            let exhaustive = engine.search(
                query: query,
                maxResults: 100,
                folderPrefixes: folderPrefixes,
                candidatePool: candidatePool,
                parseOperators: parseOperators,
                exhaustiveScoring: true
            ).map(Snapshot.init)
            let cached = engine.search(
                query: query,
                maxResults: 100,
                folderPrefixes: folderPrefixes,
                candidatePool: candidatePool,
                parseOperators: parseOperators,
                exhaustiveScoring: false
            ).map(Snapshot.init)
            guard exhaustive == cached else {
                throw SearchBenchmarkError.lifecycle(
                    "query \"\(query)\" changed after cached importance lookup\n"
                        + mismatchDescription(exhaustive: exhaustive, bounded: cached)
                )
            }
            comparisons &+= 1
        }
        return comparisons
    }

    private static func timedSearch(
        engine: SearchEngine,
        query: String,
        limit: Int,
        literalDefault: Bool,
        parseOperators: Bool,
        exhaustiveScoring: Bool
    ) -> (results: [SearchResult], milliseconds: Double) {
        let start = ContinuousClock.now
        let results = engine.search(
            query: query,
            maxResults: limit,
            literalDefault: literalDefault,
            parseOperators: parseOperators,
            exhaustiveScoring: exhaustiveScoring
        )
        let duration = start.duration(to: .now)
        let components = duration.components
        let milliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return (results, milliseconds)
    }

    private static func stressQueries(count: Int, seed: UInt64) -> [SearchBenchmarkQuery] {
        guard count > 0 else { return [] }
        let terms = [
            "search", "engine", "source", "reader", "mask", "local", "settings", "controller",
            "index", "manager", "document", "store", "result", "collector", "filesystem", "watcher",
            "query", "matcher", "performance", "accuracy", "cache", "metadata", "swift", "package",
            "release", "notes", "betterfind", "unicode", "archive", "café", "東京", "한글"
        ]
        let roots = ["documents", "downloads", "developer", "pictures", "music", "movies"]
        var generator = SplitMix64(seed: seed)
        var queries: [SearchBenchmarkQuery] = []
        queries.reserveCapacity(count)

        for index in 0 ..< count {
            let first = terms[Int(generator.next() % UInt64(terms.count))]
            let second = terms[Int(generator.next() % UInt64(terms.count))]
            let query: String
            let parseOperators: Bool
            switch index % 12 {
            case 0:
                query = String(first.prefix(1 + Int(generator.next() % UInt64(max(first.count, 1)))))
                parseOperators = false
            case 1:
                query = String(first.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil })
                parseOperators = false
            case 2:
                query = "\(first) \(second)"
                parseOperators = false
            case 3:
                query = "\(roots[Int(generator.next() % UInt64(roots.count))])/\(first)"
                parseOperators = false
            case 4:
                query = "\(String(first.prefix(2))) \(String(second.prefix(3)))"
                parseOperators = false
            case 5:
                query = first + String(format: "%02d", Int(generator.next() % 100))
                parseOperators = false
            case 6:
                query = ["cafe", "café", "東京", "한글"][Int(generator.next() % 4)]
                parseOperators = false
            case 7:
                query = "'\(first)"
                parseOperators = true
            case 8:
                query = "^\(first)"
                parseOperators = true
            case 9:
                query = "\(first) !\(second)"
                parseOperators = true
            case 10:
                query = ".\(["swift", "json", "yaml", "md"][Int(generator.next() % 4)]) !\(second)"
                parseOperators = true
            default:
                query = "missing-\(generator.next())"
                parseOperators = false
            }
            queries.append(SearchBenchmarkQuery(
                query,
                literalDefault: !parseOperators && index % 17 == 0 && !query.contains("/"),
                parseOperators: parseOperators
            ))
        }
        return queries
    }

    private static func makeEngine(entryCount: Int, seed: UInt64) -> SearchEngine {
        let engine = SearchEngine()
        engine.reserveCapacity(entryCount + 64, avgPathLen: 100)

        let curated: [(String, Bool)] = [
            ("/Users/test/Documents/README.md", false),
            ("/Users/test/Documents/read-me-final.txt", false),
            ("/Users/test/Documents/SearchEngine.swift", false),
            ("/Users/test/Developer/BetterFind/Sources/ClingSearchCore/SearchEngine.swift", false),
            ("/Users/test/Developer/BetterFind/Sources/BetterFindBackend/BackendManager.swift", false),
            ("/Users/test/Developer/MaskForLocal/MaskForLocalController.swift", false),
            ("/Users/test/Developer/src/search/engine/index.swift", false),
            ("/Users/test/Developer/src", true),
            ("/Users/test/Library/Application Support/BetterFind/index.bin", false),
            ("/Users/test/.config/better-find/settings.yaml", false),
            ("/Users/test/Documents/café-notes.txt", false),
            ("/Users/test/Documents/cafe-notes.txt", false),
            ("/Users/test/Documents/cafe\u{301}-decomposed.txt", false),
            ("/Users/test/Documents/東京旅行.md", false),
            ("/Users/test/Documents/한글문서.md", false),
            ("/Users/test/Developer/Makefile", false),
            ("/Users/test/Developer/README", false),
            ("/Users/test/Movies/search-demo.mov", false),
            ("/System/Library/Frameworks/SearchKit.framework", true),
            ("/private/var/tmp/search-index.cache", false)
        ]
        for (path, isDirectory) in curated {
            engine.addPath(path, isDir: isDirectory)
        }

        let roots = ["Documents", "Downloads", "Developer", "Pictures", "Music", "Movies"]
        let projects = ["BetterFind", "SearchKit", "LocalMask", "IndexBench", "UnicodeLab", "ArchiveTool"]
        let stems = [
            "search-engine", "source-reader", "mask-for-local", "read-me", "settings-controller",
            "index-manager", "document-store", "result-collector", "filesystem-watcher", "query-matcher",
            "performance-report", "accuracy-suite", "cache-metadata", "swift-package", "release-notes"
        ]
        let extensions = ["swift", "md", "txt", "json", "yaml", "plist", "png", "jpg", "mov", "pdf"]

        var generator = SplitMix64(seed: seed)
        for index in 0 ..< entryCount {
            let root = roots[Int(generator.next() % UInt64(roots.count))]
            let project = projects[Int(generator.next() % UInt64(projects.count))]
            let stem = stems[Int(generator.next() % UInt64(stems.count))]
            let ext = extensions[Int(generator.next() % UInt64(extensions.count))]
            let group = Int(generator.next() % 256)
            let depth = Int(generator.next() % 4)
            var components = ["Users", "test", root, project]
            for level in 0 ..< depth {
                components.append("group-\(group)-\(level)")
            }
            let suffix: String
            switch index % 997 {
            case 0: suffix = "café-東京-한글"
            case 1: suffix = "MaskForLocal"
            case 2: suffix = "SearchEngine"
            default: suffix = "\(stem)-\(String(format: "%05d", index))"
            }
            components.append("\(suffix).\(ext)")
            engine.addPath("/" + components.joined(separator: "/"), isDir: false)
        }
        return engine
    }

    private static func mismatchDescription(
        exhaustive: [Snapshot],
        bounded: [Snapshot]
    ) -> String {
        let sharedCount = min(exhaustive.count, bounded.count)
        let mismatchIndex = (0 ..< sharedCount).first { exhaustive[$0] != bounded[$0] }
            ?? sharedCount
        let lowerBound = max(0, mismatchIndex - 3)
        let upperBound = min(max(exhaustive.count, bounded.count), mismatchIndex + 4)
        var lines = [
            "First mismatch index: \(mismatchIndex)",
            "Exhaustive count: \(exhaustive.count); bounded count: \(bounded.count)"
        ]
        for index in lowerBound ..< upperBound {
            let exhaustiveValue = index < exhaustive.count ? exhaustive[index].description : "<missing>"
            let boundedValue = index < bounded.count ? bounded[index].description : "<missing>"
            lines.append("[\(index)] exhaustive: \(exhaustiveValue)")
            lines.append("[\(index)] bounded:    \(boundedValue)")
        }
        return lines.joined(separator: "\n")
    }
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
