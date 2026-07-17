package main

import (
	"fmt"
	"strconv"
	"strings"
)

// cmdStats reports the app's live resource usage from the cgroup systemd
// already accounts for — same kernel numbers Docker's `stats` reads.
// Deliberately client-side: reading unit properties is unprivileged, so
// this needs no homeportd involvement and works on any homeportd version.
func cmdStats(args []string) error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	unit := "homeport-" + cfg.App

	remote := fmt.Sprintf(
		"systemctl show %s --property=ActiveState,ActiveEnterTimestamp,MemoryCurrent,MemoryPeak,MemoryMax,CPUUsageNSec,CPUQuotaPerSecUSec,TasksCurrent"+
			" && echo ===host==="+
			" && free -b | awk 'NR==2{print \"HOSTMEM=\"$3\"/\"$2}'"+
			" && df -B1 --output=avail,size / | awk 'NR==2{print \"HOSTDISK=\"$1\"/\"$2}'"+
			" && du -sb /opt/homeport/%s/releases 2>/dev/null | awk '{print \"RELDISK=\"$1}' || true",
		unit, cfg.App,
	)
	out, err := sshOutput(cfg.Server, remote)
	if err != nil {
		return fmt.Errorf("could not read stats from %s: %w", cfg.Server, err)
	}

	props := map[string]string{}
	for _, line := range strings.Split(out, "\n") {
		if k, v, ok := strings.Cut(strings.TrimSpace(line), "="); ok {
			props[k] = v
		}
	}

	fmt.Printf("app:      %s — %s", cfg.App, props["ActiveState"])
	if ts := props["ActiveEnterTimestamp"]; ts != "" {
		fmt.Printf(" since %s", ts)
	}
	fmt.Println()
	fmt.Printf("memory:   %s now", fmtBytes(props["MemoryCurrent"]))
	if peak := fmtBytes(props["MemoryPeak"]); peak != "?" {
		fmt.Printf(" · %s peak", peak)
	}
	// MemoryMax is "infinity" (or unset) when no limit is configured.
	if max := fmtBytes(props["MemoryMax"]); max != "?" {
		fmt.Printf(" · %s max", max)
	}
	fmt.Println()
	if ns, err := strconv.ParseUint(props["CPUUsageNSec"], 10, 64); err == nil {
		fmt.Printf("cpu:      %.1fs total", float64(ns)/1e9)
		// CPUQuotaPerSecUSec is "infinity" when uncapped; otherwise µs/sec,
		// so 1500000 == 150% == 1.5 cores.
		if q, err := strconv.ParseUint(props["CPUQuotaPerSecUSec"], 10, 64); err == nil && q > 0 {
			fmt.Printf(" · %d%% quota", q/10000)
		}
		fmt.Println()
	}
	if t := props["TasksCurrent"]; t != "" && t != "[not set]" {
		fmt.Printf("tasks:    %s\n", t)
	}
	if rel := fmtBytes(props["RELDISK"]); rel != "?" {
		fmt.Printf("releases: %s on disk\n", rel)
	}
	if hm := props["HOSTMEM"]; hm != "" {
		used, total, _ := strings.Cut(hm, "/")
		fmt.Printf("host:     mem %s / %s", fmtBytes(used), fmtBytes(total))
		if hd := props["HOSTDISK"]; hd != "" {
			avail, size, _ := strings.Cut(hd, "/")
			fmt.Printf(" · disk %s free of %s", fmtBytes(avail), fmtBytes(size))
		}
		fmt.Println()
	}
	return nil
}

// fmtBytes renders a systemd byte-count property ("[not set]", "infinity",
// or a number) as a human size.
func fmtBytes(v string) string {
	n, err := strconv.ParseUint(v, 10, 64)
	if err != nil {
		return "?"
	}
	switch {
	case n >= 1<<30:
		return fmt.Sprintf("%.1f GB", float64(n)/(1<<30))
	case n >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(n)/(1<<20))
	case n >= 1<<10:
		return fmt.Sprintf("%.1f KB", float64(n)/(1<<10))
	default:
		return fmt.Sprintf("%d B", n)
	}
}
