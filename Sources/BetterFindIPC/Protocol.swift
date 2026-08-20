import Foundation

public let betterFindProtocolVersion = 1
public let betterFindBackendImplementationVersion = "betterfind-cling-e307f37-9"

public enum BackendCommand: String, Codable, Sendable {
    case search
    case ping
    case shutdown
}

public enum BackendState: String, Codable, Sendable {
    case ready
    case indexing
    case empty
    case error
    case stopping
}

public enum BackendIndexPhase: String, Codable, Sendable {
    case loading
    case building
    case rebuilding
    case recovering
}

public struct BackendIndexConfiguration: Codable, Equatable, Sendable {
    public let root: String
    public let includeSubfolders: Bool
    public let includeHidden: Bool
    public let excludeSystemFolders: Bool
    public let systemFolderNames: [String]
    public let excludedPaths: [String]

    public init(
        root: String,
        includeSubfolders: Bool,
        includeHidden: Bool,
        excludeSystemFolders: Bool,
        systemFolderNames: [String],
        excludedPaths: [String]
    ) {
        self.root = root
        self.includeSubfolders = includeSubfolders
        self.includeHidden = includeHidden
        self.excludeSystemFolders = excludeSystemFolders
        self.systemFolderNames = systemFolderNames
        self.excludedPaths = excludedPaths
    }
}

public struct BackendRequest: Codable, Sendable {
    public let protocolVersion: Int
    public let command: BackendCommand
    public let configuration: BackendIndexConfiguration?
    public let query: String?
    public let maxResults: Int?
    public let directoriesOnly: Bool?
    public let literalDefault: Bool?

    public init(
        command: BackendCommand,
        configuration: BackendIndexConfiguration? = nil,
        query: String? = nil,
        maxResults: Int? = nil,
        directoriesOnly: Bool? = nil,
        literalDefault: Bool? = nil,
        protocolVersion: Int = betterFindProtocolVersion
    ) {
        self.protocolVersion = protocolVersion
        self.command = command
        self.configuration = configuration
        self.query = query
        self.maxResults = maxResults
        self.directoriesOnly = directoriesOnly
        self.literalDefault = literalDefault
    }
}

public struct BackendSearchResult: Codable, Sendable {
    public let path: String
    public let isDirectory: Bool
    public let rank: Int

    public init(path: String, isDirectory: Bool, rank: Int) {
        self.path = path
        self.isDirectory = isDirectory
        self.rank = rank
    }
}

public struct BackendResponse: Codable, Sendable {
    public let protocolVersion: Int
    public let implementationVersion: String
    public let state: BackendState
    public let results: [BackendSearchResult]
    public let message: String?
    public let indexCount: Int
    public let searchMilliseconds: Double?
    public let indexPhase: BackendIndexPhase?
    public let indexProgressPath: String?
    public let servingExistingIndex: Bool?

    public init(
        state: BackendState,
        results: [BackendSearchResult] = [],
        message: String? = nil,
        indexCount: Int = 0,
        searchMilliseconds: Double? = nil,
        indexPhase: BackendIndexPhase? = nil,
        indexProgressPath: String? = nil,
        servingExistingIndex: Bool = false,
        protocolVersion: Int = betterFindProtocolVersion,
        implementationVersion: String = betterFindBackendImplementationVersion
    ) {
        self.protocolVersion = protocolVersion
        self.implementationVersion = implementationVersion
        self.state = state
        self.results = results
        self.message = message
        self.indexCount = indexCount
        self.searchMilliseconds = searchMilliseconds
        self.indexPhase = indexPhase
        self.indexProgressPath = indexProgressPath
        self.servingExistingIndex = servingExistingIndex
    }
}
