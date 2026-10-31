#if os(iOS) && !targetEnvironment(simulator)
import Foundation

/// [Asspp-ent] Phase 2b: on-device kbsync generation through the Go bridge
/// (KBSyncBridge c-archive: ipatool's emulated storeagent + Unicorn).
///
/// The call is synchronous and potentially slow: the first call in a fresh
/// install downloads the pinned Apple asset bundle (~125 MB) into the app's
/// cache directory; later calls reuse that cache and take seconds. Callers
/// must keep it off the main thread — `KBSyncProvider` invokes it from a
/// detached task.
enum KBSyncGenerator {
    static func generate(guid: String, dsid: UInt64) throws -> String {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = KBSyncGenerate(guid, dsid, &errorPointer)
        if let errorPointer {
            let message = String(cString: errorPointer)
            KBSyncFree(errorPointer)
            throw KBSyncError.generationFailed(message)
        }
        guard let result else {
            throw KBSyncError.generationFailed("kbsync bridge returned no result")
        }
        let blob = String(cString: result)
        KBSyncFree(result)
        guard let data = Data(base64Encoded: blob), !data.isEmpty else {
            throw KBSyncError.invalidBlob
        }
        return blob
    }
}
#endif
