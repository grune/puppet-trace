# puppet-trace test suite

## Tests

| File | Type | What it covers |
|------|------|----------------|
| `test_security.bats` | bats | `_validate_puppet_id`, `_validate_safe_path`, `--outdir` injection, ISO format check, `PUPPET_SERVER` injection |
| `test_sanitize_svg.py` | pytest | `_sanitize_svg` allowlist sanitizer extracted from the script |
| `test_dry_run.bats` | bats | End-to-end dry-run: exit code, dir mode 0700, report.html presence/size, no stray files, no infra hostname leaks |

## Dependencies

```
# bats
apt install bats
# OR: https://github.com/bats-core/bats-core

# pytest
pip install pytest
# OR: apt install python3-pytest
```

## Running

```
# All tests (from repo root)
bats tests/test_security.bats
bats tests/test_dry_run.bats
pytest tests/test_sanitize_svg.py -v

# dry-run tests require sudo
sudo bats tests/test_dry_run.bats

# Quick smoke: just pytest (no sudo needed)
pytest tests/ -v
```

## Notes

- `test_security.bats` and `test_dry_run.bats` use bats-core ≥ 1.2.
- `test_sanitize_svg.py` extracts `_sanitize_svg` via regex from `scripts/puppet-trace` — no import, no subprocess.
- `test_dry_run.bats` creates `/tmp/pt-dryrun-test-$$` and cleans up in `teardown()`.
- `test_dry_run.bats` checks that report.html contains no `forge.runeg.net`, `10.0.0.*`, or `runecorps`/`runealert` strings — the fixture data uses only generic hostnames.
