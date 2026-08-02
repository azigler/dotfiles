#!/usr/bin/env bash
# mac.upgrade.sh — upgrade every off-the-shelf binary on a WORKSTATION Mac.
#
# The macOS-workstation counterpart to ubuntu.upgrade.sh (Linux) and
# pico.upgrade.sh (the headless macOS server). Run it ON the Mac:
#
#   bash ~/dotfiles/mac.upgrade.sh              # everything
#   bash ~/dotfiles/mac.upgrade.sh --dry-run    # print, don't run
#   bash ~/dotfiles/mac.upgrade.sh --list       # section names
#   bash ~/dotfiles/mac.upgrade.sh --only brew --only gitleaks
#
# Before this existed, the Mac's only upgrade path was the no-argument branch of
# download.sh, which ran binary upgrades AND THEN every destructive vendor case —
# you could not have one without the other (bead dotfiles-7bij). download.sh is
# now a pure vendor/fetch script; upgrades live here.
#
# ── Deliberate divergences from ubuntu.upgrade.sh ────────────────────────────
#
# * `set -uo pipefail`, NOT `-euo`. ubuntu.upgrade.sh uses `-e`, which means one
#   flaky network call aborts the other 18 tools. pico.upgrade.sh already
#   dropped it for that reason; this follows pico. Every section reports its own
#   failure via fail() and the run continues.
#
# * NO `grep -oP`. BSD grep on macOS has no `-P`; the ubuntu script's
#   `grep -oP '"tag_name"...'` idiom exits 2 here. Parsing is `sed`-only so it
#   needs no jq either.
#
# * `shasum -a 256`, not `sha256sum` (which does not exist on macOS).
#
# * gitleaks assets are `darwin_arm64` / `darwin_x64`, NOT `linux_x64`.
#   Copying the ubuntu line verbatim downloads an ELF binary that cannot run.
#   (goose's own download_cli.sh IS arch-aware, so that one line ports as-is —
#   verified: it selects goose-aarch64-apple-darwin on this box.)
#
# * agentgateway / agctl are NOT installed here. This Mac neither serves the
#   gateway nor is gateway-routed (no ~/.zig.zshenv), so there is nothing to
#   upgrade and a client binary would just rot. Omitted on purpose — if that
#   ever changes, port the section from ubuntu.upgrade.sh INCLUDING its
#   prerelease comment (/releases/latest silently serves betas).
#
# ── Hazards this script warns about rather than papering over ────────────────
#
# * THIRD-PARTY TAPS ARE SILENTLY EXCLUDED FROM `brew upgrade`. Homebrew 6
#   refuses to load formulae from untrusted taps. With no ~/.homebrew/trust.json,
#   `brew outdated` prints NOTHING and exits 0 while bv, yabai, skhd, sketchybar
#   and borders never update. Measured on this box 2026-08-01:
#     $ brew outdated --verbose                      -> (empty), rc=0
#     $ brew outdated --verbose dicklesworthstone/tap/bv
#       dicklesworthstone/tap/bv (0.13.0) < 0.18.0   -> a REAL pending upgrade
#     $ brew outdated bv
#       Error: Refusing to load formula ... from untrusted tap
#   A clean exit code here is not evidence of currency — it is evidence that
#   brew declined to look. See the `brew` section; `--trust-taps` opts in.
#
# * tmux. A `brew upgrade` swaps the binary but the RUNNING server keeps the old
#   one until every session dies. Measured 2026-08-01: a fresh 3.7b client
#   attached to a live 3.6a server without complaint, so this is a warning, not
#   a gate. Zig lives in tmux over SSH and the durable pulse windows hold
#   sessions for days — the drift is normal and safe, but it is real.
#
# * brew services bounce on upgrade (yabai, skhd, sketchybar, borders, and
#   tailscale/ollama where installed). The script reports any that come back in
#   `error`, and cross-checks launchd directly, because `brew services list` is
#   itself blinded by the untrusted-tap refusal above.
#
# * `claude update` is skipped by default when CLAUDECODE=1 — this script is
#   frequently run from inside a live Claude Code session, and swapping the
#   running binary underneath it is not a thing to do silently. `--claude` forces.
#
# * bv is DUAL-MANAGED and the two copies disagree. mac.setup.sh installs
#   dicklesworthstone/tap/bv via brew (0.13.0 at /opt/homebrew/bin/bv) while the
#   upstream installer writes ~/.local/bin/bv (0.18.0) — and brew's copy wins on
#   PATH, so every `bv` invocation on this box has been running five minors
#   behind whatever the installer last fetched.
#   DECISION: the upstream curl installer is canonical, and brew's copy should be
#   removed. Not because the tap is stale — it is not; it carries 0.18.0 — but
#   because (a) `br` is already curl-installed here, into the same ~/.local/bin,
#   so this makes br and bv agree, (b) ubuntu.upgrade.sh and pico.upgrade.sh both
#   use the curl installer, so the fleet gets one manager for beads instead of
#   two, and (c) the brew path is the one with the silent-freeze failure mode
#   above — it is how bv sat at 0.13.0 unnoticed.
#   This script installs via curl and then FAILS LOUDLY if the brew copy is still
#   shadowing it. It does not pretend the upgrade took effect.

