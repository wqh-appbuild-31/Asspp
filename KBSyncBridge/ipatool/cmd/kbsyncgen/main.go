// Command kbsyncgen generates a single kbsync blob for an explicit
// (GUID, DSID) pair using ipatool's own SAP asset loader and emulated
// storeagent, mirroring defaultKBSyncGenerator in pkg/appstore.
// Generation is session-free: it needs only the 6-byte GUID and the DSID.
package main

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/majd/ipatool/v2/internal/sap/assets"
	"github.com/majd/ipatool/v2/internal/sap/machine"
)

func main() {
	guidHex := flag.String("guid", "", "six-byte device GUID, 12 hex chars")
	dsid := flag.Uint64("dsid", 0, "account DSID")
	out := flag.String("out", "", "optional file to write the base64 blob to")
	flag.Parse()

	hardwareID, err := hex.DecodeString(*guidHex)
	if err != nil || len(hardwareID) != 6 {
		fmt.Fprintf(os.Stderr, "invalid GUID %q: need exactly 6 bytes (12 hex chars)\n", *guidHex)
		os.Exit(2)
	}
	if *dsid == 0 {
		fmt.Fprintln(os.Stderr, "invalid DSID: must be nonzero")
		os.Exit(2)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	bundle, err := assets.Load(ctx)
	if err != nil {
		fmt.Fprintf(os.Stderr, "load assets: %v\n", err)
		os.Exit(1)
	}

	blob, err := machine.GenerateKBSync(ctx, bundle, hardwareID, *dsid)
	if err != nil {
		fmt.Fprintf(os.Stderr, "generate kbsync: %v\n", err)
		os.Exit(1)
	}

	encoded := base64.StdEncoding.EncodeToString(blob)
	fmt.Fprintf(os.Stderr, "guid=%s dsid=%d raw_blob_bytes=%d base64_chars=%d\n",
		*guidHex, *dsid, len(blob), len(encoded))

	if *out != "" {
		if err := os.WriteFile(*out, []byte(encoded+"\n"), 0o600); err != nil {
			fmt.Fprintf(os.Stderr, "write output: %v\n", err)
			os.Exit(1)
		}
		fmt.Fprintf(os.Stderr, "wrote %s\n", *out)
	}

	fmt.Println(encoded)
}
