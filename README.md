# supply-chain-posture

Audit (and optionally fix) supply-chain hardening for npm, pnpm and yarn.
One dependency-free Bash script. Read-only unless `--fix`.

## Run

```sh
curl -fsSL https://github.com/DumbMachine/supply-chain-posture/releases/latest/download/supply-chain-posture.sh | bash
```

Audits the current directory. Add `--fix` to apply fixes. Non-zero exit on any failure.

Piping to a shell runs unverified code. Prefer the verified download:

```sh
REPO=DumbMachine/supply-chain-posture VER=v0.1.0
curl -fsSLO "https://github.com/$REPO/releases/download/$VER/supply-chain-posture.sh"
curl -fsSLO "https://github.com/$REPO/releases/download/$VER/SHA256SUMS"
shasum -a 256 -c SHA256SUMS    # Linux: sha256sum -c SHA256SUMS
bash supply-chain-posture.sh --fix
```

## Checks

1. Tool versions — npm >= 11.10, pnpm >= 10.16 (older silently ignore the settings).
2. Version cooldown — install only versions published >= N days ago.
3. Install-script blocking — npm `ignore-scripts`, pnpm allowlist, yarn `enableScripts`.
4. Lockfile present, single package manager.
5. Official registry over HTTPS.
6. No auth tokens in tracked `.npmrc` / `.yarnrc`.
7. `packageManager` pinned (corepack).
8. GitHub Actions pinned to a commit SHA.

Committed (project) config protects CI and clones; global config only this machine.

## Options

```
(none)           audit only; non-zero exit on failure
--fix            apply cooldown fixes
--block-scripts  with --fix, also block install scripts (breaks native builds)
--global         also user-global config (~/.npmrc, pnpm/yarn)
--days N         cooldown length in days (default 7)
--no-color       disable ANSI color
```

## Releases

Push a `vX.Y.Z` tag. CI attaches the script and `SHA256SUMS` to the release; verify before running.

## License

MIT.
