import Darwin
import Foundation

/// Stage timings for the persistent backend: full walk, snapshot save, snapshot load,
/// live FSEvents-style updates, and resident memory. Run against a real directory so the
/// walk exercises the same `fts`/inclusion path as the workflow.
public struct BackendBenchmarkReport: Sendable {
    public var entries = 0
    public var buildMilliseconds = 0.0
    public var saveMilliseconds = 0.0
    public var indexBytes = 0
    public var loadMilliseconds = 0.0
    public var addMilliseconds = 0.0
    public var removeFolderMilliseconds = 0.0
    public var singleChangeMilliseconds = 0.0
    public var churnSaveBytes = 0
    public var residentBytesAfterLoad = 0
    /// Ordered result paths for a fixed query list, used to prove storage changes keep ranking identical.
    public var resultFingerprint: [String] = []
}

public enum BackendBenchmark {
    public static func run(root: String, indexURL: URL, queries: [String]) -> BackendBenchmarkReport {
        var report = BackendBenchmarkReport()
        let configuration = ClingBuildConfiguration(
            root: root,
            includeSubfolders: true,
            includeHidden: false,
            excludeSystemFolders: true,
            systemFolderNames: ["System", "private", "usr", "bin", "sbin", "cores", "dev", "etc"],
            excludedPaths: []
        )

        let builder = ClingEngine()
        report.buildMilliseconds = time { _ = builder.build(configuration: configuration) }
        report.entries = builder.count
        report.saveMilliseconds = time { builder.save(to: indexURL) }
        report.indexBytes = fileSize(indexURL)

        let loaded = ClingEngine()
        let baselineResident = residentBytes()
        report.loadMilliseconds = time { _ = loaded.load(from: indexURL, configuration: configuration) }
        report.residentBytesAfterLoad = max(0, residentBytes() - baselineResident)

        for query in queries {
            for literal in [false, true] {
                let results = loaded.search(query: query, maxResults: 200, directoriesOnly: false, literalDefault: literal)
                report.resultFingerprint.append("\(literal ? "'" : "")\(query): " + results.map { "\($0.path)#\($0.rank)" }.joined(separator: "|"))
            }
        }

        // Live updates: create a folder with files, apply as FSEvents would, then remove it.
        let churn = (root as NSString).appendingPathComponent("zz-backend-bench-churn")
        try? FileManager.default.removeItem(atPath: churn)
        try? FileManager.default.createDirectory(atPath: churn, withIntermediateDirectories: true)
        for index in 0 ..< 2_000 {
            FileManager.default.createFile(atPath: churn + "/churn-file-\(index).txt", contents: nil)
        }
        report.addMilliseconds = time { _ = loaded.applyFilesystemChange(path: churn) }
        try? FileManager.default.removeItem(atPath: churn)
        report.removeFolderMilliseconds = time { _ = loaded.applyFilesystemChange(path: churn) }

        let single = (root as NSString).appendingPathComponent("zz-backend-bench-single.txt")
        FileManager.default.createFile(atPath: single, contents: nil)
        var total = 0.0
        for _ in 0 ..< 50 {
            total += time { _ = loaded.applyFilesystemChange(path: single) }
        }
        try? FileManager.default.removeItem(atPath: single)
        _ = loaded.applyFilesystemChange(path: single)
        report.singleChangeMilliseconds = total / 50

        let churnURL = indexURL.appendingPathExtension("churn")
        loaded.save(to: churnURL)
        report.churnSaveBytes = fileSize(churnURL)
        try? FileManager.default.removeItem(at: churnURL)
        return report
    }

    private static func time(_ body: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        body()
        return (CFAbsoluteTimeGetCurrent() - start) * 1_000
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private static func residentBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
