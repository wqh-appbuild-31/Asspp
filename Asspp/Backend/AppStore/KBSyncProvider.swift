import Foundation
import KeychainAccess

// [Asspp-ent] Phase 2a: kbsync blob supply for the attested download path.
//
// A kbsync blob is an opaque FairPlay keybag-sync blob bound to exactly one
// (device GUID, account DSID) pair. ipatool v2.7.0 generates it by running
// Apple's storeagent under emulation; that generator is Phase 2b and slots in
// behind `generateBlob(guid:dsid:)` without changing callers.
//
// Until then the only source is an imported blob: the user generates one with
// the reference ipatool binary (using this app's own GUID and the account's
// DSID) and pastes it into Settings. Blobs are long-lived, so an imported blob
// is a workable stopgap.
//
// Cache policy mirrors ipatool's `appstore_kbsync_cache.go`: a single entry
// keyed by (GUID, DSID), persisted in the Keychain, stored/refreshed only
// after a blob has served a valid response, and invalidated when rejected.
enum KBSyncError: LocalizedError {
    case generationUnavailable
    case invalidBlob
    case mismatchedBinding

    var errorDescription: String? {
        switch self {
        case .generationUnavailable:
            String(localized: "On-device kbsync generation is not available yet. Import a blob in Settings instead.")
        case .invalidBlob:
            String(localized: "The kbsync blob is not valid base64 data.")
        case .mismatchedBinding:
            String(localized: "The kbsync blob does not match this device GUID and account DSID.")
        }
    }
}

actor KBSyncProvider {
    static let shared = KBSyncProvider()

    private struct Entry: Codable, Equatable {
        var guid: String
        var dsid: UInt64
        var data: String // base64-encoded blob
    }

    private let keychain = Keychain(service: "wiki.qaq.Asspp.kbsync")
    private static let storageKey = "kbsync-v1"
    private var entry: Entry?

    // MARK: - Import (Phase 2a blob source)

    /// Stores a user-imported blob for the given (GUID, DSID) pair.
    func importBlob(_ base64: String, guid: String, dsid: UInt64) throws {
        // Pasted blobs often arrive wrapped; drop all whitespace first.
        let normalized = base64.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let data = Data(base64Encoded: normalized), !data.isEmpty else {
            throw KBSyncError.invalidBlob
        }
        store(Entry(guid: guid, dsid: dsid, data: normalized))
    }

    /// The (GUID, DSID) pair the currently stored blob is bound to, if any.
    /// Settings uses this to show import state.
    func storedBinding() -> (guid: String, dsid: UInt64)? {
        guard let entry = load() else { return nil }
        return (entry.guid, entry.dsid)
    }

    func removeBlob() {
        entry = nil
        try? keychain.remove(Self.storageKey)
    }

    // MARK: - Lookup

    /// The cached blob for this (GUID, DSID) pair, if one is stored and valid.
    func cachedBlob(guid: String, dsid: UInt64) -> String? {
        guard let entry = load(), entry.guid == guid, entry.dsid == dsid,
              let data = Data(base64Encoded: entry.data), !data.isEmpty
        else { return nil }
        return entry.data
    }

    // MARK: - Upstream cache policy

    /// Called only after a blob produced a valid attested-download response.
    func recordSuccess(blob: String, guid: String, dsid: UInt64) {
        store(Entry(guid: guid, dsid: dsid, data: blob))
    }

    /// Called when a cached blob was rejected. Removes the entry only if it
    /// still holds the exact rejected blob.
    func invalidate(blob: String, guid: String, dsid: UInt64) {
        guard load() == Entry(guid: guid, dsid: dsid, data: blob) else { return }
        removeBlob()
    }

    // MARK: - Generation seam (Phase 2b)

    /// On-device generation via the emulated storeagent is Phase 2b. When it
    /// lands, this calls into the Go c-archive bridge and returns a fresh
    /// base64 blob; callers and cache policy do not change.
    func generateBlob(guid: String, dsid: UInt64) async throws -> String {
        throw KBSyncError.generationUnavailable
    }

    // MARK: - Persistence

    private func load() -> Entry? {
        if let entry {
            return entry
        }
        guard let data = try? keychain.getData(Self.storageKey), let data,
              let decoded = try? JSONDecoder().decode(Entry.self, from: data)
        else { return nil }
        entry = decoded
        return decoded
    }

    private func store(_ newEntry: Entry) {
        entry = newEntry
        if let data = try? JSONEncoder().encode(newEntry) {
            try? keychain.set(data, key: Self.storageKey)
        }
    }
}
