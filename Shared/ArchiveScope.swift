import Foundation

enum ArchiveScopePolicy {
    /// Citations alone are insufficient: an AI response can depend on uncited inputs.
    /// Legacy/opaque results are excluded from scoped sharing rather than assumed safe.
    static func permits(_ inputClipIDs: [UUID]?, within allowed: Set<UUID>) -> Bool {
        guard let dependencies = inputClipIDs, !dependencies.isEmpty else { return false }
        return dependencies.allSatisfy(allowed.contains)
    }
}
