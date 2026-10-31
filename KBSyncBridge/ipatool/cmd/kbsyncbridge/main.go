// Command kbsyncbridge exposes ipatool's session-free kbsync generation to
// the Asspp iOS app as a C library (built with -buildmode=c-archive; see
// KBSyncBridge/scripts/build-bridge.sh in the Asspp repository).
//
// Generation mirrors defaultKBSyncGenerator in pkg/appstore and the proven
// cmd/kbsyncgen harness: assets.Load + machine.GenerateKBSync over the
// emulated macOS storeagent. It needs only the 6-byte device GUID and the
// account DSID — no session, no credentials.
package main

/*
#include <stdlib.h>
#include <stdint.h>

// Unicorn is statically linked into this archive (the build script merges
// libunicorn.a into libKBSyncBridge.a). ipatool's purego layer resolves the
// uc_* API at runtime through dlsym(RTLD_DEFAULT), so the symbols must be
// (a) extracted by the static linker when the host app links this archive —
// taking their addresses here creates the required references — and
// (b) exported from the app binary, which the host app's -Wl,-export_dynamic
// link flag provides. The prototypes are declared locally (with the handle
// as void*) instead of including unicorn.h so the archive build does not
// depend on the Unicorn header layout; only uc_version is ever called, and
// it is called with its real signature.
extern unsigned int uc_version(unsigned int *major, unsigned int *minor);
extern unsigned int uc_open(unsigned int arch, unsigned int mode, void **uc);
extern unsigned int uc_close(void *uc);
extern unsigned int uc_emu_start(void *uc, uint64_t begin, uint64_t until, uint64_t timeout, size_t count);
extern unsigned int uc_mem_map(void *uc, uint64_t address, size_t size, uint32_t perms);
extern unsigned int uc_hook_add(void *uc, void **hook, int type, void *callback, void *user_data, uint64_t begin, uint64_t end);

__attribute__((used))
static void *const kbsync_unicorn_anchor[] = {
	(void *)uc_version,
	(void *)uc_open,
	(void *)uc_close,
	(void *)uc_emu_start,
	(void *)uc_mem_map,
	(void *)uc_hook_add,
};

// kbsync_anchor_version calls uc_version directly, anchoring the object that
// holds the anchor table from Go code as well.
static unsigned int kbsync_anchor_version(void) {
	unsigned int major = 0, minor = 0;
	return uc_version(&major, &minor);
}
*/
import "C"

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"time"
	"unsafe"

	"github.com/majd/ipatool/v2/internal/sap/assets"
	"github.com/majd/ipatool/v2/internal/sap/machine"
)

func main() {}

// KBSyncGenerate generates one kbsync blob for a (GUID, DSID) pair.
//
// guidHex is the device GUID as 12 hex characters. On success it returns a
// malloc'd base64 string; on failure it returns NULL and, when outErr is
// non-NULL, stores a malloc'd diagnostic message in *outErr. Every returned
// string must be released with KBSyncFree.
//
//export KBSyncGenerate
func KBSyncGenerate(guidHex *C.char, dsid uint64, outErr **C.char) *C.char {
	_ = C.kbsync_anchor_version()

	fail := func(format string, args ...any) *C.char {
		if outErr != nil {
			*outErr = C.CString(fmt.Sprintf(format, args...))
		}
		return nil
	}

	if guidHex == nil {
		return fail("kbsync bridge: missing GUID")
	}

	guidString := C.GoString(guidHex)

	hardwareID, err := hex.DecodeString(guidString)
	if err != nil || len(hardwareID) != 6 {
		return fail("kbsync bridge: invalid GUID %q: need exactly 6 bytes (12 hex chars)", guidString)
	}

	if dsid == 0 {
		return fail("kbsync bridge: invalid DSID: must be nonzero")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	bundle, err := assets.Load(ctx)
	if err != nil {
		return fail("kbsync bridge: load assets: %v", err)
	}

	blob, err := machine.GenerateKBSync(ctx, bundle, hardwareID, dsid)
	if err != nil {
		return fail("kbsync bridge: generate kbsync: %v", err)
	}

	return C.CString(base64.StdEncoding.EncodeToString(blob))
}

// KBSyncFree releases a string returned by KBSyncGenerate (result or error).
//
//export KBSyncFree
func KBSyncFree(p *C.char) {
	if p != nil {
		C.free(unsafe.Pointer(p))
	}
}
