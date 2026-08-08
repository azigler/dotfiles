#!/usr/bin/env bash
#
# re.setup.sh — the OPT-IN reverse-engineering / instrumentation tier.
#
#   bash re.setup.sh --dry-run    # print the plan, touch nothing
#   bash re.setup.sh              # install (idempotent; safe to re-run)
#
# WHY THIS IS A SEPARATE SCRIPT AND NOT A LINE IN ubuntu.setup.sh
#
#   1. Weight. This tier is ~700 MB of tooling that most machines will never
#      use. It must NOT land on every box as a side effect of provisioning.
#   2. Reachability. ubuntu.setup.sh's entire body sits inside
#      `if [ "$(hostname -s)" != "zig-computer" ]`, i.e. it is a first-run-only
#      script. A `--re` flag bolted on there would be UNREACHABLE on an
#      already-provisioned box — which is exactly when you want this tier.
#
# It also doubles as this tier's upgrade path (repo rule 6: upgrade != vendor
# != provision). Re-running is idempotent: apt packages already present are
# skipped, and the venv install runs `--upgrade`. There is deliberately no
# `re.upgrade.sh`.
#
# WHAT IT DOES NOT DO: install Ghidra, angr, Qiling, qemu, AFL++, or any
# emulator. Those are heavyweight and tier-specific — install them when a
# target actually demands one, not speculatively.
#
# Source of truth for the inventory (versions, gotchas, what is absent):
#   agents/skills/cleanroom/reference/tool-shelf.md
# Do not restate that table here; a second copy of a fact is a copy that rots.
#
# UNATTENDED-REPORTING CONTRACT (dotfiles-cxle). This script prints exactly one
#   RE_SETUP_RESULT=<verdict>
# line on EVERY terminal path, including crashes. A caller MUST treat exit 0
# without that marker as FAILURE.
#
#   RE_SETUP_RESULT=ok:apt=<n>/<t>:venv=ok          everything verified present
#   RE_SETUP_RESULT=dry-run                         --dry-run; nothing touched
#   RE_SETUP_RESULT=partial:apt=<n>/<t>:venv=<s>    something did not verify
#   RE_SETUP_RESULT=failed-unsupported:<why>        wrong OS / no apt / no uv
#   RE_SETUP_RESULT=failed-usage                    bad arguments
#   RE_SETUP_RESULT=failed-unexpected:rc=<n>        died before a verdict

# NOT `set -e`: an early exit must still reach a verdict line. The EXIT trap
# below is the backstop for the paths no branch anticipated.
set -uo pipefail

VENV="${RE_VENV:-$HOME/.venvs/re}"

# From tool-shelf.md's "Installing for a real run". Cheapest-first, and
# deliberately excluding anything heavyweight.
APT_PKGS=(
    binwalk            # tier 0 — carve unknown blobs/firmware
    radare2            # tier 1 — the cheapest way to close the static tier
    python3-capstone   # tier 1 — disassembly from Python
    python3-unicorn    # tier 3 — isolated CPU execution
    gdb-multiarch      # tier 2 — stock gdb here is x86-64 ONLY
    ltrace             # tier 2 — library-call trace (upstream is stale)
    python3-hypothesis # tier 4 — cheapest property-testing win
)

VERDICT_EMITTED=0
verdict() {
    VERDICT_EMITTED=1
    printf 'RE_SETUP_RESULT=%s\n' "$1"
}
on_exit() {
    local rc=$?
    if [ "$VERDICT_EMITTED" -eq 0 ]; then
        printf 'RE_SETUP_RESULT=failed-unexpected:rc=%s\n' "$rc"
    fi
}
trap on_exit EXIT

finish() { verdict "$1"; exit "${2:-0}"; }
section() { printf '\n==> %s\n' "$1"; }
note()    { printf '    %s\n' "$1"; }

# Is an apt package installed? A PURE EXISTENCE CHECK — dpkg-query writes to
# stderr for an unknown package, and "unknown" is the expected case here, so
# the suppression hides nothing a caller needs (repo rule 3).
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'; }  # allow-suppress

# --- args ------------------------------------------------------------------
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,30p' "$0"; finish dry-run 0 ;;
        *) printf 'unknown argument: %s\n' "$arg" >&2; finish failed-usage 64 ;;
    esac
done

