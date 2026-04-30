// Command oommemhog allocates a bounded amount of memory and holds it for a
// fixed duration so Challenges can produce real, observable memory pressure
// against the running host.
//
// Why a custom tool and not stress-ng?
//
//	1. stress-ng requires a system package install (sudo). oommemhog is built
//	   from source in this repo and is auditable line-by-line, satisfying
//	   Constitution Article I (anti-bluff: every Challenge artifact is in the
//	   repo and reviewable).
//	2. Pages allocated by Go's runtime are not committed until written to —
//	   Linux backs them with the zero-page CoW. We must explicitly touch one
//	   byte per page, otherwise MemAvailable does not drop and oom-watch
//	   would not see real pressure. stress-ng has a --vm-keep flag for the
//	   same reason.
//	3. We can advertise a unique label in argv so the report's top-mem table
//	   contains a recognizable string the Challenge can grep for, providing
//	   a positive identification of the process inside the captured atop
//	   sample (anti-bluff: proves the snapshot saw THIS test process).
//
// Usage:
//
//	oommemhog -target 4G -chunk 256M -delay 100ms -hold 30s -label memhog-test
//
// Safety: oommemhog refuses to allocate more than 16 GiB and enforces a 5-min
// upper bound on hold time. These limits are intentional; the daemon's job is
// to prove pressure detection, not to crash the host.
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"runtime"
	"syscall"
	"time"
)

const (
	pageSize       = 4096
	maxTargetBytes = 16 * 1 << 30 // 16 GiB hard ceiling
	maxHold        = 5 * time.Minute
	minChunkBytes  = 1 << 20 // 1 MiB
)

func main() {
	var (
		target = flag.Int64("target", 1<<32, "total bytes to allocate (max 16 GiB)")
		chunk  = flag.Int64("chunk", 256<<20, "bytes per allocation step")
		delay  = flag.Duration("delay", 100*time.Millisecond, "pause between allocation steps")
		hold   = flag.Duration("hold", 20*time.Second, "duration to hold memory after target reached (max 5m)")
		label  = flag.String("label", "oommemhog", "label printed in logs and visible in argv (greppable)")
	)
	flag.Parse()
	log.SetFlags(log.LstdFlags | log.LUTC)

	if *target <= 0 || *target > maxTargetBytes {
		log.Fatalf("[%s] -target out of range (1..%d bytes); got %d", *label, maxTargetBytes, *target)
	}
	if *chunk < minChunkBytes || *chunk > *target {
		log.Fatalf("[%s] -chunk out of range (%d..%d bytes); got %d", *label, minChunkBytes, *target, *chunk)
	}
	if *hold < 0 || *hold > maxHold {
		log.Fatalf("[%s] -hold out of range (0..%v); got %v", *label, maxHold, *hold)
	}

	log.Printf("[%s] starting: target=%d MiB, chunk=%d MiB, delay=%v, hold=%v",
		*label, *target>>20, *chunk>>20, *delay, *hold)

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	// Hold all chunks in a slice so the GC cannot reclaim them while we wait.
	var blocks [][]byte
	var allocated int64
	for allocated < *target {
		select {
		case s := <-sigCh:
			log.Printf("[%s] caught %v at %d MiB allocated; releasing", *label, s, allocated>>20)
			return
		default:
		}
		size := *chunk
		if remaining := *target - allocated; size > remaining {
			size = remaining
		}
		b := make([]byte, size)
		// Touch every page so the kernel actually commits backing pages,
		// otherwise zero-page CoW means MemAvailable does not drop.
		for off := int64(0); off < size; off += pageSize {
			b[off] = byte(allocated >> 20)
		}
		blocks = append(blocks, b)
		allocated += size

		var ms runtime.MemStats
		runtime.ReadMemStats(&ms)
		log.Printf("[%s] allocated %d/%d MiB (heap_inuse=%d MiB)",
			*label, allocated>>20, *target>>20, ms.HeapInuse>>20)
		time.Sleep(*delay)
	}

	log.Printf("[%s] target reached; holding for %v", *label, *hold)
	timer := time.NewTimer(*hold)
	defer timer.Stop()
	select {
	case s := <-sigCh:
		log.Printf("[%s] caught %v during hold; releasing", *label, s)
	case <-timer.C:
		log.Printf("[%s] hold complete; releasing", *label)
	}

	// Reference blocks once more to guarantee the compiler keeps them live
	// to this point. Without this, the GC could in principle reclaim earlier.
	runtime.KeepAlive(blocks)
	fmt.Printf("[%s] done; allocated %d MiB peak\n", *label, allocated>>20)
}
