import Darwin
import Foundation

/// Multi-threaded replacement for the engine's single-threaded `fts` walk.
///
/// Directories are read concurrently, but results are emitted in exactly the order
/// `fts_open(FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV | FTS_NOSTAT)` visits them: depth-first
/// pre-order with each directory's children in `readdir` order. Entry order matters because
/// entry IDs break exact ties during ranking, so a faster walk must not reorder the index.
///
/// Per-entry classification mirrors `fts` and `SearchEngine.walkDirectory`:
/// - entries whose `d_type` is known and not a directory are files (`FTS_NSOK`), including symlinks;
/// - `DT_DIR`/`DT_UNKNOWN` entries are `lstat`ed: directories are `FTS_D`, regular files and
///   symlinks are files, anything else (`FTS_DEFAULT`) or a failed `lstat` (`FTS_NS`) is skipped;
/// - a directory on another device is indexed but not descended (`FTS_XDEV`);
/// - an unreadable directory is indexed with no children (`FTS_DNR` after `FTS_D`).
final class ParallelDirectoryWalker: @unchecked Sendable {
    struct Item {
        let path: String
        let isDirectory: Bool
        let node: Node?
    }

    final class Node: @unchecked Sendable {
        let path: String
        var children: [Item] = []

        init(path: String) {
            self.path = path
        }
    }

    private let skipDirectory: ((String) -> Bool)?
    private let includeFile: ((String) -> Bool)?
    private let skipGitDirectories: Bool
    private let progress: ((Int, String) -> Void)?
    private let cancelled: (() -> Bool)?

    private let condition = NSCondition()
    private var queue: [Node] = []
    private var head = 0
    private var outstanding = 0
    private var stopped = false
    private var accepted = 0
    private var lastProgress = CFAbsoluteTimeGetCurrent()
    private var rootDevice: dev_t = 0

    init(
        skipDirectory: ((String) -> Bool)?,
        includeFile: ((String) -> Bool)?,
        skipGitDirectories: Bool,
        progress: ((Int, String) -> Void)?,
        cancelled: (() -> Bool)?
    ) {
        self.skipDirectory = skipDirectory
        self.includeFile = includeFile
        self.skipGitDirectories = skipGitDirectories
        self.progress = progress
        self.cancelled = cancelled
    }

    /// Returns `nil` when the root cannot be walked this way, so the caller can fall back to `fts`.
    func walk(_ root: String) -> [(String, Bool)]? {
        var rootStatus = stat()
        guard lstat(root, &rootStatus) == 0 else { return nil }
        // fts reports a non-directory root (including a symlink, under FTS_PHYSICAL) at
        // level 0 and never descends; level 0 is never indexed, so that yields nothing.
        guard rootStatus.st_mode & S_IFMT == S_IFDIR else { return [] }
        rootDevice = rootStatus.st_dev

        let rootNode = Node(path: root)
        queue = [rootNode]
        outstanding = 1

        let workers = Self.workerCount
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            self.runWorker()
        }

