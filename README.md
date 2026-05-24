# puppet-trace

Comprehensive Puppet run profiler. Wraps `puppet agent` or `puppet apply` with strace, perf, memory polling, and PuppetDB enrichment to produce a self-contained HTML report showing:

- Per-resource timing with disk I/O, memory delta, and peak RSS
- Memory usage chart with resource eval bands colored by status (changed/unchanged/failed/skipped)
- Parameter details for each resource
- Flamegraph of Puppet Ruby execution (via `perf` + [FlameGraph](https://github.com/brendangregg/FlameGraph))
- Puppetserver profile flamegraph (agent mode)
- Idempotency check (second run to confirm no lingering changes)
- Remote artifact shipping for report generation on another host

## Requirements

- Linux (tested on Ubuntu 22.04/24.04)
- Puppet agent installed and configured
- `strace`, `perf-tools` (`perf`), `flamegraph` (`flamegraph.pl` in PATH) — for full profiling
- Python 3 (stdlib only — no pip installs)
- Root access (strace + perf require root)
- Optional: SSH access to Puppet server for PuppetDB enrichment and profile flamegraph

## Installation

```bash
curl -Lo /usr/local/bin/puppet-trace https://raw.githubusercontent.com/grune/puppet-trace/main/puppet-trace
chmod +x /usr/local/bin/puppet-trace
```

Or clone and symlink:

```bash
git clone https://github.com/grune/puppet-trace
ln -s "$PWD/puppet-trace/puppet-trace" /usr/local/bin/puppet-trace
```

## Usage

### One-shot profiled run

```bash
sudo puppet-trace once
```

Runs `puppet agent --test --profile --evaltrace`, captures everything, generates report under `/var/log/puppet-trace/<timestamp>/`.

### Enable as postrun hook

```bash
sudo puppet-trace enable
```

Installs `puppet-trace collect` as Puppet's `postrun_command`. After each agent run, artifacts are collected and a report generated automatically.

```bash
sudo puppet-trace disable
```

### Generate report from existing artifacts

```bash
puppet-trace report /var/log/puppet-trace/20260523-164018/
# or latest run:
puppet-trace report
```

Regenerates the HTML report from saved artifacts (useful after updating puppet-trace).

### Ship artifacts to remote host

```bash
puppet-trace ship /var/log/puppet-trace/20260523-164018/ user@remote:/path/to/dest/
```

Rsyncs the artifact directory to a remote host (excluding large raw files like `strace.raw` and `perf.data` by default), then runs `puppet-trace report` on the remote.

Add `--include-strace` to include the raw strace file.

### Dry run (fixture data)

```bash
sudo puppet-trace once --dry-run
```

Generates a rich example report without running Puppet, using a 40-resource `puppet apply` fixture. Useful for testing report generation or viewing a demo.

## Output

Each run produces a directory under `/var/log/puppet-trace/<timestamp>/`:

| File | Description |
|---|---|
| `report.html` | Self-contained HTML report (open in browser) |
| `run-meta.json` | Run metadata (exit code, wall time, idempotency) |
| `io-correlation.json` | Per-resource strace correlation with timing and memory |
| `resource-report.json` | Top resources by duration (PuppetDB enriched) |
| `proc-poll.log` | Memory samples at 1s intervals |
| `puppet.log` | Full puppet output with evaltrace |
| `strace.log` | Summarized strace (file I/O and process events) |
| `strace.raw` | Raw strace output (large, excluded from ship by default) |
| `perf.data` | Raw perf data (large, excluded from ship by default) |
| `flamegraph.svg` | Puppet Ruby flamegraph |
| `puppetserver-flamegraph.svg` | Puppetserver profile flamegraph (agent mode) |

## Configuration

Environment variables (can be set before running or in `/etc/puppet-trace.conf`):

| Variable | Default | Description |
|---|---|---|
| `PUPPET_TRACE_SSH_KEY` | `~/.ssh/id_ed25519` | SSH key for PuppetDB/profile log access |
| `PUPPET_TRACE_SSH_USER` | `puppet` | SSH user on Puppet server |
| `PUPPET_TRACE_SERVER_CONTAINER` | `puppetserver` | Docker container name for Puppet server |
| `PUPPET_TRACE_PDB_CONTAINER` | `puppetdb` | Docker container name for PuppetDB |
| `PUPPET_TRACE_LOG_DIR` | `/var/log/puppet-trace` | Base directory for run artifacts |

## Report features

### Resource table

Each resource row shows:
- **Status** badge (changed / unchanged / failed / skipped)
- **Duration** in seconds
- **Disk write / read** during eval (from strace)
- **Memory Δ** — RSS change during resource eval
- **Memory peak** — peak RSS during resource eval
- **Processes** spawned (exec calls)
- **Files written** preview

Click a row to expand full detail: parameters, source file/line, memory stats, all files read/written, processes spawned.

### Memory chart

SVG chart showing RSS over the full run with:
- Colored bands for each resource eval window (green=changed, gray=unchanged, red=failed, orange=skipped)
- Reference lines for min / average / peak RSS
- Per-sample tooltips showing timestamp and RSS

### Flamegraphs

Interactively zoomable SVG flamegraphs embedded in the report.

## Example report

See [`example-report.html`](example-report.html) — generated from the `--dry-run` fixture (40-resource `puppet apply` with realistic memory curve).

## How it works

1. **Wrap**: puppet run is started under `strace -f -ttt -e trace=openat,read,write,execve,clone` + `perf record -g -p <pid>` in parallel
2. **Poll**: `proc-poll.log` captures RSS every 1 second via `/proc/<pid>/status`
3. **Correlate**: strace timestamps (float unix epoch) are joined to resource eval windows from evaltrace log
4. **Enrich**: PuppetDB REST API (via SSH to Puppet server) adds source file, line, and parameters per resource
5. **Flamegraph**: `perf script | stackcollapse-perf.pl | flamegraph.pl` → SVG
6. **Report**: single-file HTML with embedded SVGs, inline CSS/JS, no external dependencies

## License

MIT
