import ClingSearchCore
import CoreServices
import Darwin
import Foundation
import BetterFindIPC

private struct PersistedIndexMetadata: Codable {
    let configuration: BackendIndexConfiguration
    let lastEventID: UInt64
}

final class BackendManager: @unchecked Sendable {
    private let indexURL: URL
    private let metadataURL: URL
    private let metadataTemporaryURL: URL
    private let logURL: URL
    private let lock = NSLock()
    private let watcher = FilesystemWatcher()
    private let changeQueue = DispatchQueue(label: "com.betterfind.workflow.index-changes", qos: .utility)

    private var engine: ClingEngine?
    private var activeConfiguration: BackendIndexConfiguration?
    private var requestedConfiguration: BackendIndexConfiguration?
    private var indexing = false
    private var indexPhase: BackendIndexPhase?
    private var indexProgressCount = 0
    private var indexProgressPath: String?
    private var lastError: String?
    private var buildGeneration = 0
    private var pendingChanges: [String: UInt64] = [:]
    private var pendingIgnoredEventID: UInt64?
    private var latestObservedEventID: UInt64?
    private var lastProcessedEventID: UInt64?
    private var rebuildAfterCurrentBuild = false
    private var historyReplayComplete = true
    private var persistenceGeneration = 0
    private var indexSavePending = false

    init(indexPath: String) {
        indexURL = URL(fileURLWithPath: indexPath).standardizedFileURL
        metadataURL = URL(fileURLWithPath: indexPath + ".json").standardizedFileURL
        metadataTemporaryURL = URL(fileURLWithPath: indexPath + ".json.tmp").standardizedFileURL
        logURL = indexURL.deletingLastPathComponent().appendingPathComponent("better-find-backend.log")
    }

    func handle(_ request: BackendRequest) -> BackendResponse {
        guard request.protocolVersion == betterFindProtocolVersion else {
            return BackendResponse(
                state: .error,
                message: "Backend protocol mismatch (client \(request.protocolVersion), backend \(betterFindProtocolVersion))"
            )
        }

        switch request.command {
        case .search:
            guard let configuration = request.configuration else {
                return BackendResponse(state: .error, message: "Search request is missing index configuration")
            }
            ensureEngine(for: configuration, forceRebuild: false)
            return search(request, configuration: configuration)

        case .ping:
            return status()

        case .shutdown:
            return BackendResponse(state: .stopping, message: "Backend stopping")
        }
    }

