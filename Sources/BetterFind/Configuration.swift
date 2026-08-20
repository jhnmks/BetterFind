import Foundation
import Yams


enum ConfiguredSortBy: String {
    case relevance
    case name
    case type
    case path
}

enum ConfiguredSortOrder: String {
    case ascending
    case descending
}

struct WorkflowConfiguration {
    var root = "~"
    var includeSubfolders = true
    var includeHiddenFiles = false
    var caseSensitive = false
    var excludeSystemFolders = true
    var systemFolders: Set<String> = [
        "System", "private", "usr", "bin", "sbin", "cores", "dev", "etc"
    ]
    var excludedPaths = [
        "~/Library/Caches",
        "~/Library/Containers",
        "~/Library/Group Containers",
        "~/Library/Application Support",
        "~/Library/Developer",
        "~/Library/Metadata"
    ]
    var limit: Int? = 100
    var sortBy = ConfiguredSortBy.relevance
    var sortOrder = ConfiguredSortOrder.descending
}

enum ConfigurationError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let message): return message
        }
    }
}

enum WorkflowConfigurationParser {
    static func parseStringSequenceYAML(_ source: String, setting: String) throws -> [String] {
        do {
            return try YAMLDecoder().decode([String].self, from: source)
        } catch {
            throw ConfigurationError.invalid(
                "Invalid \(setting); expected a YAML sequence of strings: \(error)"
            )
        }
    }
}

func standardizePath(_ value: String) -> String {
    let expanded = NSString(string: value).expandingTildeInPath
    return URL(fileURLWithPath: expanded).standardizedFileURL.path
}

func validateDirectoryPath(_ value: String) throws -> String {
    let path = standardizePath(value)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw ConfigurationError.invalid("Search root does not exist or is not a directory: \(path)")
    }
    return path
}
