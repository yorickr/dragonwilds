# Contributing

## Local setup

Tooling is pinned in `mise.toml` ([mise](https://mise.jdx.dev)); `mise install`
fetches `bats`, `shellcheck` and `hadolint`. Docker is needed for the
integration suite.

```sh
mise install
mise run lint              # shellcheck + hadolint
mise run test:unit         # bats, no Docker needed
mise run test:integration  # builds the image, runs container tests
mise run test              # unit + integration
mise run build             # docker build -t dragonwilds:test .
```

## What CI enforces

`.github/workflows/ci.yml` runs on every push to `main` and every pull request,
and must pass before a release tag publishes anything:

- **lint** — `shellcheck` over `entrypoint.sh` and the test scripts, `hadolint`
  over both Dockerfiles.
- **unit** — the `bats` suite in `tests/unit`, which sources `entrypoint.sh` and
  exercises its functions directly.
- **integration** — `tests/integration/run.sh`, which builds the image and runs a
  container against a stub server, asserting config rendering, idle pause, UDP
  wake, shutdown signal order, the `OWNER_ID` guard, and opt-in interval backups.
  The real game is never downloaded.

## Notes

- `entrypoint.sh` is sourceable: everything lives in functions and `main "$@"`
  is guarded by `[[ "${BASH_SOURCE[0]}" == "$0" ]]`. Keep it that way, and keep
  paths injectable (`INSTALL_DIR`, `STEAMCMD`, `PROC_NET_UDP`, `SYS_CLASS_NET`,
  `LOG_FILE`) so tests can point them at fixtures.
- Releases are cut by pushing a `vX.Y.Z` tag. No secrets to configure — the
  workflow pushes to GHCR with `GITHUB_TOKEN`.