set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; DIM='\033[2m'; NC='\033[0m'
section() { echo ""; echo -e "${GREEN}==> $1${NC}"; }
warn()    { echo -e "${YELLOW}  ⚠ $1${NC}"; }
fail()    { echo -e "${RED}  ✗ $1${NC}"; FAILURES=$((FAILURES + 1)); }
ok()      { echo -e "  ✓ $1"; }
skip()    { echo -e "${DIM}  – $1${NC}"; }

FAILURES=0
DRY_RUN=0
DO_CASKS=0
DO_TRUST=0
FORCE_CLAUDE=0
ONLY=()

# brew and ~/.local/bin are not guaranteed on a non-interactive PATH. APPEND the
# missing ones rather than prepending: prepending ~/.local/bin put a second,
# hermes-managed npm ahead of nvm's and the node/globals sections then reported
# on a node install the user never uses. Only add what is genuinely absent.
for _d in /opt/homebrew/bin /opt/homebrew/sbin "$HOME/.local/bin" "$HOME/.bun/bin" "$HOME/.cargo/bin"; do
    case ":$PATH:" in *":$_d:"*) ;; *) PATH="$PATH:$_d" ;; esac
done
export PATH
export HOMEBREW_NO_ENV_HINTS=1

# run  — a single command in argv form
# runs — a shell snippet (pipelines / redirects)
# Both are no-ops that print themselves under --dry-run, so every section below
# is safe to exercise end-to-end without touching the machine.
run()  { if [ "$DRY_RUN" -eq 1 ]; then echo -e "${DIM}  [dry-run] $*${NC}"; return 0; fi; "$@"; }
runs() { if [ "$DRY_RUN" -eq 1 ]; then echo -e "${DIM}  [dry-run] $1${NC}"; return 0; fi; eval "$1"; }

SECTIONS=(brew tmux rust bun deno pnpm uv node claude cursor beads biome ruff
          golangci-lint gitleaks goose omz nix js-globals)

usage() {
    sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; $d'
    echo "Sections: ${SECTIONS[*]}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1 ;;
        --casks)      DO_CASKS=1 ;;
        --trust-taps) DO_TRUST=1 ;;
        --claude)     FORCE_CLAUDE=1 ;;
        --only)       shift; ONLY+=("${1:-}") ;;
        --list)       echo "${SECTIONS[*]}"; exit 0 ;;
        -h|--help)    usage; exit 0 ;;
        *)            echo "unknown option: $1" >&2; echo "try --help" >&2; exit 2 ;;
    esac
    shift
