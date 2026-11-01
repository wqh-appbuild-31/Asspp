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
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

// kbsync_probe_exec_mmap tests whether this process is allowed to make an
// anonymous read/write page executable — the exact operation Unicorn's
// patched ipatool_jit_write_protect performs on its translation buffer
// before executing translated code (mprotect to PROT_READ|PROT_EXEC on a
// plain mmap, no MAP_JIT). On iOS that protection change is denied
// (EACCES) unless the process holds the com.apple.security.cs.allow-jit
// entitlement or is running under a debugger (CS_DEBUGGED); a free
// (Personal Team) provisioning profile grants neither, and the patch's
// failure path is perror + abort(), which would kill the whole app.
// Probing the identical operation first lets the bridge report a clean
// error instead. Returns 0 when the operation is permitted, otherwise
// the errno of the failing call. The probed page holds an aarch64 "ret"
// opcode but is never called — only the protection change is tested.
static int kbsync_probe_exec_mmap(void) {
	long page = sysconf(_SC_PAGESIZE);
	if (page <= 0) {
		page = 4096;
	}
	unsigned char *p = mmap(NULL, (size_t)page, PROT_READ | PROT_WRITE,
		MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		return errno;
	}
	p[0] = 0xc0; p[1] = 0x03; p[2] = 0x5f; p[3] = 0xd6; // aarch64 ret
	if (mprotect(p, (size_t)page, PROT_READ | PROT_EXEC) != 0) {
		int e = errno;
		munmap(p, (size_t)page);
		return e;
	}
	munmap(p, (size_t)page);
	return 0;
}

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

	// Capability preflight (deliberately probed on every call, never
	// cached — a debugger/JIT enabler attaching later in the session
	// changes the answer). If iOS will not let this process execute
	// translated code, fail HERE with a descriptive error: downstream,
	// Unicorn's ipatool_jit_write_protect reacts to the same denial
	// with abort(), which took the whole app down on free provisioning
	// profiles (Asspp-2026-11-01-075815.ips). Failing before the asset
	// download also avoids pulling ~125 MB that could never be used.
	if probeErrno := C.kbsync_probe_exec_mmap(); probeErrno != 0 {
		errnoName := ""
		switch probeErrno {
		case 1:
			errnoName = " (EPERM)"
		case 13:
			errnoName = " (EACCES)"
		}
		return fail("kbsync bridge: on-device generation unavailable: iOS denied executable memory for the emulator (mprotect to PROT_EXEC on an anonymous page failed, errno %d%s). Unicorn's translated code needs JIT-style executable memory, which a free provisioning profile cannot grant (com.apple.security.cs.allow-jit is a restricted entitlement). Manual blob import still works.", int(probeErrno), errnoName)
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
