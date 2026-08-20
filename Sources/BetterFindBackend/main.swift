import Darwin
import Foundation
import BetterFindIPC

private enum BackendMainError: Error, CustomStringConvertible {
    case usage
    case alreadyRunning

    var description: String {
        switch self {
        case .usage:
            return "Usage: better-find-backend --socket <path> --index-path <path>"
        case .alreadyRunning:
            return "Another Better Find backend already owns this socket"
        }
    }
}

private final class InstanceLock {
    let descriptor: Int32

    init(path: String) throws {
        descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw UnixSocketError.systemCall("open backend lock", errno)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw BackendMainError.alreadyRunning
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

private func argumentValue(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

do {
    signal(SIGPIPE, SIG_IGN)
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let socketPath = argumentValue("--socket", in: arguments),
          let indexPath = argumentValue("--index-path", in: arguments) else {
        throw BackendMainError.usage
    }

    let socketURL = URL(fileURLWithPath: socketPath)
    try FileManager.default.createDirectory(
        at: socketURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let instanceLock = try InstanceLock(path: socketPath + ".lock")
    let serverDescriptor = try UnixSocketTransport.makeServer(socketPath: socketPath)
    defer {
        Darwin.close(serverDescriptor)
        unlink(socketPath)
        withExtendedLifetime(instanceLock) {}
    }

    let manager = BackendManager(indexPath: indexPath)
    var shouldStop = false
    while !shouldStop {
        let client = try UnixSocketTransport.acceptClient(from: serverDescriptor)

        do {
            let request = try UnixSocketTransport.readRequest(from: client)
            let response = manager.handle(request)
            try UnixSocketTransport.writeResponse(response, to: client)
            shouldStop = request.command == .shutdown
        } catch {
            let response = BackendResponse(state: .error, message: String(describing: error))
            try? UnixSocketTransport.writeResponse(response, to: client)
        }
        Darwin.close(client)
    }
} catch BackendMainError.alreadyRunning {
    exit(0)
} catch {
    FileHandle.standardError.write(Data("better-find-backend: \(error)\n".utf8))
    exit(1)
}