done

wanted() {
    [ ${#ONLY[@]} -eq 0 ] && return 0
    local s; for s in "${ONLY[@]}"; do [ "$s" = "$1" ] && return 0; done
    return 1
}

# A typo'd --only that runs nothing and exits 0 is the same silent-no-op class of
# defect this script exists to surface. Reject unknown names.
for o in "${ONLY[@]:-}"; do
    [ -z "$o" ] && continue
    printf '%s\n' "${SECTIONS[@]}" | grep -qxF "$o" || {
        echo "unknown section: $o" >&2
        echo "known sections: ${SECTIONS[*]}" >&2
        exit 2
    }
done

# Newest release tag for a GitHub repo, without grep -oP and without jq.
latest_tag() {
    curl -fsSL "https://api.github.com/repos/$1/releases/latest" \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# --- Homebrew -----------------------------------------------------------------
sec_brew() {
    section "Homebrew"
    if ! command -v brew &>/dev/null; then
        fail "brew not found at /opt/homebrew/bin/brew — install it first (mac.setup.sh)"
        return
    fi

    # Untrusted taps are excluded from `brew outdated` / `brew upgrade` WITHOUT
    # a non-zero exit. Probe each INSTALLED third-party formula by FULL name and
    # compare against what bare `brew outdated` admits to — the gap is exactly
    # the set of upgrades `brew upgrade` will silently decline to perform.
    # A tap with nothing installed from it cannot cause a missed upgrade.
    # HOMEBREW_NO_AUTO_UPDATE for the probes only: brew's "==> Auto-updating
    # Homebrew..." banner goes to stderr and otherwise lands in the report as a
    # bogus "frozen" entry. The real `brew update` still runs below.
    local bare untrusted=() blocked=() t f out
    bare=$(HOMEBREW_NO_AUTO_UPDATE=1 brew outdated --verbose)
    for f in $(brew list --formula --full-name | grep '/' || true); do
        out=$(HOMEBREW_NO_AUTO_UPDATE=1 brew outdated --verbose "$f" 2>&1)
        if echo "$out" | grep -qiE 'trust|No available formula'; then
            untrusted+=("${f%/*}")
        elif [ -n "$out" ] && ! echo "$bare" | grep -qF "$f"; then
            untrusted+=("${f%/*}")
            # keep only the "name (old) < new" lines
            blocked+=("$(echo "$out" | grep -E '^[^ ]+ \(.*\) < ' | tr '\n' ' ')")
        fi
    done
    if [ ${#untrusted[@]} -gt 0 ]; then
        # shellcheck disable=SC2207
        untrusted=($(printf '%s\n' "${untrusted[@]}" | sort -u))
        if [ "$DO_TRUST" -eq 1 ]; then
            for t in "${untrusted[@]}"; do
                run brew trust --tap "$t" && ok "trusted $t"
            done
        else
            fail "${#untrusted[@]} third-party tap(s) are UNTRUSTED: ${untrusted[*]}"
            warn "Homebrew 6 refuses to load formulae from an untrusted tap, so"
            warn "\`brew outdated\` prints NOTHING for them and \`brew upgrade\` skips"
            warn "them — both exiting 0. A clean run is not evidence of currency."
            for out in "${blocked[@]:-}"; do
                [ -n "$out" ] && warn "  frozen: $out"
            done
            warn "Fix: bash mac.upgrade.sh --trust-taps   (or: brew trust --tap <tap>)"
        fi
    else
        ok "no untrusted taps blocking upgrades"
    fi

    # A formula rename left unmigrated makes EVERY later brew command error out,
    # aborting the whole upgrade over an unrelated package. Clear those first.
    for f in $(brew outdated 2>&1 | sed -n 's/^Error: \(.*\) was renamed to .*/\1/p'); do
        warn "migrating renamed formula: $f"
        run brew migrate "$f" || warn "migrate failed for $f"
    done

    run brew update || fail "brew update failed"
    run brew upgrade || fail "brew upgrade failed"
    if [ "$DO_CASKS" -eq 1 ]; then
        # OPT-IN, and it stays opt-in: a cask upgrade force-quits the running
        # GUI app. On a workstation that can take a browser, an editor, or the
        # terminal this script is running in. Casks are a deliberate, attended act.
        run brew upgrade --cask --greedy || fail "brew cask upgrade failed"
    else
        skip "casks not upgraded (pass --casks; they force-quit running GUI apps)"
    fi
    run brew cleanup -s || warn "brew cleanup failed"
    ok "brew formulae upgraded"

    # brew upgrade restarts services. Report any that came back broken. Note
    # `brew services list` is itself blinded by the untrusted-tap refusal above
    # (it printed an empty list here while two homebrew.mxcl jobs were loaded),
    # so cross-check launchd directly.
    local broken
    broken=$(brew services list | awk 'NR>1 && $2=="error" {print $1}')
    if [ -n "$broken" ]; then
        fail "brew services in error after upgrade: $(echo "$broken" | tr '\n' ' ')"
        warn "check with: brew services list"
    else
        ok "no brew services reporting error"
    fi
    local jobs
    jobs=$(launchctl list | awk '$3 ~ /^homebrew\.mxcl\.|^com\.koekeishiya\./ {print $3" (rc="$2")"}')
    if [ -n "$jobs" ]; then
        echo "  launchd jobs that a brew upgrade can bounce:"
        echo "$jobs" | sed 's/^/    /'
        warn "if any shows a non-zero rc, restart it (yabai --restart-service,"
        warn "skhd --restart-service, brew services restart <name>)"
    fi
}

# --- tmux ---------------------------------------------------------------------
sec_tmux() {
    section "tmux (binary vs. running server)"
    if ! command -v tmux &>/dev/null; then skip "tmux not installed"; return; fi
    local binv srvv
    binv=$(tmux -V | awk '{print $2}')
    srvv=$(tmux display-message -p '#{version}' 2>&1)
    if [ -z "$srvv" ] || [[ "$srvv" == *"no server"* ]] || [[ "$srvv" == *"error"* ]]; then
        ok "binary $binv; no server running, nothing to drift"
        return
    fi
    if [ "$binv" = "$srvv" ]; then
        ok "binary $binv == running server $srvv"
    else
        warn "binary is $binv but the RUNNING SERVER is still $srvv"
        warn "The server keeps its old binary until every session exits. Measured"
        warn "2026-08-01: a 3.7b client attached to a live 3.6a server fine, so this"
        warn "is drift, not breakage. To adopt the new binary you must kill the"
        warn "server (tmux kill-server) — which ends every window, including the"
        warn "durable pulse sessions. Do it deliberately, not as a side effect."
    fi
}

# --- Rust ---------------------------------------------------------------------
sec_rust() {
    section "Rust toolchain"
    # bash/.profile sources ~/.cargo/env and sync.sh links cargo/config.toml, but
    # rustup has never actually been installed on this Mac — so both are dead
    # references. Install-on-missing, same as ubuntu.upgrade.sh.
    if command -v rustup &>/dev/null; then
        run rustup update && ok "rustup updated (rustfmt + clippy come along)"
    else
        warn "rustup not found, installing"
        runs "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y" \
            && ok "rustup installed" || fail "rustup install failed"
    fi
}

sec_bun() {
    section "Bun"
    if command -v bun &>/dev/null; then
        run bun upgrade && ok "bun current" || fail "bun upgrade failed"
    else
        warn "bun not found, reinstalling"
        runs "curl -fsSL https://bun.sh/install | bash" || fail "bun install failed"
    fi
}

sec_deno() {
    section "Deno"
    if command -v deno &>/dev/null; then
        run deno upgrade && ok "deno current" || fail "deno upgrade failed"
    else
        skip "deno not installed on this box"
    fi
}

sec_pnpm() {
    section "pnpm"
    if ! command -v pnpm &>/dev/null; then skip "pnpm not installed"; return; fi
    # pnpm here comes from brew, and `pnpm self-update` on a brew-managed pnpm
    # fights the package manager. Let brew own it.
    if [ -x /opt/homebrew/bin/pnpm ] && [ "$(command -v pnpm)" = /opt/homebrew/bin/pnpm ]; then
        ok "pnpm is brew-managed — already covered by the brew section"
    else
        run pnpm self-update && ok "pnpm updated" || fail "pnpm self-update failed"
    fi
}

sec_uv() {
    section "uv + uv tools"
    if command -v uv &>/dev/null; then
        run uv self update && ok "uv updated" || fail "uv self update failed"
        run uv tool upgrade --all && ok "uv tools upgraded" || fail "uv tool upgrade failed"
    else
        warn "uv not found, reinstalling"
        runs "curl -LsSf https://astral.sh/uv/install.sh | sh" || fail "uv install failed"
    fi
}

# --- Node -----------------------------------------------------------------
sec_node() {
    section "Node (report only)"
    # Deliberately NOT upgraded. There are two node installs on this box — nvm's
    # (~/.nvm/versions/node/...) and a hermes-managed one symlinked from
    # ~/.local/bin — and which one wins depends on shell rc order. Bumping node
    # under a global package set that was installed against a different one is
    # how you get half-broken CLIs. Report, don't guess.
    if command -v node &>/dev/null; then
        ok "node $(node --version) at $(command -v node)"
        ok "npm  $(npm --version 2>/dev/null || echo '?') at $(command -v npm)"
        [ -d "$HOME/.nvm" ] && warn "nvm is present; upgrade node deliberately with \`nvm install --lts\`"
    else
        skip "node not on PATH"
    fi
}

sec_claude() {
    section "Claude Code"
    if [ "${CLAUDECODE:-0}" = "1" ] && [ "$FORCE_CLAUDE" -ne 1 ]; then
        skip "running INSIDE a Claude Code session (CLAUDECODE=1) — not swapping the"
        skip "  live binary. Re-run outside the session, or pass --claude to force."
        return
    fi
    if command -v claude &>/dev/null; then
        run claude update && ok "claude current" || {
            warn "claude update failed, reinstalling via installer"
            runs "curl -fsSL https://claude.ai/install.sh | bash" || fail "claude install failed"
        }
    else
        warn "claude not found, reinstalling"
        runs "curl -fsSL https://claude.ai/install.sh | bash" || fail "claude install failed"
    fi
}

sec_cursor() {
    section "cursor-agent"
    runs "curl https://cursor.com/install -fsS | bash" \
        && ok "cursor-agent current" || fail "cursor install script failed"
}

# --- beads --------------------------------------------------------------------
sec_beads() {
    section "beads_rust (br) + beads_viewer (bv)"
    runs "curl -fsSL 'https://raw.githubusercontent.com/Dicklesworthstone/beads_rust/main/install.sh?$(date +%s)' | bash" \
        && ok "br -> $(br --version 2>/dev/null || echo '?')" || fail "beads_rust install failed"

    runs "curl -fsSL 'https://raw.githubusercontent.com/Dicklesworthstone/beads_viewer/main/install.sh?$(date +%s)' | bash" \
        || fail "beads_viewer install failed"

    # The installer writes ~/.local/bin/bv. mac.setup.sh ALSO brew-installs
    # dicklesworthstone/tap/bv, and /opt/homebrew/bin comes first on PATH — so
    # without this check the upgrade above is a silent no-op for every caller.
    local resolved local_bv
    resolved=$(command -v bv || true)
    local_bv="$HOME/.local/bin/bv"
    if [ -z "$resolved" ]; then
        fail "bv not on PATH after install"
    elif [ "$resolved" != "$local_bv" ] && [ -x "$local_bv" ]; then
        fail "bv is DUAL-MANAGED and the wrong copy wins:"
        warn "  PATH resolves to $resolved ($("$resolved" --version 2>/dev/null || echo '?'))"
        warn "  just-upgraded copy $local_bv ($("$local_bv" --version 2>/dev/null || echo '?'))"
        warn "The brew copy is frozen behind Homebrew's untrusted-tap gate, so it"
        warn "will not catch up on its own. Pick one manager — the curl installer:"
        warn "  brew uninstall bv    (then re-run this script)"
    else
        ok "bv -> $("$resolved" --version 2>/dev/null || echo '?') at $resolved"
    fi
}

sec_biome() {
    section "Biome"
    if ! command -v bun &>/dev/null; then fail "bun not found, cannot manage biome"; return; fi
    run bun install -g @biomejs/biome && ok "biome $(biome --version 2>/dev/null || echo installed)" \
        || fail "biome install failed"
}

sec_ruff() {
    section "Ruff"
    if ! command -v uv &>/dev/null; then fail "uv not found, cannot manage ruff"; return; fi
    if command -v ruff &>/dev/null; then
        run uv tool upgrade ruff && ok "ruff upgraded" || fail "ruff upgrade failed"
    else
        warn "ruff not found, installing"
        run uv tool install ruff && ok "ruff installed" || fail "ruff install failed"
    fi
}

sec_golangci_lint() {
    section "golangci-lint"
    runs "curl -sSfL https://golangci-lint.run/install.sh | sh -s -- -b \"$HOME/.local/bin\"" \
        && ok "golangci-lint $(golangci-lint --version 2>/dev/null | head -1)" \
        || fail "golangci-lint install failed"
}

# --- gitleaks -----------------------------------------------------------------
sec_gitleaks() {
    section "gitleaks"
    # darwin assets, NOT linux_x64. Verified against the release listing:
    #   gitleaks_<ver>_darwin_arm64.tar.gz / gitleaks_<ver>_darwin_x64.tar.gz
    local arch
    case "$(uname -m)" in
        arm64|aarch64) arch=arm64 ;;
        x86_64)        arch=x64 ;;
        *)             fail "unsupported arch $(uname -m)"; return ;;
    esac
    local tag
    tag=$(latest_tag gitleaks/gitleaks)
    if [ -z "$tag" ]; then fail "could not resolve latest gitleaks tag"; return; fi
    local url="https://github.com/gitleaks/gitleaks/releases/download/${tag}/gitleaks_${tag#v}_darwin_${arch}.tar.gz"
    echo "  $tag -> $(basename "$url")"
    mkdir -p "$HOME/.local/bin"
    runs "curl -fsSL '$url' | tar xz -C \"\$HOME/.local/bin\" gitleaks && chmod +x \"\$HOME/.local/bin/gitleaks\"" \
        && ok "gitleaks $(gitleaks version 2>/dev/null || echo "$tag")" \
        || fail "gitleaks download/extract failed"
}

sec_goose() {
    section "goose"
    # download_cli.sh is arch-aware (it resolves goose-aarch64-apple-darwin here),
    # so this is the one ubuntu line that ports verbatim.
    runs "curl -fsSL https://github.com/block/goose/releases/download/stable/download_cli.sh | CONFIGURE=false bash" \
        && ok "goose $(goose --version 2>/dev/null | tr -d ' ')" || fail "goose install failed"
}

sec_omz() {
    section "Oh My Zsh"
    local omz="${ZSH:-$HOME/.oh-my-zsh}"
    if [ -d "$omz" ]; then
        run env ZSH="$omz" zsh "$omz/tools/upgrade.sh" && ok "oh-my-zsh current" \
            || fail "oh-my-zsh upgrade failed"
    else
        warn "Oh My Zsh not found at $omz"
    fi
}

sec_nix() {
    section "Nix + nix-direnv"
    if ! command -v nix &>/dev/null; then
        # Deliberately NOT auto-installed: the macOS installer is a multi-user
        # daemon install that repartitions a synthetic volume and needs sudo.
        # That is a setup decision, not an upgrade.
        skip "nix not installed on this box — mac.setup.sh owns that install"
        return
    fi
    run sudo -n /nix/var/nix/profiles/default/bin/nix-channel --update \
        && ok "nix channels updated" || warn "nix-channel update needs an interactive sudo; skipped"
    run nix --extra-experimental-features nix-command \
            --extra-experimental-features flakes profile upgrade nix-direnv \
        && ok "nix-direnv upgraded" || fail "nix-direnv upgrade failed"
}

# --- JS CLI globals -----------------------------------------------------------
sec_js_globals() {
    section "JS CLI globals"
    # UPGRADE what is installed; do NOT silently install new tools during an
    # upgrade run. ubuntu.upgrade.sh bun-installs the whole set unconditionally,
    # which on this Mac would create a SECOND copy of packages npm already owns
    # (vercel, wrangler) and shadow them unpredictably.
    local pkgs=(@google/gemini-cli @openai/codex @github/copilot vercel wrangler)
    local npm_root bun_root npm_list p handled
    if command -v npm &>/dev/null; then
        npm_root=$(npm root -g)
        echo "  npm  $(command -v npm) -> $npm_root"
    else
        npm_root=""
        warn "npm not on PATH"
    fi
    bun_root="$HOME/.bun/install/global/node_modules"
    [ -d "$bun_root" ] && echo "  bun  global root -> $bun_root"

    npm_list=$([ -n "$npm_root" ] && ls -d "$npm_root"/*/ "$npm_root"/@*/*/ 2>/dev/null | sed "s#^$npm_root/##; s#/\$##")

    for p in "${pkgs[@]}"; do
        handled=0
        if echo "$npm_list" | grep -qxF "$p"; then
            run npm install -g "$p@latest" && ok "npm: $p" || fail "npm: $p failed"
            handled=1
        fi
        if [ -d "$bun_root/$p" ]; then
            run bun install -g "$p" && ok "bun: $p" || fail "bun: $p failed"
            handled=1
        fi
        [ "$handled" -eq 0 ] && skip "$p not installed here (install deliberately, then it upgrades)"
    done

    # Globals belong to ONE node install. This box has several (nvm has two
    # versions, plus a hermes-managed node symlinked into ~/.local/bin), and only
    # whichever `npm` wins on PATH was upgraded above. Name the strays instead of
    # leaving stale copies to shadow the fresh ones.
    local root stray
    for root in "$HOME"/.nvm/versions/node/*/lib/node_modules "$HOME"/.hermes/node/lib/node_modules; do
        [ -d "$root" ] || continue
        [ "$root" = "$npm_root" ] && continue
        stray=""
        for p in "${pkgs[@]}"; do [ -d "$root/$p" ] && stray="$stray $p"; done
        [ -n "$stray" ] && warn "NOT upgraded (different node install) $root:$stray"
    done
}

# --- dispatch -----------------------------------------------------------------
for s in "${SECTIONS[@]}"; do
    wanted "$s" || continue
    "sec_${s//-/_}"
done

section "Done"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry run — nothing was changed."
elif [ "$FAILURES" -eq 0 ]; then
    echo "All upgrades complete."
else
    echo -e "${RED}${FAILURES} section(s) reported a problem — scroll up for the ✗ lines.${NC}"
fi
echo ""
echo "NOT touched here: download.sh's vendored resources (run ./download.sh <dir>),"
echo "GUI casks (--casks), node/nvm, and anything under a bespoke deploy path."
exit $([ "$FAILURES" -eq 0 ] && echo 0 || echo 1)
