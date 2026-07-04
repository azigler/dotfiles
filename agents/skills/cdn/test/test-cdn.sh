#!/usr/bin/env bash
# test-cdn.sh — dry-run + unit tests for cdn.sh. NO creds, NO network required.
# Run: bash test/test-cdn.sh   (exit 0 = all pass)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CDN="$HERE/../cdn.sh"
PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "  ✗ FAIL: $1" >&2; }
eq()   { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$3] got [$2]"; fi; }
match(){ if printf '%s' "$2" | grep -Eq "$3"; then ok; else bad "$1: [$2] !~ /$3/"; fi; }

# Source pure helpers (the run-guard keeps main() from firing on source).
# shellcheck disable=SC1090
source "$CDN"
set +e +u   # cdn.sh's top-level `set -euo` leaked in via source; assertions
            # deliberately run failing commands to check exit codes.

# ── pure helpers ─────────────────────────────────────────────────────────────
eq "ext png"     "$(ext_of a/b/foo.png)"  "png"
eq "ext upper"   "$(ext_of FOO.JPG)"      "jpg"
eq "ext none"    "$(ext_of Makefile)"     ""
eq "ext multi"   "$(ext_of a.b.svg)"      "svg"

eq "ct png"      "$(content_type_of png)"  "image/png"
eq "ct jpg"      "$(content_type_of jpg)"  "image/jpeg"
eq "ct jpeg"     "$(content_type_of jpeg)" "image/jpeg"
eq "ct gif"      "$(content_type_of gif)"  "image/gif"
eq "ct webp"     "$(content_type_of webp)" "image/webp"
eq "ct svg"      "$(content_type_of svg)"  "image/svg+xml"
eq "ct avif"     "$(content_type_of avif)" "image/avif"
eq "ct unknown"  "$(content_type_of xyz)"  "application/octet-stream"

eq "strip //"    "$(strip_trailing_slash 'https://cdn.zig.computer///')" "https://cdn.zig.computer"
eq "strip none"  "$(strip_trailing_slash 'https://cdn.zig.computer')"    "https://cdn.zig.computer"

# ── derive_key ───────────────────────────────────────────────────────────────
# Use a controlled name (mktemp adds a random .suffix that ext_of would pick up).
TMPD="$(mktemp -d)"; TMP="$TMPD/pixel.png"; printf 'hello-cdn' > "$TMP"
SHA="$(sha256sum "$TMP" | cut -d' ' -f1)"
eq  "key override"  "$(derive_key "$TMP" png 'custom/a.png' 0)" "custom/a.png"
eq  "key default"   "$(derive_key "$TMP" png '' 0)"             "img/${SHA:0:16}.png"
eq  "key no-ext"    "$(derive_key "$TMP" '' '' 0)"              "img/${SHA:0:16}"
match "key review"  "$(derive_key "$TMP" png '' 1)"             '^review/[0-9]{4}-[0-9]{2}/[0-9a-f]{8}\.png$'

# ── up --dry-run: url assembly (trailing slash on base is stripped) ──────────
# default (content-addressed) dry-run over an existing file:
URL2="$(CDN_BASE_URL='https://cdn.zig.computer/' bash "$CDN" up --dry-run "$TMP" 2>/dev/null)"
eq  "dry default(file)" "$URL2" "https://cdn.zig.computer/img/${SHA:0:16}.png"
URLK="$(CDN_BASE_URL='https://cdn.zig.computer' bash "$CDN" up --key aaif/x.png --dry-run "$TMP" 2>/dev/null)"
eq  "dry --key url"    "$URLK" "https://cdn.zig.computer/aaif/x.png"

# ── missing secrets => exit 3 (non-dry-run, on every network subcommand) ─────
for sub in "up $TMP" "get k" "ls" "rm k" "purge k"; do
  # shellcheck disable=SC2086  # intentional word-split: $sub is a mini arg list
  CDN_SECRETS_FILE=/dev/null bash "$CDN" $sub >/dev/null 2>&1
  eq "exit3: $sub" "$?" "3"
done

# ── dispatch / usage ─────────────────────────────────────────────────────────
bash "$CDN" --help >/dev/null 2>&1;  eq "help exit0" "$?" "0"
bash "$CDN"       >/dev/null 2>&1;   eq "noargs exit2" "$?" "2"

# usage errors exit 2 (not 1 via ${:?}) — honors the documented contract
bash "$CDN" get      >/dev/null 2>&1; eq "get noarg exit2"      "$?" "2"
bash "$CDN" purge    >/dev/null 2>&1; eq "purge noarg exit2"    "$?" "2"
bash "$CDN" up --key >/dev/null 2>&1; eq "up --key noval exit2" "$?" "2"

# ── dry-run on a MISSING content-addressed file: must error, print NO url ─────
OUTM="$(CDN_BASE_URL='https://cdn.zig.computer' bash "$CDN" up --dry-run /no/such/f.png 2>/dev/null)"; RCM=$?
eq "dry missing default: empty stdout" "$OUTM" ""
if [ "$RCM" -ne 0 ]; then ok; else bad "dry missing default: expected nonzero exit, got 0"; fi
# but --key dry-run needs no file (no hashing):
OUTK2="$(CDN_BASE_URL='https://cdn.zig.computer' bash "$CDN" up --key a/b.png --dry-run /no/such.png 2>/dev/null)"
eq "dry --key missing ok" "$OUTK2" "https://cdn.zig.computer/a/b.png"

# ── REGRESSION: never probe the canonical public url around upload ───────────
# The cache-poisoning bug was a HEAD/GET of the canonical url (negative-caches a
# 404 for hours). Guard BEHAVIORALLY, not by a literal token:
#   A) no curl line HEADs the url (any of -I / --head / -fsSI);
#   B) any curl that FETCHES the url (-o ... url) must be cache-busted (_cb=).
# (The `purge` curl posts to the CF API and references $url only in --data, with
#  no `-o`, so it's correctly excluded from B.)
if grep -E 'curl' "$CDN" | grep -Eq '(-I |--head|-fsSI).*url'; then
  bad "regression: a HEAD of the canonical url is present"
else ok; fi
FETCHES="$(grep -E 'curl' "$CDN" | grep -E -- '-o .*url')"
if [ -z "$FETCHES" ]; then
  bad "regression: no cache-busted reachability GET found"
elif printf '%s\n' "$FETCHES" | grep -qv '_cb='; then
  bad "regression: a canonical-url fetch is not cache-busted -> $FETCHES"
else ok; fi

rm -rf "$TMPD"
echo "── cdn.sh tests: $PASS passed, $FAIL failed ──" >&2
[ "$FAIL" -eq 0 ]
