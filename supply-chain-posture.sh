#!/usr/bin/env bash
#
# supply-chain-posture.sh — audit (and optionally fix) JS package-manager
# supply-chain hardening for npm / pnpm / yarn.
#
#   curl -fsSL <url> | bash                 # audit only (read-only, safe)
#   curl -fsSL <url> | bash -s -- --fix     # apply the low-risk fixes
#   curl -fsSL <url> | bash -s -- --help    # usage
#
# SAFETY: piping a script to bash is itself a supply-chain risk. Read this file
# before running it. Default mode changes NOTHING — it only reports. Fixes are
# applied only with --fix, are idempotent, and are limited to package-manager
# config files (never your source, never your lockfile).
#
# What it checks:
#   1. Tooling version floor (npm >=11.10, pnpm >=10.16 — older = settings no-op)
#   2. Minimum release age / version cooldown (npm/pnpm/yarn)
#   3. Install-script blocking (npm ignore-scripts; pnpm allowlist; yarn)
#   4. Lockfile present (and not a mixed-PM repo)
#   5. Registry is the official one over HTTPS
#   6. No auth tokens in git-tracked config files
#   7. packageManager field pinned (corepack)
#   8. GitHub Actions pinned to a full commit SHA
#
# Exit code: 0 if no failures, 1 if any FAIL-level finding (CI-friendly).

set -o pipefail

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
FIX=0            # --fix          apply low-risk fixes (cooldown, etc.)
BLOCK_SCRIPTS=0  # --block-scripts also enable npm/yarn install-script blocking
GLOBAL=0         # --global       also audit/fix user-global config
DAYS=7           # --days N       cooldown length (default 7)
USE_COLOR=1

while [ $# -gt 0 ]; do
  case "$1" in
    --fix) FIX=1 ;;
    --block-scripts) BLOCK_SCRIPTS=1 ;;
    --global) GLOBAL=1 ;;
    --days) shift; DAYS="${1:-7}" ;;
    --days=*) DAYS="${1#*=}" ;;
    --no-color) USE_COLOR=0 ;;
    -h|--help)
      sed -n '2,33p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

case "$DAYS" in ''|*[!0-9]*) echo "--days must be a positive integer" >&2; exit 2 ;; esac
MINUTES=$(( DAYS * 1440 ))   # pnpm & yarn want minutes

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [ "$USE_COLOR" = 1 ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_R=$'\033[0m'
else
  C_OK=; C_WARN=; C_BAD=; C_DIM=; C_B=; C_R=
fi

PASS=0; WARN=0; FAIL=0; FIXED=0
ok()    { PASS=$((PASS+1));  printf '  %s✓%s %s\n' "$C_OK" "$C_R" "$1"; }
warn()  { WARN=$((WARN+1));  printf '  %s⚠%s %s\n' "$C_WARN" "$C_R" "$1"; }
bad()   { FAIL=$((FAIL+1));  printf '  %s✗%s %s\n' "$C_BAD" "$C_R" "$1"; }
info()  {                    printf '  %sℹ%s %s\n' "$C_DIM" "$C_R" "$1"; }
fixed() { FIXED=$((FIXED+1)); printf '    %s↳ fixed:%s %s\n' "$C_OK" "$C_R" "$1"; }
section(){ printf '\n%s%s%s\n' "$C_B" "$1" "$C_R"; }

have()  { command -v "$1" >/dev/null 2>&1; }
# ver_ge A B -> 0 (true) if version A >= B
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V 2>/dev/null | head -n1)" = "$2" ]; }
# file_has FILE REGEX -> 0 if FILE exists and a non-comment line matches REGEX
file_has() { [ -f "$1" ] && grep -Eq "$2" "$1" 2>/dev/null; }

# Append a "key: value" / "key=value" line to a config file iff the key is absent.
# add_line FILE KEY-REGEX FULL-LINE
add_line() {
  local file="$1" key="$2" line="$3"
  [ -f "$file" ] || { mkdir -p "$(dirname "$file")" 2>/dev/null; : > "$file"; }
  if grep -Eq "$key" "$file" 2>/dev/null; then return 1; fi
  printf '%s\n' "$line" >> "$file"
  return 0
}

NPMRC_USER="$(npm config get userconfig 2>/dev/null)"; [ -n "$NPMRC_USER" ] && [ "$NPMRC_USER" != "undefined" ] || NPMRC_USER="$HOME/.npmrc"
case "$(uname -s)" in
  Darwin) PNPM_GLOBAL_CFG="$HOME/Library/Preferences/pnpm/config.yaml" ;;
  *)      PNPM_GLOBAL_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/pnpm/rc" ;;