        var output: [(String, Bool)] = []
        output.reserveCapacity(accepted)
        Self.emit(rootNode, into: &output)
        return output
    }

    /// Directory reads are I/O- and kernel-bound; a few threads saturate APFS metadata
    /// throughput, and more add contention (measured: 4 ≈ 4.6x, 8 slower than 4).
    private static var workerCount: Int {
        min(6, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    private static func emit(_ node: Node, into output: inout [(String, Bool)]) {
        for item in node.children {
            output.append((item.path, item.isDirectory))
            if let child = item.node {
                emit(child, into: &output)
            }
        }
    }

    private func runWorker() {
        var pathBuffer: [UInt8] = []
        pathBuffer.reserveCapacity(1_024)

        while true {
            condition.lock()
            while head == queue.count, outstanding > 0, !stopped {
                condition.wait()
            }
            if stopped || head == queue.count {
                condition.broadcast()
                condition.unlock()
                return
            }
            let node = queue[head]
            head += 1
            condition.unlock()

            if cancelled?() == true {
                condition.lock()
                stopped = true
                condition.broadcast()
                condition.unlock()
                return
            }

            var subdirectories: [Node] = []
            let lastPath = read(node, buffer: &pathBuffer, subdirectories: &subdirectories)

            var report: (Int, String)?
            condition.lock()
            queue.append(contentsOf: subdirectories)
            outstanding += subdirectories.count - 1
            accepted += node.children.count
            if progress != nil, let lastPath {
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastProgress > 0.5 {
                    lastProgress = now
                    report = (accepted, lastPath)
                }
            }
            if outstanding == 0 || !subdirectories.isEmpty {
                condition.broadcast()
            }
            condition.unlock()

            if let report {
                progress?(report.0, report.1)
            }
        }
    }

    /// Reads one directory, filling `node.children` in `readdir` order.
    private func read(_ node: Node, buffer: inout [UInt8], subdirectories: inout [Node]) -> String? {
        guard let directory = opendir(node.path) else { return nil }
        defer { closedir(directory) }

        buffer.removeAll(keepingCapacity: true)
        buffer.append(contentsOf: node.path.utf8)
        // fts's NAPPEND: never double the separator after a root of "/".
        if buffer.last != 0x2F { buffer.append(0x2F) }
        let prefixLength = buffer.count

        var children: [Item] = []
        while let entry = readdir(directory) {
            let nameLength = Int(entry.pointee.d_namlen)
            let type = entry.pointee.d_type
            if Int32(type) == DT_WHT { continue }

            buffer.removeSubrange(prefixLength...)
            let isDot: Bool = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: UInt8.self, capacity: nameLength) { name in
                    if name[0] == 0x2E, nameLength == 1 || (nameLength == 2 && name[1] == 0x2E) {
                        return true
                    }
                    buffer.append(contentsOf: UnsafeBufferPointer(start: name, count: nameLength))
                    return false
                }
            }
            if isDot { continue }

            var isDirectory = false
            var descend = false
            if Int32(type) == DT_DIR || Int32(type) == DT_UNKNOWN {
                buffer.append(0)
                var status = stat()
                let statResult = buffer.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: pointer.count) {
                        lstat($0, &status)
                    }
                }
                buffer.removeLast()
                guard statResult == 0 else { continue } // FTS_NS
                switch status.st_mode & S_IFMT {
                case S_IFDIR:
                    isDirectory = true
                    descend = status.st_dev == rootDevice
                case S_IFREG, S_IFLNK:
                    isDirectory = false
                default:
                    continue // FTS_DEFAULT
                }
            }

            if isDirectory {
                if skipGitDirectories, nameLength == 4,
                   buffer[prefixLength] == 0x2E, buffer[prefixLength + 1] == 0x67,
                   buffer[prefixLength + 2] == 0x69, buffer[prefixLength + 3] == 0x74 {
                    continue
                }
                let path = String(decoding: buffer, as: UTF8.self)
                if let skipDirectory, skipDirectory(path) { continue }
                let child = descend ? Node(path: path) : nil
                children.append(Item(path: path, isDirectory: true, node: child))
                if let child { subdirectories.append(child) }
            } else {
                let n = prefixLength
                // Same name screens as SearchEngine.walkDirectory (.DS_Store, .localized, Icon\r).
                if nameLength == 9, buffer[n] == 0x2E, buffer[n + 1] == 0x44, buffer[n + 2] == 0x53,
                   buffer[n + 3] == 0x5F, buffer[n + 4] == 0x53 { continue }
                if nameLength == 10, buffer[n] == 0x2E, buffer[n + 1] == 0x6C, buffer[n + 2] == 0x6F,
                   buffer[n + 3] == 0x63 { continue }
                if nameLength == 5, buffer[n] == 0x49, buffer[n + 1] == 0x63, buffer[n + 2] == 0x6F,
                   buffer[n + 3] == 0x6E, buffer[n + 4] == 0x0D { continue }
                let path = String(decoding: buffer, as: UTF8.self)
                if let includeFile, !includeFile(path) { continue }
                children.append(Item(path: path, isDirectory: false, node: nil))
            }
        }
        node.children = children
        return children.last?.path
    }
}
