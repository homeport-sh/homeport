#!/usr/bin/env bash
# End-to-end test of hosted builds on a real Linux host with gVisor: plays the
# control plane (a source tarball to fetch, an upload to accept, both over
# HTTPS), hands homeportd build-run a job, and checks what comes out - and
# what a build can and can't reach from inside its sandbox.
#
# Needs root, systemd, go, openssl, python3 and network (it pulls golang from
# Docker Hub). Skips without them unless REQUIRE_SANDBOX=1 (CI sets it). It
# installs homeportd, homeport and crane, so run it on a throwaway machine.
set -uo pipefail
cd "$(dirname "$0")/.."

need() {
  if ! command -v "$1" >/dev/null; then
    [[ ${REQUIRE_SANDBOX:-} == 1 ]] && { echo "missing $1 (REQUIRE_SANDBOX=1)"; exit 1; }
    echo "skip: $1 not installed"; exit 0
  fi
}
for t in go openssl python3 systemctl; do need "$t"; done
if [[ $(id -u) != 0 ]]; then
  [[ ${REQUIRE_SANDBOX:-} == 1 ]] && { echo "must run as root"; exit 1; }
  echo "skip: needs root"; exit 0
fi

fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
has()  { if [[ $2 == *"$3"* ]]; then ok "$1"; else fail "$1: [$3] not in output"; fi; }
lacks() { if [[ $2 != *"$3"* ]]; then ok "$1"; else fail "$1: [$3] in output"; fi; }

HD=/usr/local/bin/homeportd
awk "/<<'HOMEPORTD_SCRIPT'/{f=1;next} /^HOMEPORTD_SCRIPT\$/{f=0} f" bootstrap/bootstrap.sh > /tmp/homeportd.new
install -m 755 /tmp/homeportd.new "$HD"
go build -o /usr/local/bin/homeport ./cmd/homeport || { echo "homeport build failed"; exit 1; }
"$HD" builder-install || { echo "builder-install failed"; exit 1; }
command -v crane >/dev/null && ok "builder-install put crane in place" || fail "no crane"

# the control plane's side: HTTPS with our own CA, which the runner trusts
W=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=test-ca -keyout "$W/ca.key" -out "$W/ca.crt" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj /CN=127.0.0.1 -keyout "$W/srv.key" -out "$W/srv.csr" 2>/dev/null
printf 'subjectAltName=IP:127.0.0.1\n' > "$W/san"
openssl x509 -req -in "$W/srv.csr" -CA "$W/ca.crt" -CAkey "$W/ca.key" -CAcreateserial -days 1 -extfile "$W/san" -out "$W/srv.crt" 2>/dev/null
cp "$W/ca.crt" /usr/local/share/ca-certificates/homeport-test.crt && update-ca-certificates >/dev/null
cat > "$W/server.py" <<'PY'
import http.server, ssl, sys, os
root = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        p = os.path.join(root, self.path.lstrip("/").split("?")[0])
        if not os.path.isfile(p):
            self.send_response(404); self.end_headers(); return
        b = open(p, "rb").read()
        self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_PUT(self):
        n = int(self.headers.get("Content-Length") or 0)
        open(os.path.join(root, "uploaded" + self.path.replace("/", "_")), "wb").write(self.rfile.read(n))
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 8443), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(sys.argv[2], sys.argv[3])
s.socket = ctx.wrap_socket(s.socket, server_side=True)
s.serve_forever()
PY
mkdir -p "$W/www"
python3 "$W/server.py" "$W/www" "$W/srv.crt" "$W/srv.key" &
srv=$!
trap 'kill $srv 2>/dev/null; rm -rf "$W"; rm -f /usr/local/share/ca-certificates/homeport-test.crt; update-ca-certificates >/dev/null 2>&1' EXIT
sleep 1

# repo <name> <main.go> [homeport.yaml]: a GitHub-shaped tarball (one top dir)
repo() {
  local d="$W/repo/$1-0123456"
  mkdir -p "$d"
  printf 'module hello\n\ngo 1.24\n' > "$d/go.mod"
  printf '%s' "$2" > "$d/main.go"
  [[ -n ${3:-} ]] && printf '%s' "$3" > "$d/homeport.yaml"
  tar -czf "$W/www/$1.tgz" -C "$W/repo" "$1-0123456"
}

arch=$(source "$HD" >/dev/null 2>&1; host_arch)
build() { # <repo> <build uuid> → output in OUT, exit in RC
  local job
  job=$(jq -n --arg b "$2" --arg arch "$arch" --arg src "https://127.0.0.1:8443/$1.tgz" --arg up "https://127.0.0.1:8443/up/$2" \
    '{build: $b, app: "1c2d3e4f-0000-4000-8000-000000000001", sha: "0123456789abcdef0123456789abcdef01234567",
      arch: $arch, source: $src, upload: $up, timeout: 600}')
  OUT=$("$HD" build-run <<<"$job" 2>&1); RC=$?
}

# 1. a Go repo builds in golang, inside gVisor, unprivileged, and the binary
#    it uploads runs
repo hello 'package main

import "fmt"

func main() { fmt.Println("hello from a hosted build") }
' 'build:
  command: echo "UID=$(id -u)"; if curl -s -m 5 http://169.254.169.254/ >/dev/null 2>&1; then echo METADATA-REACHED; fi; if curl -fsS -m 20 https://proxy.golang.org/ >/dev/null 2>&1; then echo INTERNET-OK; fi; CGO_ENABLED=0 go build -o server .
'
build hello 11111111-1111-4111-8111-111111111111
if [[ $RC -eq 0 ]]; then ok "a Go repo builds"; else fail "build failed ($RC): $OUT"; fi
has "it ran unprivileged" "$OUT" "UID=64000"
has "it reached the internet" "$OUT" "INTERNET-OK"
lacks "it couldn't reach the cloud metadata service" "$OUT" "METADATA-REACHED"
up="$W/www/uploaded_up_11111111-1111-4111-8111-111111111111"
if [[ -s $up ]]; then
  chmod +x "$up"
  has "the uploaded binary runs" "$("$up" 2>&1)" "hello from a hosted build"
else
  fail "nothing was uploaded"
fi

# 2. a compile error fails the build with the compiler's words; no upload
repo broken 'package main

func main() { undefinedThing() }
'
build broken 22222222-2222-4222-8222-222222222222
if [[ $RC -ne 0 ]]; then ok "a broken repo fails"; else fail "a broken repo built"; fi
has "the log says why" "$OUT" "undefined: undefinedThing"
[[ ! -e "$W/www/uploaded_up_22222222-2222-4222-8222-222222222222" ]] && ok "a failed build uploads nothing" || fail "a failed build uploaded"

# 3. nothing is left behind but the app's cache
[[ -z $(ls -A /var/lib/homeport/builds 2>/dev/null) ]] && ok "workspaces are removed" || fail "left: $(ls /var/lib/homeport/builds)"
[[ -z $(ip netns list | grep -E '^hp-62') ]] && ok "build networks are removed" || fail "left: $(ip netns list)"
[[ -d /var/lib/homeport/build-cache/1c2d3e4f-0000-4000-8000-000000000001/go ]] && ok "the dependency cache stays" || fail "no cache"

[[ $fails -eq 0 ]] && echo "all build integration tests passed" || { echo "$fails failed"; exit 1; }
