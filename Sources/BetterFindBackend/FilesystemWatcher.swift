import CoreServices
import Foundation

final class FilesystemWatcher {
    struct Event {
        let path: String
        let id: FSEventStreamEventId
        let requiresRescan: Bool
        let historyDone: Bool
    }

    enum WatcherError: Error {
        case couldNotCreateStream
        case couldNotStartStream
    }

    private let queue = DispatchQueue(label: "com.betterfind.workflow.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?
    private var eventHandler: ((Event) -> Void)?

    @discardableResult
    func start(
        path: String,
        since eventID: FSEventStreamEventId,
        handler: @escaping (Event) -> Void
    ) throws -> FSEventStreamEventId {
        stop()
        eventHandler = handler

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, pathsPointer, flags, eventIDs in
            guard let info else { return }
            let watcher = Unmanaged<FilesystemWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(pathsPointer, to: NSArray.self)
            for index in 0..<count {
                guard let path = paths[index] as? String else { continue }
                let eventFlags = flags[index]
                let dropped = eventFlags & (
                    FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
                        | FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
                        | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
                ) != 0
                watcher.eventHandler?(Event(
                    path: path,
                    id: eventIDs[index],
                    requiresRescan: dropped,
                    historyDone: eventFlags
                        & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0
                ))
            }
        }

        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [path] as CFArray,
            eventID,
            0.2,
            createFlags
        ) else {
            throw WatcherError.couldNotCreateStream
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw WatcherError.couldNotStartStream
        }
        self.stream = stream
        return FSEventsGetCurrentEventId()
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        eventHandler = nil
    }

    deinit {
        stop()
    }
}
