import ClingSearchCore
import Foundation

func positiveInteger(at index: Int, default defaultValue: Int) -> Int {
    guard CommandLine.arguments.count > index else { return defaultValue }
    guard let value = Int(CommandLine.arguments[index]), value >= 0 else {
        FileHandle.standardError.write(Data("usage: better-find-benchmark [positive-entry-count] [nonnegative-stress-query-count] [corpus-seed]\n".utf8))
        exit(2)
    }
    return value
}

let entryCount = positiveInteger(at: 1, default: 30_000)
let stressQueryCount = positiveInteger(at: 2, default: 0)
let corpusSeed: UInt64
if CommandLine.arguments.count > 3 {
    guard let value = UInt64(CommandLine.arguments[3]) else {
        FileHandle.standardError.write(Data("usage: better-find-benchmark [positive-entry-count] [nonnegative-stress-query-count] [corpus-seed]\n".utf8))
        exit(2)
    }
    corpusSeed = value
} else {
    corpusSeed = 0xB377_EF1D_CAFE_F00D
}

guard entryCount > 0 else {
    FileHandle.standardError.write(Data("entry count must be positive\n".utf8))
    exit(2)
}

do {
    let report = try SearchBenchmark.run(
        entryCount: entryCount,
        stressQueryCount: stressQueryCount,
        corpusSeed: corpusSeed
    )
    print("Bounded versus exhaustive search timings (\(report.entryCount) generated entries, \(report.queryCount) queries, seed \(report.corpusSeed)):")
    if stressQueryCount == 0 {
        for row in report.rows {
            print(String(
                format: "query=%@ limit=%d exhaustive=%.3fms bounded=%.3fms speedup=%.2fx results=%d",
                row.query,
                row.limit,
                row.exhaustiveMilliseconds,
                row.boundedMilliseconds,
                row.speedup,
                row.resultCount
            ))
        }
    } else {
        let totalExhaustive = report.rows.reduce(0) { $0 + $1.exhaustiveMilliseconds }
        let totalBounded = report.rows.reduce(0) { $0 + $1.boundedMilliseconds }
        let minimumSpeedup = report.rows.map(\.speedup).min() ?? 0
        let maximumSpeedup = report.rows.map(\.speedup).max() ?? 0
        print(String(
            format: "comparisons=%d exhaustive-total=%.3fms bounded-total=%.3fms aggregate-speedup=%.2fx per-case-speedup=%.2fx...%.2fx",
            report.rows.count,
            totalExhaustive,
            totalBounded,
            totalExhaustive / max(totalBounded, 0.001),
            minimumSpeedup,
            maximumSpeedup
        ))
    }
    print("PASS: bounded scoring exactly matched exhaustive scoring for every case (seed \(report.corpusSeed)).")

    let lifecycleComparisons = try SearchBenchmark.validatePathMetadataLifecycle()
    print("PASS: cached path metadata matched recomputed metadata across \(lifecycleComparisons) lifecycle comparisons.")

    let byteSearch = SearchBenchmark.runByteSearch()
    print(String(
        format: "byte-search iterations=%d legacy=%.3fms optimized=%.3fms speedup=%.2fx checksum=%d",
        byteSearch.iterations,
        byteSearch.legacyMilliseconds,
        byteSearch.optimizedMilliseconds,
        byteSearch.speedup,
        byteSearch.checksum
    ))
} catch {
    FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
    exit(1)
}