esac

printf '%s%s═══ supply-chain posture ═══%s  (cooldown=%sd, mode=%s)\n' \
  "$C_B" "" "$C_R" "$DAYS" "$([ "$FIX" = 1 ] && echo "FIX" || echo "audit")"

# ---------------------------------------------------------------------------
# 1. Tooling versions
# ---------------------------------------------------------------------------
section "1. Tooling"
NPM_OK=0; PNPM_OK=0
if have npm; then
  v="$(npm --version 2>/dev/null)"
  if ver_ge "$v" "11.10.0"; then ok "npm $v (supports min-release-age)"; NPM_OK=1
  else warn "npm $v — needs >=11.10.0 for min-release-age (the cooldown would no-op)"; fi
else info "npm not installed"; fi
if have pnpm; then
  v="$(pnpm --version 2>/dev/null)"
  if ver_ge "$v" "10.16.0"; then ok "pnpm $v (supports minimumReleaseAge + script allowlist)"; PNPM_OK=1
  else warn "pnpm $v — needs >=10.16.0 for minimumReleaseAge; <10 also runs dep scripts by default"; fi
fi
have yarn && info "yarn $(yarn --version 2>/dev/null) detected"
have bun  && info "bun $(bun --version 2>/dev/null) detected (configure cooldown in bunfig.toml)"

# ---------------------------------------------------------------------------
# 2. Minimum release age (version cooldown)
# ---------------------------------------------------------------------------
section "2. Version cooldown (>= ${DAYS}d)"

# -- npm. Project .npmrc travels with the repo (CI + clones); global ~/.npmrc
# only protects this one machine, so it is a weaker posture for a shared repo.
if have npm; then
  npm_glob_set=0
  file_has "$NPMRC_USER" '^[[:space:]]*min-release-age[[:space:]]*=' && npm_glob_set=1
  if [ -f "./package.json" ]; then
    if file_has "./.npmrc" '^[[:space:]]*min-release-age[[:space:]]*='; then
      ok "npm: min-release-age in project .npmrc (committed → applies in CI & clones)"
    elif [ "$FIX" = 1 ] && [ "$NPM_OK" = 1 ]; then
      npm config set min-release-age "$DAYS" --location=project >/dev/null 2>&1 && fixed "npm project min-release-age=$DAYS (./.npmrc)"
    elif [ "$npm_glob_set" = 1 ]; then
      warn "npm: cooldown only via global ~/.npmrc — not committed, so CI/teammates are unprotected${C_DIM} (fix: npm config set min-release-age $DAYS --location=project)${C_R}"
    else
      bad "npm: no min-release-age set${C_DIM} (fix: npm config set min-release-age $DAYS --location=project)${C_R}"
    fi
  fi
  if [ "$GLOBAL" = 1 ]; then
    if [ "$npm_glob_set" = 1 ]; then ok "npm: global min-release-age set ($NPMRC_USER)"
    elif [ "$FIX" = 1 ] && [ "$NPM_OK" = 1 ]; then npm config set min-release-age "$DAYS" --location=user >/dev/null 2>&1 && fixed "npm global min-release-age=$DAYS"
    else warn "npm: no global min-release-age${C_DIM} (fix: npm config set min-release-age $DAYS --location=user)${C_R}"; fi
  fi
fi

# -- pnpm (project = pnpm-workspace.yaml; minutes)
if have pnpm; then
  if file_has "./pnpm-workspace.yaml" '^[[:space:]]*minimumReleaseAge[[:space:]]*:'; then
    ok "pnpm: minimumReleaseAge set (pnpm-workspace.yaml)"
  elif [ -f "./pnpm-workspace.yaml" ] || [ -f "./package.json" ]; then
    if [ "$FIX" = 1 ] && [ "$PNPM_OK" = 1 ]; then
      add_line "./pnpm-workspace.yaml" '^[[:space:]]*minimumReleaseAge' "minimumReleaseAge: $MINUTES" && fixed "pnpm minimumReleaseAge=$MINUTES min (pnpm-workspace.yaml)"
    else
      bad "pnpm: no minimumReleaseAge in pnpm-workspace.yaml${C_DIM} (fix: add 'minimumReleaseAge: $MINUTES')${C_R}"
    fi
  fi
  if [ "$GLOBAL" = 1 ]; then
    if file_has "$PNPM_GLOBAL_CFG" '^[[:space:]]*minimumReleaseAge[[:space:]]*:'; then ok "pnpm: global minimumReleaseAge set ($PNPM_GLOBAL_CFG)"
    elif [ "$FIX" = 1 ] && [ "$PNPM_OK" = 1 ]; then
      PATH="$HOME/Library/pnpm/bin:$PATH" pnpm config set minimumReleaseAge "$MINUTES" --global >/dev/null 2>&1 \
        && fixed "pnpm global minimumReleaseAge=$MINUTES min" \
        || warn "pnpm: could not set global config automatically — run: pnpm config set minimumReleaseAge $MINUTES --global"
    else warn "pnpm: no global minimumReleaseAge${C_DIM} (fix: pnpm config set minimumReleaseAge $MINUTES --global)${C_R}"; fi
  fi
