import CryptoKit
import Darwin
import Foundation
import BetterFindIPC

struct BackendClient {
    let indexURL: URL
    let socketPath: String

    init(indexURL: URL) {
        self.indexURL = indexURL.standardizedFileURL
        socketPath = Self.socketPath(for: self.indexURL.path)
    }

    func send(_ request: BackendRequest, launchIfNeeded: Bool = true) throws -> BackendResponse {
        if let response = try? UnixSocketTransport.request(
            request,
            socketPath: socketPath,
            timeout: 10
        ) {
            if response.implementationVersion == betterFindBackendImplementationVersion {
                return response
            }
            stop()
            let stopDeadline = Date().addingTimeInterval(1)
            while Date() < stopDeadline,
                  (try? UnixSocketTransport.request(
                      BackendRequest(command: .ping),
                      socketPath: socketPath,
                      timeout: 0.1
                  )) != nil {
                usleep(50_000)
            }
            // The listening socket can disappear just before the exiting process
            // releases its singleton flock. Give that final teardown a moment.
            usleep(100_000)
        }
        guard launchIfNeeded else {
            throw BackendClientError.unavailable
        }
        try launchBackend()

        let deadline = Date().addingTimeInterval(2)
        var nextLaunchAttempt = Date().addingTimeInterval(0.25)
        repeat {
            if let response = try? UnixSocketTransport.request(
                request,
                socketPath: socketPath,
                timeout: 10
            ), response.implementationVersion == betterFindBackendImplementationVersion {
                return response
            }
            if Date() >= nextLaunchAttempt {
                try? launchBackend()
                nextLaunchAttempt = Date().addingTimeInterval(0.25)
            }
            usleep(50_000)
        } while Date() < deadline
        throw BackendClientError.startupTimedOut(logURL.path)
    }

    func stop() {
        let request = BackendRequest(command: .shutdown)
        _ = try? UnixSocketTransport.request(request, socketPath: socketPath, timeout: 0.5)
    }

    private var backendURL: URL {
        if let override = ProcessInfo.processInfo.environment["BETTER_FIND_BACKEND_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        return URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("better-find-backend")
    }

    private var logURL: URL {
        indexURL.deletingLastPathComponent().appendingPathComponent("better-find-backend.log")
    }

    private func launchBackend() throws {
        let executable = backendURL.path
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw BackendClientError.missingBackend(executable)
        }
        let storageDirectory = indexURL.deletingLastPathComponent()
        let storageDirectoryExisted = FileManager.default.fileExists(atPath: storageDirectory.path)
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !storageDirectoryExisted {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: storageDirectory.path
            )
        }

        let arguments = [
            executable,
            "--socket", socketPath,
            "--index-path", indexURL.path
        ]
        var spawnArguments = arguments.map { strdup($0) }
        spawnArguments.append(nil)
        defer { spawnArguments.dropLast().forEach { free($0) } }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw BackendClientError.couldNotLaunch("posix_spawnattr_init")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID)) == 0 else {
            throw BackendClientError.couldNotLaunch("posix_spawnattr_setflags")
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw BackendClientError.couldNotLaunch("posix_spawn_file_actions_init")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        guard posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(
                  &fileActions,
                  STDOUT_FILENO,
                  logURL.path,
                  O_WRONLY | O_CREAT | O_APPEND,
                  S_IRUSR | S_IWUSR
              ) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, STDOUT_FILENO, STDERR_FILENO) == 0 else {
            throw BackendClientError.couldNotLaunch("posix_spawn file redirection")
        }

        var processID: pid_t = 0
        let result = executable.withCString { executablePointer in
            spawnArguments.withUnsafeMutableBufferPointer { argumentBuffer in
                posix_spawn(
                    &processID,
                    executablePointer,
                    &fileActions,
                    &attributes,
                    argumentBuffer.baseAddress!,
                    environ
                )
            }
        }
        guard result == 0 else {
            throw BackendClientError.couldNotLaunch(String(cString: strerror(result)))
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: logURL.path
        )
    }

    private static func socketPath(for indexPath: String) -> String {
        let digest = SHA256.hash(data: Data(indexPath.utf8))
            .prefix(10)
            .map { String(format: "%02x", $0) }
            .joined()
        return "/tmp/better-find-\(getuid())-v\(betterFindProtocolVersion)-\(digest).sock"
    }
}

enum BackendClientError: Error, CustomStringConvertible {
    case unavailable
    case missingBackend(String)
    case couldNotLaunch(String)
    case startupTimedOut(String)

    var description: String {
        switch self {
        case .unavailable:
            return "Better Find backend is not running"
        case .missingBackend(let path):
            return "Bundled backend is missing or not executable: \(path)"
        case .couldNotLaunch(let reason):
            return "Could not launch Better Find backend: \(reason)"
        case .startupTimedOut(let logPath):
            return "Better Find backend did not start in time; see \(logPath)"
        }
    }
}
