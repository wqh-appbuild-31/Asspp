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
// [Asspp-ent] v2: storage holds one entry per account DSID, so several
// accounts (e.g. a US and a CN account) can each keep their own blob. Entries
// persist as a list in the Keychain under "kbsync-v2"; a lone pre-v2 entry
// under "kbsync-v1" is adopted into the list on first load.
//
// Cache policy mirrors ipatool's `appstore_kbsync_cache.go`: entries keyed by
// (GUID, DSID), persisted in the Keychain, stored/refreshed only after a blob
// has served a valid response, and invalidated when rejected.
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
    private static let storageKey = "kbsync-v2"
    private static let legacyStorageKey = "kbsync-v1"
    private var entries: [Entry]?

    // MARK: - Import (Phase 2a blob source)

    /// Stores a user-imported blob for the given (GUID, DSID) pair, replacing
    /// only that DSID's entry and keeping every other account's blob.
    func importBlob(_ base64: String, guid: String, dsid: UInt64) throws {
        // Pasted blobs often arrive wrapped; drop all whitespace first.
        let normalized = base64.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let data = Data(base64Encoded: normalized), !data.isEmpty else {
            throw KBSyncError.invalidBlob
        }
        upsert(Entry(guid: guid, dsid: dsid, data: normalized))
    }

    /// The (GUID, DSID) pairs that currently have a stored blob. Settings
    /// uses this to show one row per imported account blob.
    func storedBindings() -> [(guid: String, dsid: UInt64)] {
        load().map { (guid: $0.guid, dsid: $0.dsid) }
    }

    /// Removes the stored blob for one account DSID, if any.
    func removeBlob(dsid: UInt64) {
        var current = load()
        current.removeAll { $0.dsid == dsid }
        persist(current)
    }

    /// Removes every stored blob.
    func removeAll() {
        entries = []
        try? keychain.remove(Self.storageKey)
        try? keychain.remove(Self.legacyStorageKey)
    }

    // MARK: - Lookup

    /// The cached blob for this (GUID, DSID) pair, if one is stored and valid.
    func cachedBlob(guid: String, dsid: UInt64) -> String? {
        guard let entry = load().first(where: { $0.guid == guid && $0.dsid == dsid }),
              let data = Data(base64Encoded: entry.data), !data.isEmpty
        else { return nil }
        return entry.data
    }

    // MARK: - Upstream cache policy

    /// Called only after a blob produced a valid attested-download response.
    func recordSuccess(blob: String, guid: String, dsid: UInt64) {
        upsert(Entry(guid: guid, dsid: dsid, data: blob))
    }

    /// Called when a cached blob was rejected. Removes that DSID's entry
    /// only if it still holds the exact rejected blob.
    func invalidate(blob: String, guid: String, dsid: UInt64) {
        guard load().contains(Entry(guid: guid, dsid: dsid, data: blob)) else { return }
        removeBlob(dsid: dsid)
    }

    // MARK: - Generation seam (Phase 2b)

    /// On-device generation via the emulated storeagent is Phase 2b. When it
    /// lands, this calls into the Go c-archive bridge and returns a fresh
    /// base64 blob; callers and cache policy do not change.
    func generateBlob(guid: String, dsid: UInt64) async throws -> String {
        throw KBSyncError.generationUnavailable
    }

    // MARK: - Persistence

    private func load() -> [Entry] {
        if let entries {
            return entries
        }
        var loaded: [Entry] = []
        if let data = try? keychain.getData(Self.storageKey),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            loaded = decoded
        } else if let data = try? keychain.getData(Self.legacyStorageKey),
                  let legacy = try? JSONDecoder().decode(Entry.self, from: data) {
            // Adopt the single pre-v2 entry, then drop the legacy key so a
            // later removal is not undone by re-adopting it.
            loaded = [legacy]
            persist(loaded)
            try? keychain.remove(Self.legacyStorageKey)
        }
        entries = loaded
        return loaded
    }

    private func persist(_ newEntries: [Entry]) {
        entries = newEntries
        if newEntries.isEmpty {
            try? keychain.remove(Self.storageKey)
        } else if let data = try? JSONEncoder().encode(newEntries) {
            try? keychain.set(data, key: Self.storageKey)
        }
    }

    /// Inserts an entry, replacing any existing entry for the same DSID.
    private func upsert(_ newEntry: Entry) {
        var current = load()
        current.removeAll { $0.dsid == newEntry.dsid }
        current.append(newEntry)
        persist(current)
    }
}
