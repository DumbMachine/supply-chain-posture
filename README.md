# supply-chain-posture

A single, dependency-free Bash script that audits — and optionally fixes — the
supply-chain hardening of your JavaScript package managers (**npm**, **pnpm**,
**yarn**). It reports your posture and can apply the low-risk fixes for you.

The two biggest npm-ecosystem attack vectors are **freshly published malicious
versions** (caught and yanked within hours, so a release-age cooldown filters
them out) and **install/lifecycle scripts** (arbitrary code on `install`). This
tool checks both, plus the surrounding hygiene that makes them effective.

## What it checks

1. **Tooling version floor** — `min-release-age` needs npm ≥ 11.10, `minimumReleaseAge` needs pnpm ≥ 10.16. Older tools silently ignore the setting.
2. **Version cooldown** — only install versions published ≥ N days ago (npm `min-release-age`, pnpm `minimumReleaseAge`, yarn `npmMinimalAgeGate`). Distinguishes committed (project) config from machine-only (global) config.
3. **Install-script blocking** — npm `ignore-scripts`, pnpm's block-by-default dependency allowlist (`pnpm approve-builds` / `onlyBuiltDependencies`, and flags `dangerouslyAllowAllBuilds`), yarn `enableScripts`.
4. **Lockfile** — present, and not a mixed-package-manager repo.
5. **Registry** — official npm registry over HTTPS (catches rogue registries / plaintext HTTP).
6. **Committed secrets** — `_authToken` / `npmAuthToken` in a git-tracked `.npmrc` / `.yarnrc`.
7. **`packageManager` pin** — corepack pin so everyone runs the same PM version (and your hardening actually applies).
8. **GitHub Actions** — `uses:` refs pinned to a full 40-char commit SHA.

## Usage

> [!CAUTION]
> Piping any script straight into your shell is itself a supply-chain risk.
> Prefer the **verified download** below over `curl … | bash`. The script
> changes **nothing** unless you pass `--fix`.

### Verified download (recommended)

```sh
REPO=DumbMachine/supply-chain-posture
VER=v0.1.0   # pick a release tag

curl -fsSLO "https://github.com/$REPO/releases/download/$VER/supply-chain-posture.sh"
curl -fsSLO "https://github.com/$REPO/releases/download/$VER/SHA256SUMS"

shasum -a 256 -c SHA256SUMS   # macOS   (use: sha256sum -c SHA256SUMS  on Linux)

bash supply-chain-posture.sh            # audit
bash supply-chain-posture.sh --fix      # apply low-risk fixes
```

### Quick one-liner

```sh
curl -fsSL https://github.com/DumbMachine/supply-chain-posture/releases/latest/download/supply-chain-posture.sh | bash
```

### Flags

| Flag | Effect |
| --- | --- |
| *(none)* | Audit only. Read-only. Exits non-zero if any **FAIL**-level finding (CI-friendly). |
| `--fix` | Apply the low-risk fixes: version cooldown for each detected package manager. |
| `--block-scripts` | With `--fix`, also enable install-script blocking (npm `ignore-scripts=true`, yarn `enableScripts:false`). Sharper — it blocks legitimate native builds too; run `npm rebuild <pkg>` for those. |
| `--global` | Also audit/fix user-global config (`~/.npmrc`, pnpm/yarn global), not just the current project. |
| `--days N` | Cooldown length in days (default `7`). Converted to minutes for pnpm/yarn. |
| `--no-color` | Disable ANSI color. |

Project-level config (committed) protects CI and everyone who clones the repo;
global config only protects your machine — the script calls out the difference.

## Releases & integrity

Tagging `vX.Y.Z` triggers `.github/workflows/release.yml`, which attaches the
script **and** a `SHA256SUMS` file to the GitHub Release. Always verify the
checksum (see above) before executing. CI (`.github/workflows/ci.yml`) runs
`shellcheck` and a self-audit on every push. Both workflows pin
`actions/checkout` to a commit SHA — the same rule check #8 enforces.

To cut a release:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

## License

[MIT](./LICENSE)
