import Darwin
import Foundation

public enum UnixSocketError: Error, CustomStringConvertible {
    case invalidPath(String)
    case systemCall(String, Int32)
    case connectionClosed
    case messageTooLarge
    case invalidResponse

    public var description: String {
        switch self {
        case .invalidPath(let path):
            return "Unix socket path is too long: \(path)"
        case .systemCall(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code)))"
        case .connectionClosed:
            return "The backend closed the connection before returning a response"
        case .messageTooLarge:
            return "The backend message exceeded the 16 MB safety limit"
        case .invalidResponse:
            return "The backend returned an invalid response"
        }
    }
}

public enum UnixSocketTransport {
    private static let maximumMessageSize = 16 * 1_024 * 1_024

    public static func request(
        _ request: BackendRequest,
        socketPath: String,
        timeout: TimeInterval = 2
    ) throws -> BackendResponse {
        let descriptor = try connect(to: socketPath, timeout: timeout)
        defer { Darwin.close(descriptor) }

        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        try writeAll(payload, to: descriptor)
        let responseData = try readMessage(from: descriptor)
        guard let response = try? JSONDecoder().decode(BackendResponse.self, from: responseData) else {
            throw UnixSocketError.invalidResponse
        }
        return response
    }

    public static func makeServer(socketPath: String) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw UnixSocketError.systemCall("socket", errno)
        }

        do {
            var address = try makeAddress(path: socketPath)
            unlink(socketPath)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, addressLength(path: socketPath))
                }
            }
            guard result == 0 else {
                throw UnixSocketError.systemCall("bind", errno)
            }
            guard Darwin.listen(descriptor, 32) == 0 else {
                throw UnixSocketError.systemCall("listen", errno)
            }
            chmod(socketPath, S_IRUSR | S_IWUSR)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    public static func acceptClient(from serverDescriptor: Int32) throws -> Int32 {
        while true {
            let descriptor = Darwin.accept(serverDescriptor, nil, nil)
            if descriptor >= 0 {
                // A timeout is defensive for this private, permission-restricted
                // socket. Some macOS environments reject SO_*TIMEO for accepted
                // Unix sockets; that must not terminate the persistent backend.
                try? configureTimeout(10, descriptor: descriptor)
                return descriptor
            }
            if errno == EINTR { continue }
            throw UnixSocketError.systemCall("accept", errno)
        }
    }

    public static func readRequest(from descriptor: Int32) throws -> BackendRequest {
        let data = try readMessage(from: descriptor)
        guard let request = try? JSONDecoder().decode(BackendRequest.self, from: data) else {
            throw UnixSocketError.invalidResponse
        }
        return request
    }

    public static func writeResponse(_ response: BackendResponse, to descriptor: Int32) throws {
        var payload = try JSONEncoder().encode(response)
        payload.append(0x0A)
        try writeAll(payload, to: descriptor)
    }

    private static func connect(to socketPath: String, timeout: TimeInterval) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw UnixSocketError.systemCall("socket", errno)
        }

        do {
            try configureTimeout(timeout, descriptor: descriptor)
            var address = try makeAddress(path: socketPath)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, addressLength(path: socketPath))
                }
            }
            guard result == 0 else {
                throw UnixSocketError.systemCall("connect", errno)
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func configureTimeout(_ timeout: TimeInterval, descriptor: Int32) throws {
        let seconds = floor(timeout)
        var value = timeval(
            tv_sec: Int(seconds),
            tv_usec: Int32((timeout - seconds) * 1_000_000)
        )
        let size = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, size) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &value, size) == 0 else {
            throw UnixSocketError.systemCall("setsockopt", errno)
        }
    }

    private static func makeAddress(path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count + 1 <= capacity else {
            throw UnixSocketError.invalidPath(path)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: capacity) { destination in
                for (offset, byte) in bytes.enumerated() {
                    destination[offset] = byte
                }
                destination[bytes.count] = 0
            }
        }
        return address
    }

    private static func addressLength(path: String) -> socklen_t {
        socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw UnixSocketError.systemCall("write", written < 0 ? errno : EPIPE)
                }
            }
        }
    }

    private static func readMessage(from descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)

        while data.count <= maximumMessageSize {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                    data.append(contentsOf: buffer[..<newline])
                    return data
                }
                data.append(contentsOf: buffer[..<count])
            } else if count == 0 {
                if data.isEmpty { throw UnixSocketError.connectionClosed }
                return data
            } else if errno == EINTR {
                continue
            } else {
                throw UnixSocketError.systemCall("read", errno)
            }
        }
        throw UnixSocketError.messageTooLarge
    }
}