fi

# -- yarn berry (project = .yarnrc.yml; minutes)
if [ -f "./.yarnrc.yml" ] || have yarn; then
  if file_has "./.yarnrc.yml" '^[[:space:]]*npmMinimalAgeGate[[:space:]]*:'; then ok "yarn: npmMinimalAgeGate set (.yarnrc.yml)"
  elif [ "$FIX" = 1 ]; then add_line "./.yarnrc.yml" '^[[:space:]]*npmMinimalAgeGate' "npmMinimalAgeGate: $MINUTES" && fixed "yarn npmMinimalAgeGate=$MINUTES min (.yarnrc.yml)"
  else warn "yarn: no npmMinimalAgeGate (.yarnrc.yml)${C_DIM} (Berry >=4.10; fix: npmMinimalAgeGate: $MINUTES)${C_R}"; fi
fi

# ---------------------------------------------------------------------------
# 3. Install-script blocking
# ---------------------------------------------------------------------------
section "3. Install scripts"
if have npm; then
  igs="$(npm config get ignore-scripts 2>/dev/null)"
  if [ "$igs" = "true" ]; then ok "npm: ignore-scripts=true (lifecycle scripts blocked)"
  elif [ "$BLOCK_SCRIPTS" = 1 ] && [ "$FIX" = 1 ]; then
    loc=$([ "$GLOBAL" = 1 ] && echo user || echo project)
    npm config set ignore-scripts true --location="$loc" >/dev/null 2>&1 && fixed "npm ignore-scripts=true ($loc) — run 'npm rebuild <pkg>' for native builds"
  else
    warn "npm: ignore-scripts not enabled${C_DIM} (opt-in fix: --block-scripts; note: blocks native builds too)${C_R}"
  fi
fi
if have pnpm; then
  if [ "$PNPM_OK" = 1 ]; then
    if file_has "./pnpm-workspace.yaml" '^[[:space:]]*dangerouslyAllowAllBuilds[[:space:]]*:[[:space:]]*true'; then
      bad "pnpm: dangerouslyAllowAllBuilds=true — disables the dependency-script allowlist"
    else
      ok "pnpm: dependency build scripts blocked by default (allowlist via 'pnpm approve-builds')"
      file_has "./pnpm-workspace.yaml" '^[[:space:]]*onlyBuiltDependencies[[:space:]]*:' && info "pnpm: onlyBuiltDependencies allowlist present — review it stays minimal"
    fi
  else
    warn "pnpm <10 runs dependency install scripts by default — upgrade to >=10 to block them"
  fi
fi
if [ -f "./.yarnrc.yml" ]; then
  if file_has "./.yarnrc.yml" '^[[:space:]]*enableScripts[[:space:]]*:[[:space:]]*false'; then ok "yarn: enableScripts=false"
  elif [ "$BLOCK_SCRIPTS" = 1 ] && [ "$FIX" = 1 ]; then add_line "./.yarnrc.yml" '^[[:space:]]*enableScripts' "enableScripts: false" && fixed "yarn enableScripts=false (.yarnrc.yml)"
  else warn "yarn: enableScripts not disabled${C_DIM} (opt-in fix: --block-scripts)${C_R}"; fi
fi

