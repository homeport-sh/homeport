#!/bin/sh
# homeport installer — served at homeport.sh/install
#   curl -fsSL homeport.sh/install | sh
# Downloads the right prebuilt binary for your OS/arch from GitHub Releases,
# verifies its checksum, and installs it. macOS users can also: brew install
# homeport-sh/tap/homeport
set -eu

REPO="homeport-sh/homeport"
BIN="homeport"

err() { printf 'homeport install: %s\n' "$1" >&2; exit 1; }

# --- platform detection ---
os=$(uname -s)
case "$os" in
  Darwin) os=darwin ;;
  Linux)  os=linux ;;
  *) err "unsupported OS '$os' (need macOS or Linux; on Windows use WSL)" ;;
esac

arch=$(uname -m)
case "$arch" in
  x86_64 | amd64) arch=amd64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *) err "unsupported architecture '$arch'" ;;
esac

# --- resolve version (override with HOMEPORT_VERSION=v0.1.0) ---
ver="${HOMEPORT_VERSION:-}"
if [ -z "$ver" ]; then
  ver=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep '"tag_name":' | head -1 | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
  [ -n "$ver" ] || err "could not determine the latest version — set HOMEPORT_VERSION=vX.Y.Z"
fi
num=${ver#v} # archive names carry the version without the leading v

archive="${BIN}_${num}_${os}_${arch}.tar.gz"
base="https://github.com/$REPO/releases/download/$ver"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

printf 'downloading %s %s (%s/%s)...\n' "$BIN" "$ver" "$os" "$arch"
curl -fsSL "$base/$archive" -o "$tmp/$archive" || err "download failed: $base/$archive"

# --- verify checksum (best-effort; warn if no sha tool) ---
if curl -fsSL "$base/checksums.txt" -o "$tmp/checksums.txt" 2>/dev/null; then
  want=$(grep " $archive\$" "$tmp/checksums.txt" | awk '{print $1}')
  if [ -n "$want" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
      got=$(sha256sum "$tmp/$archive" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
      got=$(shasum -a 256 "$tmp/$archive" | awk '{print $1}')
    fi
    [ -z "${got:-}" ] || [ "$got" = "$want" ] || err "checksum mismatch — refusing to install"
  fi
fi

tar -xzf "$tmp/$archive" -C "$tmp" || err "extract failed"
[ -f "$tmp/$BIN" ] || err "archive did not contain the $BIN binary"
chmod +x "$tmp/$BIN"

# --- pick an install dir: a writable one on PATH, else ~/.local/bin ---
dir=""
for d in /usr/local/bin /opt/homebrew/bin; do
  if [ -d "$d" ] && [ -w "$d" ]; then dir=$d; break; fi
done
if [ -z "$dir" ]; then
  if [ -w /usr/local/bin ] 2>/dev/null || command -v sudo >/dev/null 2>&1; then
    dir=/usr/local/bin
  else
    dir="$HOME/.local/bin"; mkdir -p "$dir"
  fi
fi

if [ -w "$dir" ]; then
  mv "$tmp/$BIN" "$dir/$BIN"
else
  printf 'installing to %s (needs sudo)...\n' "$dir"
  sudo mv "$tmp/$BIN" "$dir/$BIN"
fi

printf '\n✓ installed %s to %s\n' "$BIN" "$dir/$BIN"
case ":$PATH:" in
  *":$dir:"*) : ;;
  *) printf '  add it to your PATH:  export PATH="%s:$PATH"\n' "$dir" ;;
esac
printf '  get started:  %s bootstrap root@<your-server-ip>\n' "$BIN"
