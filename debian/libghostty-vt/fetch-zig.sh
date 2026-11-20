#!/usr/bin/env bash
# Downloads the Zig that `zig` pins for this machine into DIR, checks its
# SHA-256 and its minisign signature, and prints the directory to put on
# PATH. Zig is not in Debian, so the package build cannot depend on it.
#
#   export PATH="$(debian/libghostty-vt/fetch-zig.sh /opt):$PATH"
set -Eeuo pipefail

DIR="${1:?usage: fetch-zig.sh DIR}"
PINS="$(dirname "${BASH_SOURCE[0]}")/zig"

key="$(awk '$1 == "minisign-key" { print $2 }' "$PINS")"
read -r url sha256 < <(awk -v machine="$(uname -m)" '$1 == machine { print $2, $3 }' "$PINS")
[[ -n "${url:-}" ]] || { echo "Error: no Zig pinned for $(uname -m)" >&2; exit 1; }

archive="$DIR/$(basename "$url")"
mkdir -p "$DIR"
curl -fsSL -o "$archive" "$url"
curl -fsSL -o "$archive.minisig" "$url.minisig"
echo "$sha256  $archive" | sha256sum --check --quiet >&2
minisign -Vq -P "$key" -m "$archive" >&2

tree="$DIR/$(basename "$url" .tar.xz)"
rm -rf "$tree"
tar -xJf "$archive" -C "$DIR"
rm -f "$archive" "$archive.minisig"
echo "$tree"