    private func ensureEngine(for configuration: BackendIndexConfiguration, forceRebuild: Bool) {
        let needsStart: Bool = lock.withLock {
            if !forceRebuild, activeConfiguration == configuration, engine != nil { return false }
            if indexing, requestedConfiguration == configuration { return false }
            return true
        }
        guard needsStart else { return }

        // This metadata check only runs when a new engine is actually needed, never
        // on warm queries. It lets Alfred distinguish loading from a true rebuild.
        let canLoadPersistedIndex = !forceRebuild
            && readPersistedMetadata()?.configuration == configuration
            && FileManager.default.fileExists(atPath: indexURL.path)
        let shouldStart: Bool = lock.withLock {
            if !forceRebuild, activeConfiguration == configuration, engine != nil { return false }
            if indexing, requestedConfiguration == configuration { return false }
            buildGeneration += 1
            indexing = true
            if forceRebuild {
                indexPhase = .recovering
            } else if engine != nil {
                indexPhase = .rebuilding
            } else {
                indexPhase = canLoadPersistedIndex ? .loading : .building
            }
            indexProgressCount = 0
            indexProgressPath = nil
            lastError = nil
            requestedConfiguration = configuration
            pendingChanges.removeAll()
            pendingIgnoredEventID = nil
            rebuildAfterCurrentBuild = false
            return true
        }
        guard shouldStart else { return }
        changeQueue.sync {
            // Prevent a save for the retiring engine from pairing its old
            // snapshot with event IDs processed by the replacement build.
            persistenceGeneration += 1
            indexSavePending = false
        }
        let generation = lock.withLock { buildGeneration }
        startWatching(configuration, generation: generation)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.loadOrBuild(
                configuration: configuration,
                generation: generation,
                canLoadPersistedIndex: canLoadPersistedIndex
            )
        }
    }

    private func loadOrBuild(
        configuration: BackendIndexConfiguration,
        generation: Int,
        canLoadPersistedIndex: Bool
    ) {
        let candidate = ClingEngine()
        let coreConfiguration = configuration.coreConfiguration
        var loaded = false

        if canLoadPersistedIndex {
            loaded = candidate.load(from: indexURL, configuration: coreConfiguration)
        }

        if !loaded {
            lock.withLock {
                guard buildGeneration == generation else { return }
                if canLoadPersistedIndex {
                    indexPhase = .recovering
                } else if engine == nil {
                    indexPhase = .building
                } else if indexPhase != .recovering {
                    indexPhase = .rebuilding
                }
            }
            _ = candidate.build(
                configuration: coreConfiguration,
                progress: { [weak self] count, path in
                    guard let self else { return }
                    self.lock.withLock {
                        guard self.buildGeneration == generation else { return }
                        self.indexProgressCount = count
                        self.indexProgressPath = path
                    }
                },
                cancelled: { [weak self] in
                    guard let self else { return true }
                    return self.lock.withLock { self.buildGeneration != generation }
                }
            )
        }
        guard lock.withLock({ buildGeneration == generation }) else { return }

        if loaded {
            let historyDeadline = Date().addingTimeInterval(5)
            while Date() < historyDeadline,
                  !lock.withLock({ historyReplayComplete || buildGeneration != generation }) {
                usleep(20_000)
            }
            lock.withLock {
                if !historyReplayComplete, buildGeneration == generation {
                    // If fseventsd cannot complete replay promptly, a full rebuild is
                    // safer than publishing a potentially stale persisted snapshot.
                    rebuildAfterCurrentBuild = true
                }
            }
        }

        var appliedPendingChanges = false
        while true {
            var batch: [(path: String, eventID: UInt64)] = []
            var finished = false
            var stale = false
            lock.withLock {
                if buildGeneration != generation {
                    stale = true
                } else if pendingChanges.isEmpty {
                    engine = candidate
                    activeConfiguration = configuration
                    requestedConfiguration = configuration
                    indexing = false
                    indexPhase = nil
                    indexProgressCount = 0
                    indexProgressPath = nil
                    lastError = nil
                    if !loaded, !rebuildAfterCurrentBuild {
                        // A full walk plus the drained pending events represents the
                        // filesystem through the latest event observed during the walk.
                        // A dropped stream deliberately withholds this advancement until
                        // its mandatory corrective rebuild finishes.
                        lastProcessedEventID = max(
                            lastProcessedEventID ?? 0,
                            latestObservedEventID ?? 0
                        )
                    } else if let ignoredEventID = pendingIgnoredEventID {
                        // Ignored events can advance only after every earlier pending
                        // real event has been applied to the candidate engine.
                        lastProcessedEventID = max(lastProcessedEventID ?? 0, ignoredEventID)
                    }
                    pendingIgnoredEventID = nil
                    finished = true
                } else {
                    batch = pendingChanges.map { (path: $0.key, eventID: $0.value) }
                    pendingChanges.removeAll()
                }
            }
            if stale { return }
            if finished { break }
            for change in batch {
                appliedPendingChanges = candidate.applyFilesystemChange(path: change.path)
                    || appliedPendingChanges
            }
            let processedThrough = batch.map(\.eventID).max() ?? 0
            lock.withLock {
                lastProcessedEventID = max(lastProcessedEventID ?? 0, processedThrough)
            }
        }

        let rebuild = lock.withLock {
            let value = rebuildAfterCurrentBuild
            rebuildAfterCurrentBuild = false
            return value
        }
        if rebuild {
            // Do not publish an index or checkpoint from a build that overlapped
            // a dropped FSEvents stream. The old durable snapshot/event ID remain
            // available if the corrective rebuild is interrupted.
            ensureEngine(for: configuration, forceRebuild: true)
            return
        }

        var persistenceAccepted = false
        changeQueue.sync {
            guard lock.withLock({ buildGeneration == generation }) else { return }
            if !loaded || appliedPendingChanges {
                candidate.save(to: indexURL)
            }
            guard lock.withLock({ buildGeneration == generation }) else { return }
            persist(configuration)
            persistenceAccepted = true
        }
        guard persistenceAccepted else { return }
    }

    private func search(
        _ request: BackendRequest,
        configuration: BackendIndexConfiguration
    ) -> BackendResponse {
        let snapshot = snapshot()
        guard snapshot.configuration == configuration, let engine = snapshot.engine else {
            return BackendResponse(
                state: snapshot.indexing ? .indexing : .empty,
                message: snapshot.error ?? "Loading or building the Cling index",
                indexCount: snapshot.engine?.count ?? snapshot.progressCount,
                indexPhase: snapshot.phase,
                indexProgressPath: snapshot.progressPath,
                servingExistingIndex: snapshot.engine != nil
            )
        }

        let started = CFAbsoluteTimeGetCurrent()
        let results = engine.search(
            query: request.query ?? "",
            maxResults: request.maxResults ?? 100,
            directoriesOnly: request.directoriesOnly ?? false,
            literalDefault: request.literalDefault ?? false
        )
        let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1_000
        return BackendResponse(
            state: .ready,
            results: results.map {
                BackendSearchResult(
                    path: $0.path,
                    isDirectory: $0.isDirectory,
                    rank: $0.rank
                )
            },
            message: snapshot.indexing ? "A refreshed index is being built in the background" : nil,
            indexCount: engine.count,
            searchMilliseconds: elapsed,
            indexPhase: snapshot.phase,
            indexProgressPath: snapshot.progressPath,
            servingExistingIndex: snapshot.indexing
        )
    }

    private func status() -> BackendResponse {
        let snapshot = snapshot()
        if let error = snapshot.error {
            return BackendResponse(
                state: .error,
                message: error,
                indexCount: snapshot.engine?.count ?? snapshot.progressCount,
                indexPhase: snapshot.phase,
                indexProgressPath: snapshot.progressPath,
                servingExistingIndex: snapshot.engine != nil
            )
        }
        if snapshot.indexing, snapshot.engine == nil {
            return BackendResponse(
                state: .indexing,
                message: "Loading or building the Cling index",
                indexCount: snapshot.progressCount,
                indexPhase: snapshot.phase,
                indexProgressPath: snapshot.progressPath,
                servingExistingIndex: false
            )
        }
        if let engine = snapshot.engine {
            return BackendResponse(
                state: .ready,
                message: snapshot.indexing ? "Refreshing index" : "Index ready",
                indexCount: engine.count,
                indexPhase: snapshot.phase,
                indexProgressPath: snapshot.progressPath,
                servingExistingIndex: snapshot.indexing
            )
        }
        return BackendResponse(state: .empty, message: "Index has not been built")
    }

    private func startWatching(_ configuration: BackendIndexConfiguration, generation: Int) {
        let metadata = readPersistedMetadata()
        let replayEventID: FSEventStreamEventId
        if metadata?.configuration == configuration, let eventID = metadata?.lastEventID, eventID > 0 {
            replayEventID = FSEventStreamEventId(eventID)
        } else {
            replayEventID = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        }

        lock.withLock {
            historyReplayComplete = replayEventID == FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        }

        do {
            let baseline = try watcher.start(path: configuration.root, since: replayEventID) { [weak self] event in
                self?.handleFilesystemEvent(event, configuration: configuration, generation: generation)
            }
            lock.withLock {
                guard buildGeneration == generation else { return }
                let initial = replayEventID == FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
                    ? UInt64(baseline)
                    : UInt64(replayEventID)
                latestObservedEventID = max(latestObservedEventID ?? 0, initial)
                lastProcessedEventID = max(lastProcessedEventID ?? 0, initial)
            }
        } catch {
            lock.withLock {
                lastError = "Could not start FSEvents: \(error)"
            }
        }
    }

    private func handleFilesystemEvent(
        _ event: FilesystemWatcher.Event,
        configuration: BackendIndexConfiguration,
        generation: Int
    ) {
        var liveEngine: ClingEngine?
        var ignoredLiveEventID: UInt64?
        var startRebuild = false
        lock.withLock {
            guard buildGeneration == generation, requestedConfiguration == configuration else { return }
            latestObservedEventID = max(latestObservedEventID ?? 0, UInt64(event.id))
            if event.historyDone {
                historyReplayComplete = true
                return
            }

            if event.requiresRescan {
                if indexing {
                    rebuildAfterCurrentBuild = true
                } else {
                    startRebuild = true
                }
                return
            }
            guard !isIgnoredEventPath(event.path, configuration: configuration) else {
                if indexing {
                    pendingIgnoredEventID = max(pendingIgnoredEventID ?? 0, UInt64(event.id))
                } else {
                    ignoredLiveEventID = UInt64(event.id)
                }
                return
            }
            if indexing || activeConfiguration != configuration || engine == nil {
                pendingChanges[event.path] = max(pendingChanges[event.path] ?? 0, UInt64(event.id))
            } else {
                liveEngine = engine
            }
        }

        if startRebuild {
            ensureEngine(for: configuration, forceRebuild: true)
        } else if let ignoredLiveEventID {
            changeQueue.async { [weak self] in
                guard let self else { return }
                self.lock.withLock {
                    self.lastProcessedEventID = max(
                        self.lastProcessedEventID ?? 0,
                        ignoredLiveEventID
                    )
                }
                // No persistence is scheduled for ignored/generated events alone;
                // writing metadata here would generate another ignored event. The
                // next real change safely persists this advanced watermark.
            }
        } else if let liveEngine {
            changeQueue.async { [weak self, weak liveEngine] in
                guard let self, let liveEngine else { return }
                let changed = liveEngine.applyFilesystemChange(path: event.path)
                self.lock.withLock {
                    self.lastProcessedEventID = max(
                        self.lastProcessedEventID ?? 0,
                        UInt64(event.id)
                    )
                }
                self.schedulePersistence(
                    engine: liveEngine,
                    configuration: configuration,
                    saveIndex: changed
                )
            }
        }
    }

    private func isIgnoredEventPath(_ rawPath: String, configuration: BackendIndexConfiguration) -> Bool {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        let generated = [indexURL.path, metadataURL.path, metadataTemporaryURL.path, logURL.path]
        if generated.contains(path) { return true }
        return configuration.excludedPaths.contains { excluded in
            path == excluded || path.hasPrefix(excluded + "/")
        }
    }

    private func schedulePersistence(
        engine: ClingEngine,
        configuration: BackendIndexConfiguration,
        saveIndex: Bool
    ) {
        indexSavePending = indexSavePending || saveIndex
        persistenceGeneration += 1
        let generation = persistenceGeneration
        changeQueue.asyncAfter(deadline: .now() + 5) { [weak self, weak engine] in
            guard let self, let engine, self.persistenceGeneration == generation else { return }
            let snapshot = self.snapshot()
            guard snapshot.configuration == configuration, snapshot.engine === engine else { return }
            let shouldSaveIndex = self.indexSavePending
            self.indexSavePending = false
            if shouldSaveIndex { engine.save(to: self.indexURL) }
            self.persist(configuration)
        }
    }


    private func snapshot() -> (
        engine: ClingEngine?,
        configuration: BackendIndexConfiguration?,
        indexing: Bool,
        phase: BackendIndexPhase?,
        progressCount: Int,
        progressPath: String?,
        error: String?
    ) {
        lock.withLock {
            (
                engine,
                activeConfiguration,
                indexing,
                indexPhase,
                indexProgressCount,
                indexProgressPath,
                lastError
            )
        }
    }

    private func persist(_ configuration: BackendIndexConfiguration) {
        do {
            try FileManager.default.createDirectory(
                at: metadataURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let eventID = lock.withLock { lastProcessedEventID ?? 0 }
            let data = try JSONEncoder().encode(PersistedIndexMetadata(
                configuration: configuration,
                lastEventID: eventID
            ))
            try data.write(to: metadataTemporaryURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: metadataTemporaryURL.path
            )
            guard rename(metadataTemporaryURL.path, metadataURL.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            lock.withLock {
                lastError = "Could not save index metadata: \(error.localizedDescription)"
            }
        }
    }

    private func readPersistedMetadata() -> PersistedIndexMetadata? {
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        return try? JSONDecoder().decode(PersistedIndexMetadata.self, from: data)
    }
}

private extension BackendIndexConfiguration {
    var coreConfiguration: ClingBuildConfiguration {
        ClingBuildConfiguration(
            root: root,
            includeSubfolders: includeSubfolders,
            includeHidden: includeHidden,
            excludeSystemFolders: excludeSystemFolders,
            systemFolderNames: Set(systemFolderNames),
            excludedPaths: excludedPaths
        )
    }
}
