# KBSyncBridge — on-device kbsync generation for Asspp-ent (Phase 2b)

Asspp's attested `ent/download` path needs a **kbsync blob**: an opaque
FairPlay keybag-sync blob bound to (device GUID, account DSID), produced by
Apple's storeagent. No iOS API mints one, so — exactly like the reference
ipatool — this bridge runs Apple's own storeagent code inside a Unicorn
emulator, on the device, and returns the blob. Generation is session-free:
no Apple ID session or credential is involved.

## Layout

- `ipatool/` — a vendored copy of majd/ipatool (MIT) at the exact tree that
  was verified to generate valid blobs server-side (macOS 27 / 26A434
  asset profile), plus one added package:
  - `ipatool/cmd/kbsyncbridge/` — `package main` built as a c-archive,
    exporting `KBSyncGenerate(guidHex, dsid, &err)` / `KBSyncFree`. It is a
    thin wrapper over `assets.Load` + `machine.GenerateKBSync`.
  - `ipatool/cmd/kbsyncgen/` — the desktop harness used for server-side
    generation (Phase 2a stopgap); kept for reference.
- `include/KBSyncBridge.h` — the C interface the app compiles against.
- `scripts/build-bridge.sh` — builds `lib/libKBSyncBridge.a` (iOS arm64):
  Unicorn 2.1.4 (guest arch **arm64**, static, with ipatool's iOS W^X
  patch) merged via libtool into the Go c-archive. Runs on the macOS CI
  runner; see `.github/workflows/build-ent.yml`.
- `lib/` — build output, generated in CI, not committed.

## How the app links it

`Configuration/Base.xcconfig` (iphoneos SDK only) adds:

- `LIBRARY_SEARCH_PATHS` → `KBSyncBridge/lib`
- `OTHER_LDFLAGS` → `-lKBSyncBridge -Wl,-export_dynamic`
- `SWIFT_OBJC_BRIDGING_HEADER` → `KBSyncBridge/include/KBSyncBridge.h`

`-export_dynamic` matters: ipatool's purego layer is linked statically but
resolves the `uc_*` API at runtime via `dlsym(RTLD_DEFAULT)`, so the Unicorn
symbols must land in the app binary's dynamic symbol table. The CI workflow
verifies `uc_open`/`uc_version` are exported from the built app binary.

Swift side: `Asspp/Backend/AppStore/KBSyncGenerator.swift` wraps the C API;
`KBSyncProvider.generateBlob(guid:dsid:)` calls it (device builds only —
macOS and the iOS simulator keep the Phase 2a behaviour and report
generation as unavailable). Manual blob import (Settings → Attested
Download) remains as the fallback everywhere.

## Assets on device

Nothing Apple-authored ships in the repo or the IPA. On the first
generation in a fresh install, ipatool's `assets.Load` downloads the pinned
macOS 27 frameworks (AppleMediaServices, commerce, CoreFP, CoreFP.icxs;
≈125 MB total, SHA-256 pinned in `ipatool/internal/sap/assets`) from
Apple's public restore image via HTTP range requests, and caches them
under the app container's cache directory
(`Library/Caches/ipatool/sap/apple-assets-macos-27-26A434-arm64-v1`, via
Go's `os.UserCacheDir()`). Later generations reuse the cache and take
seconds. If iOS purges the cache directory, the next generation simply
re-downloads.

## Known unknowns

CI proves the archive builds, links, and exports the right symbols. It
cannot prove that iOS lets Unicorn execute translated code inside an app
signed with a free (SideStore) provisioning profile: the iOS patch toggles
the TCG buffer between writable and executable with mprotect, which the OS
may still refuse under that signing. That question is answered only by
running this build on a device; if generation is refused, the error
surfaces in Settings → Logs and the imported-blob fallback keeps working.