# --- preflight -------------------------------------------------------------
section "Preflight"
command -v apt-get >/dev/null || finish failed-unsupported:no-apt 1
UV="$(command -v uv || echo "$HOME/.local/bin/uv")"
[ -x "$UV" ] || finish failed-unsupported:no-uv 1
note "apt-get: $(command -v apt-get)"
note "uv:      $UV ($("$UV" --version))"
note "venv:    $VENV"

# --- apt tier --------------------------------------------------------------
# Idempotent by construction: query dpkg first, install only what is missing.
section "APT packages (${#APT_PKGS[@]})"
MISSING=()
for p in "${APT_PKGS[@]}"; do
    if pkg_installed "$p"; then
        note "present: $p"
    else
        note "MISSING: $p"
        MISSING+=("$p")
    fi
done

if [ "$DRY_RUN" -eq 1 ]; then
    section "Dry run — nothing was installed"
    note "would apt-get install: ${MISSING[*]:-<none, all present>}"
    note "would create venv:     $VENV"
    note "would install into it: frida-tools (upgrade if present)"
    finish dry-run 0
fi

if [ "${#MISSING[@]}" -gt 0 ]; then
    sudo apt-get update
    sudo apt-get install -y "${MISSING[@]}"
else
    note "nothing to install"
fi

# Verify by RE-QUERY, not by the installer's exit code — the whole point of
# the reporting contract is that "the command returned 0" is not evidence.
APT_OK=0
for p in "${APT_PKGS[@]}"; do
    if pkg_installed "$p"; then
        APT_OK=$((APT_OK + 1))
    else
        note "NOT INSTALLED after apt run: $p"
    fi
done
note "verified $APT_OK/${#APT_PKGS[@]} packages installed"

# --- frida venv (PEP 668) --------------------------------------------------
# /usr/lib/python3.13/EXTERNALLY-MANAGED blocks a bare `pip install`, and there
# is no python3-frida in apt, so frida-tools lives in its own venv.
#
# NOTE: `uv venv` does NOT put a `uv` binary inside the venv (verified,
# uv 0.11.32) — so `$VENV/bin/uv pip install ...` cannot work. Drive the venv
# from the OUTER uv with `--python`.
section "frida-tools venv"
VENV_STATE=failed
if [ ! -x "$VENV/bin/python" ]; then
    "$UV" venv "$VENV" || finish "partial:apt=$APT_OK/${#APT_PKGS[@]}:venv=failed-create" 1
else
    note "venv already exists"
fi

if "$UV" pip install --python "$VENV/bin/python" --upgrade frida-tools; then
    # Verify by importing + running, not by pip's exit code.
    if "$VENV/bin/python" -c 'import frida; print("frida", frida.__version__)'; then
        VENV_STATE=ok
    else
        note "frida installed but does not import"
        VENV_STATE=failed-import
    fi
else
    VENV_STATE=failed-install
fi

# --- post-install verification --------------------------------------------
# Advisory only: these print what the tools actually report so the two claims
# tool-shelf.md marks UNVERIFIED can be settled here rather than assumed.
section "Verify (advisory — read the output, do not assume)"
command -v radare2 >/dev/null && note "radare2: $(radare2 -v | head -1)"
command -v binwalk >/dev/null && note "binwalk: $(binwalk --help 2>&1 | head -1)"
command -v gdb-multiarch >/dev/null && \
    note "gdb-multiarch archs: $(gdb-multiarch -batch -ex 'set architecture' 2>&1 | head -2 | tr '\n' ' ')"
python3 -c 'import capstone; print("    capstone", capstone.__version__)' || true
# The m68k claim is UNVERIFIED upstream — this is the check that settles it.
python3 -c 'import unicorn; print("    unicorn", unicorn.__version__, "m68k arch id", unicorn.UC_ARCH_M68K)' || \
    note "unicorn m68k NOT confirmed — do not plan a 68000 oracle on it"

section "Next"
note "./sync.sh gdb radare2 ghidra frida   # link the config dirs into \$HOME"
note "frida lives in the venv: $VENV/bin/frida (not on PATH by design)"

if [ "$APT_OK" -eq "${#APT_PKGS[@]}" ] && [ "$VENV_STATE" = ok ]; then
    finish "ok:apt=$APT_OK/${#APT_PKGS[@]}:venv=ok" 0
fi
finish "partial:apt=$APT_OK/${#APT_PKGS[@]}:venv=$VENV_STATE" 1
