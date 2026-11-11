#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stub" "$TMP/venv/bin"
export RE_VENV="$TMP/venv" MARKER_FILE="$TMP/installer-called"
export PATH="$TMP/stub:$PATH"

cat > "$TMP/stub/dpkg-query" <<'STUB'
#!/usr/bin/env bash
case "${*: -1}" in
    binwalk) printf 'install ok installed\t2.4.3' ;;
    radare2) printf 'install ok installed\t5.9.8' ;;
    gdb-multiarch) printf 'install ok installed\t16.3' ;;
    ltrace) printf 'install ok installed\t0.7.3' ;;
    *) printf 'dpkg-query: no packages found matching %s\n' "${*: -1}" >&2; exit 1 ;;
esac
STUB
cat > "$TMP/venv/bin/python" <<'STUB'
#!/usr/bin/env bash
[[ "${FAKE_VENV_MISSING:-0}" == 1 ]] && exit 1
printf '16.1.2\n'
STUB
cat > "$TMP/stub/apt-get" <<'STUB'
#!/usr/bin/env bash
printf 'apt-get called\n' >> "$MARKER_FILE"
exit 96
STUB
cat > "$TMP/stub/sudo" <<'STUB'
#!/usr/bin/env bash
printf 'sudo called\n' >> "$MARKER_FILE"
exit 96
STUB
cat > "$TMP/stub/uv" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
    printf 'uv stub\n'
    exit 0
fi
printf 'uv install called\n' >> "$MARKER_FILE"
exit 96
STUB
chmod +x "$TMP/stub/"* "$TMP/venv/bin/python"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_row() { grep -Fqx "$1" "$TMP/output" || fail "missing row: $1"; }
run_case() {
    local label=$1 expected_rc=$2 rc=0
    shift 2
    bash "$ROOT/re.setup.sh" "$@" > "$TMP/output" 2>&1 || rc=$?
    [[ "$rc" -eq "$expected_rc" ]] || fail "$label exit $rc (expected $expected_rc)"
    [[ $(awk '/^RE_SETUP_RESULT=/{n++} END {print n+0}' "$TMP/output") -eq 1 ]] || fail "$label RESULT count"
    [[ $(tail -n 1 "$TMP/output") == RE_SETUP_RESULT=* ]] || fail "$label RESULT is not last"
    [[ ! -e "$MARKER_FILE" ]] || fail "$label called installer: $(cat "$MARKER_FILE")"
    printf 'PASS %s\n' "$label"
}

run_case check-installed 0 --check
[[ $(grep -Ec '^[0-4] \| ' "$TMP/output") -eq 8 ]] || fail 'check row count'
assert_row '0 | binwalk | installed 2.4.3'
assert_row '1 | radare2 | installed 5.9.8'
assert_row '1 | python3-capstone | missing (install: sudo apt-get install python3-capstone)'
assert_row '3 | python3-unicorn | missing (install: sudo apt-get install python3-unicorn)'
assert_row '2 | gdb-multiarch | installed 16.3'
assert_row '2 | ltrace | installed 0.7.3'
assert_row '4 | python3-hypothesis | missing (install: sudo apt-get install python3-hypothesis)'
assert_row "2 | frida-tools | installed 16.1.2"
assert_row 'RE_SETUP_RESULT=check:apt=4/7:venv=ok'

FAKE_VENV_MISSING=1 run_case check-venv-missing 0 --check
assert_row "2 | frida-tools | missing (install: uv pip install --python $RE_VENV/bin/python frida-tools)"
assert_row 'RE_SETUP_RESULT=check:apt=4/7:venv=missing'

run_case dry-run 0 --dry-run
assert_row 'RE_SETUP_RESULT=dry-run'
run_case conflicting-flags 64 --check --dry-run
assert_row 'RE_SETUP_RESULT=failed-usage'
run_case unknown-flag 64 --unrecognized
assert_row 'RE_SETUP_RESULT=failed-usage'
