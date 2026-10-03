// Command probe is the app the sandbox integration test deploys: a small HTTP
// server that reports what it can see and tries what a hostile tenant would.
// Built with cgo so it is dynamically linked, like a Bun or Node binary.
package main

import (
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "sleep": // a child for /fork
			time.Sleep(time.Hour)
			return
		case "migrate", "migrate-fail": // a release command: leaves a mark where the app can see it
			if os.Args[1] == "migrate-fail" {
				fmt.Println("migration failed")
				os.Exit(1)
			}
			kernel, _ := os.ReadFile("/proc/sys/kernel/osrelease")
			mark := os.Getenv("STATE_DIR") + "/migrated"
			prev, _ := os.ReadFile(mark)
			n, _ := strconv.Atoi(strings.Fields(string(prev) + " 0")[0])
			_ = os.WriteFile(mark, []byte(fmt.Sprintf("%d %s", n+1, strings.TrimSpace(string(kernel)))), 0o600)
			fmt.Println("migrated")
			return
		case "worker": // a process: a heartbeat in the state dir, a line in the log
			name := "worker"
			if len(os.Args) > 2 {
				name = os.Args[2]
			}
			for {
				_ = os.WriteFile(os.Getenv("STATE_DIR")+"/beat-"+name, []byte(strconv.FormatInt(time.Now().Unix(), 10)), 0o600)
				fmt.Println("beat " + name)
				time.Sleep(time.Second)
			}
		case "crash": // a process that won't stay up
			fmt.Println("crashing")
			os.Exit(3)
		}
	}
	http.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) { fmt.Fprint(w, "ok") })
	http.HandleFunc("/env", func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, os.Getenv(r.URL.Query().Get("k"))) })
	http.HandleFunc("/uid", func(w http.ResponseWriter, _ *http.Request) { fmt.Fprint(w, os.Getuid()) })
	http.HandleFunc("/log", func(w http.ResponseWriter, r *http.Request) { // a line on stdout, for the logs tests
		fmt.Println(r.URL.Query().Get("m"))
		fmt.Fprint(w, "logged")
	})
	http.HandleFunc("/kernel", func(w http.ResponseWriter, _ *http.Request) {
		b, _ := os.ReadFile("/proc/sys/kernel/osrelease")
		fmt.Fprint(w, strings.TrimSpace(string(b)))
	})
	http.HandleFunc("/procs", func(w http.ResponseWriter, _ *http.Request) {
		ents, _ := os.ReadDir("/proc")
		n := 0
		for _, e := range ents {
			if _, err := strconv.Atoi(e.Name()); err == nil {
				n++
			}
		}
		fmt.Fprint(w, n)
	})
	http.HandleFunc("/write", func(w http.ResponseWriter, r *http.Request) {
		if err := os.WriteFile(r.URL.Query().Get("path"), []byte("x"), 0o600); err != nil {
			fmt.Fprint(w, "denied")
			return
		}
		fmt.Fprint(w, "written")
	})
	http.HandleFunc("/read", func(w http.ResponseWriter, r *http.Request) {
		if _, err := os.ReadFile(r.URL.Query().Get("path")); err != nil {
			fmt.Fprint(w, "denied")
			return
		}
		fmt.Fprint(w, "read")
	})
	http.HandleFunc("/dial", func(w http.ResponseWriter, r *http.Request) {
		c, err := net.DialTimeout("tcp", r.URL.Query().Get("addr"), 3*time.Second)
		if err != nil {
			fmt.Fprint(w, "blocked")
			return
		}
		c.Close()
		fmt.Fprint(w, "connected")
	})
	http.HandleFunc("/resolve", func(w http.ResponseWriter, r *http.Request) {
		if _, err := net.LookupHost(r.URL.Query().Get("name")); err != nil {
			fmt.Fprint(w, "failed")
			return
		}
		fmt.Fprint(w, "resolved")
	})
	http.HandleFunc("/blob", func(w http.ResponseWriter, r *http.Request) { // egress, for metering
		kb, _ := strconv.Atoi(r.URL.Query().Get("kb"))
		chunk := make([]byte, 1024)
		for i := 0; i < kb; i++ {
			_, _ = w.Write(chunk)
		}
	})
	http.HandleFunc("/alloc", func(w http.ResponseWriter, r *http.Request) {
		mb, _ := strconv.Atoi(r.URL.Query().Get("mb"))
		hog := make([][]byte, 0, mb)
		for i := 0; i < mb; i++ {
			b := make([]byte, 1<<20)
			for j := range b {
				b[j] = 1
			}
			hog = append(hog, b)
		}
		fmt.Fprint(w, "survived ", len(hog))
	})
	http.HandleFunc("/fork", func(w http.ResponseWriter, r *http.Request) {
		n, _ := strconv.Atoi(r.URL.Query().Get("n"))
		started := 0
		for i := 0; i < n; i++ {
			if exec.Command("/proc/self/exe", "sleep").Start() != nil {
				break
			}
			started++
		}
		fmt.Fprint(w, started)
	})
	// a slow start, like a real app's: what a cold wake has to wait out
	if d, err := time.ParseDuration(os.Getenv("PROBE_START_DELAY")); err == nil {
		time.Sleep(d)
	}
	addr := net.JoinHostPort(os.Getenv("HOST"), os.Getenv("PORT"))
	fmt.Println("probe listening on", addr)
	if err := http.ListenAndServe(addr, nil); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
