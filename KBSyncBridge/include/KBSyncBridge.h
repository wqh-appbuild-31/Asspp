// KBSyncBridge — C interface to the on-device kbsync generator.
//
// The implementation is a Go c-archive built from the vendored ipatool tree
// (KBSyncBridge/ipatool/cmd/kbsyncbridge) with Unicorn 2.1.4 statically
// merged in; see KBSyncBridge/scripts/build-bridge.sh. Generation is
// session-free: it runs Apple's storeagent under emulation and needs only
// the device GUID and the account DSID.
//
// This header is the committed copy the app compiles against (via the
// Objective-C bridging header setting in Configuration/Base.xcconfig). It
// must stay ABI-identical to the header Go generates for the c-archive:
//   extern char* KBSyncGenerate(char* guidHex, uint64_t dsid, char** outErr);
//   extern void  KBSyncFree(char* p);
#ifndef KBSYNC_BRIDGE_H
#define KBSYNC_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Generates one kbsync blob for a (GUID, DSID) pair. guidHex is the device
// GUID as 12 hex characters. On success returns a malloc'd base64 string;
// on failure returns NULL and, when outErr is non-NULL, stores a malloc'd
// diagnostic message in *outErr. Release every returned string with
// KBSyncFree. Potentially slow: the first call in a fresh install downloads
// the pinned Apple asset bundle (~125 MB) into the app cache directory.
char *KBSyncGenerate(const char *guidHex, uint64_t dsid, char **outErr);

// Releases a string returned by KBSyncGenerate (result or error). NULL is
// accepted and ignored.
void KBSyncFree(char *p);

#ifdef __cplusplus
}
#endif

#endif /* KBSYNC_BRIDGE_H */
