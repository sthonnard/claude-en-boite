# Tests

Automated test suite for `claude-en-boite`. Run from the repo root.

## Quick start

```bash
# First time: make scripts executable
chmod +x tests/*.sh

# Run all tests (skips image build if images already exist)
./tests/run-tests.sh

# Only test the proxy (fast, no Azure credentials needed)
./tests/run-tests.sh --proxy-only

# Force-rebuild images then run all tests
./tests/run-tests.sh --force-build
```

## Test suites

| File | What it tests | Azure needed? | Network needed? |
|---|---|---|---|
| `01-install.sh` | `install-claude-podman.sh` runs; images exist; symlink created | No | Yes (pulls Alpine, npm) |
| `02-proxy.sh` | Proxy starts; blocked → 403; allowed → passthrough; hot-reload; wildcards | No | Yes (tests real HTTPS) |
| `03-launch.sh` | Script executability; symlink correct; fast-fail on missing env/token; two parallel instances | No | No |

## Options

```
./tests/run-tests.sh --force-build   # Re-run install even if images exist
./tests/run-tests.sh --skip-build    # Skip 01-install.sh
./tests/run-tests.sh --proxy-only    # Only run 02-proxy.sh
./tests/run-tests.sh 02              # Filter: only run suites matching '02'
```

## Design principles

- **No Azure credentials required** for proxy and launch tests.
- **Skip gracefully** when dependencies (podman, images, symlink) are missing.
- **No side effects** on the live `claude-proxy` container — tests use isolated containers on different ports.
- **Self-cleaning** — all test containers are removed in `trap cleanup EXIT`.
