#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="$HERE/releases/koha-dashboard-bibliotecario-v1.7.0.kpz"
cd "$HERE"
mkdir -p "$HERE/releases"
rm -f "$OUT"
zip -qr "$OUT" Koha
printf 'Created %s\n' "$OUT"