# ---------------------------------------------------------------------------
# 4. Lockfile
# ---------------------------------------------------------------------------
section "4. Lockfile"
if [ -f "./package.json" ]; then
  locks=""
  for f in package-lock.json npm-shrinkwrap.json pnpm-lock.yaml yarn.lock bun.lockb bun.lock; do
    [ -f "./$f" ] && locks="$locks $f"
  done
  set -- $locks
  if [ "$#" -eq 0 ]; then bad "no lockfile committed — installs are non-reproducible"
  elif [ "$#" -gt 1 ]; then warn "multiple lockfiles ($*) — mixed package managers is a hazard; keep one"
  else ok "lockfile present:$locks — use frozen installs in CI (npm ci / --frozen-lockfile / --immutable)"; fi
else info "no package.json here — skipping lockfile check"; fi

# ---------------------------------------------------------------------------
# 5. Registry
# ---------------------------------------------------------------------------
section "5. Registry"
if have npm; then
  reg="$(npm config get registry 2>/dev/null)"
  case "$reg" in
    https://registry.npmjs.org/*|https://registry.npmjs.org) ok "registry: $reg" ;;
    http://*) bad "registry over plaintext HTTP: $reg — MITM risk" ;;
    "") info "registry: (unset)" ;;
    *) warn "non-default registry: $reg — confirm it is trusted (dependency-confusion risk)" ;;
  esac
fi

# ---------------------------------------------------------------------------
# 6. Committed secrets
# ---------------------------------------------------------------------------
section "6. Secrets in config"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  tracked="$(git ls-files '*.npmrc' '.npmrc' '*.yarnrc.yml' '.yarnrc.yml' '.yarnrc' 2>/dev/null)"
  found=0
  if [ -n "$tracked" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if grep -Eq '(_authToken|_password|_auth[[:space:]]*=|npmAuthToken|npmAuthIdent)' "$f" 2>/dev/null; then
        bad "credential committed in $f — rotate the token and git-ignore it"; found=1
      fi
    done <<EOF
$tracked
EOF
  fi
  [ "$found" = 0 ] && ok "no auth tokens found in git-tracked npm/yarn config"
else info "not a git repo — skipping committed-secret scan"; fi

# ---------------------------------------------------------------------------
# 7. packageManager pin
# ---------------------------------------------------------------------------
section "7. packageManager pin"
if [ -f "./package.json" ]; then
  pm=""
  if have node; then pm="$(node -e 'try{process.stdout.write(require("./package.json").packageManager||"")}catch(e){}' 2>/dev/null)"; fi
  [ -z "$pm" ] && grep -Eq '"packageManager"[[:space:]]*:' ./package.json 2>/dev/null && pm="(present)"
  if [ -n "$pm" ]; then ok "packageManager pinned: $pm"
  else warn 'no "packageManager" field — pin it (e.g. "pnpm@11.3.0") so corepack enforces one PM version'; fi
else info "no package.json here — skipping"; fi

# ---------------------------------------------------------------------------
# 8. GitHub Actions SHA pinning
# ---------------------------------------------------------------------------
section "8. GitHub Actions"
if [ -d "./.github/workflows" ]; then
  unpinned=0; total=0
  while IFS= read -r line; do
    ref="$(printf '%s' "$line" | sed -E 's/.*uses:[[:space:]]*//; s/[[:space:]"'"'"'].*//')"
    case "$ref" in
      ./*|docker://*|"") continue ;;
    esac
    total=$((total+1))
    # pinned = ...@<40-hex-sha>
    printf '%s' "$ref" | grep -Eq '@[0-9a-f]{40}$' || { unpinned=$((unpinned+1)); }
  done <<EOF
$(grep -rEh '^[[:space:]-]*uses:' ./.github/workflows 2>/dev/null)
EOF
  if [ "$total" = 0 ]; then info "no external 'uses:' actions found"
  elif [ "$unpinned" = 0 ]; then ok "all $total action refs pinned to a commit SHA"
  else warn "$unpinned/$total action refs not SHA-pinned — pin 'uses: org/repo@<40-char-sha>'"; fi
else info "no .github/workflows — skipping"; fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n%s─── summary ───%s  %s%d ok%s · %s%d warn%s · %s%d fail%s%s\n' \
  "$C_B" "$C_R" "$C_OK" "$PASS" "$C_R" "$C_WARN" "$WARN" "$C_R" "$C_BAD" "$FAIL" "$C_R" \
  "$([ "$FIXED" -gt 0 ] && printf ' · %s%d fixed%s' "$C_OK" "$FIXED" "$C_R")"
if [ "$FIX" = 0 ]; then
  printf '%srun with --fix to apply cooldown fixes, --block-scripts to also block install scripts, --global for user config%s\n' "$C_DIM" "$C_R"
fi
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
