import Foundation

let clingSubsystem = "com.betterfind.workflow.backend"

// Cling's complete app supplies these hooks from its settings and ignore-file
// layers. Better Find applies its exclusions through Cling's walker and search
// arguments instead, so the core engine intentionally leaves the app-global
// blocklist disabled.
final class PathBlocklist {
    static let shared = PathBlocklist()
    let hasAllows = false
}

func pathBlockMatch(_: String) -> Bool { false }
func isPathBlocked(_: String) -> Bool { false }
func blocklistDirHasAllowedDescendant(_: String) -> Bool { false }

// SearchEngine conditionally imports swift-ignore upstream. Better Find does not
// pass ignore files into the engine; its configured exclusions are normalized
// and enforced by ClingEngine's walker closure instead.
extension String {
    func isIgnored(in _: String) -> Bool { false }
    func isIgnored(in _: String, root _: String) -> Bool { false }
}
