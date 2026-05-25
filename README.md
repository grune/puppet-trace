# puppet-trace

Comprehensive Puppet run profiler. Wraps `puppet agent` or `puppet apply` with strace, perf, rbspy, memory polling, and PuppetDB enrichment to produce a self-contained HTML report showing:

- Per-resource timing with disk I/O, memory delta, and peak RSS
- Memory usage chart with resource eval bands colored by status (changed/unchanged/failed/skipped)
- Parameter details and before/after change diffs for each resource
- HTTP phase waterfall (facts prefetch → plugin sync → catalog request → apply)
- Flamegraph of Puppet Ruby execution (via `perf` + [FlameGraph](https://github.com/brendangregg/FlameGraph))
- Ruby-level flamegraph sampled by [rbspy](https://rbspy.github.io/) (if installed)
- Puppetserver profile flamegraph (agent mode)
- Idempotency check (second run to confirm no lingering changes)
- Remote artifact shipping and a central web dashboard for multi-node deployments

## Requirements

### On the agent host (where puppet-trace runs)

| Requirement | Notes |
|---|---|
| Linux (Ubuntu 22.04 / 24.04 tested) | |
| Puppet agent installed and configured | `puppet agent --test` must work |
| `strace` | `apt install strace` |
| `linux-tools-common`, `linux-tools-$(uname -r)` | provides `perf` |
| `flamegraph` scripts in `$PATH` | `flamegraph.pl`, `stackcollapse-perf.pl` from [brendangregg/FlameGraph](https://github.com/brendangregg/FlameGraph) — copy to `/usr/local/bin/` |
| Python 3 (stdlib only) | no pip installs required |
| **Root / sudo** | strace and perf require root; run `sudo puppet-trace once` |
| rbspy (optional) | enables Ruby-level flamegraph — see [install](#rbspy-ruby-level-flamegraph) |

#### Sudo requirements

puppet-trace must run as root. If invoking via sudo, the user needs unrestricted sudo or at minimum:

```sudoers
# /etc/sudoers.d/puppet-trace
<user> ALL=(root) NOPASSWD: /usr/local/bin/puppet-trace
```

The script runs `puppet`, `strace`, `perf record`, `perf script`, and (optionally) `rbspy` — all of which need root.

### For PuppetDB enrichment (optional)

PuppetDB enrichment adds source file, line number, and parameter values (including before/after change diffs) to each resource. It requires:

| Requirement | Notes |
|---|---|
| SSH access to the Puppet server host | the user running puppet-trace must be able to SSH in |
| `docker exec` access on the Puppet server | the SSH user needs permission to run `docker exec <pdb-container> curl ...` |
| PuppetDB running in Docker | container name must be set via `PUPPET_TRACE_PDB_CONTAINER` or auto-discovered (see below) |

If PuppetDB is not configured, puppet-trace prints `PuppetDB not configured — skipping enrichment` and continues without it.

#### Auto-discovery via push-server

When `--push-server` is set (see [Remote dashboard](#remote-dashboard)), puppet-trace fetches the PuppetDB container name automatically from the server's `/api/profiling/status` endpoint. No manual configuration needed on the agent.

To configure on the server side, set `PT_PDB_CONTAINER_NAME` in `/etc/puppet-trace-server/puppet-trace-server.env` (empty string = PuppetDB disabled).

### For Puppetserver profile flamegraph (agent mode only)

| Requirement | Notes |
|---|---|
| SSH access to the Puppet server host | |
| `docker exec` access on Puppet server | to read the puppetserver profile log |
| Puppetserver running in Docker | container name set via `PUPPET_TRACE_SERVER_CONTAINER` or auto-discovered |

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

### rbspy (Ruby-level flamegraph)

[rbspy](https://rbspy.github.io/) samples the Puppet Ruby process and produces a second flamegraph showing time in Ruby methods (complements the perf/kernel-level flamegraph). Install on the agent host:

```bash
curl -sL https://github.com/rbspy/rbspy/releases/download/v0.48.0/rbspy-x86_64-unknown-linux-musl.tar.gz \
  | tar -xz -C /usr/local/bin/ --transform 's/rbspy-x86_64-unknown-linux-musl/rbspy/'
```

rbspy runs automatically when present and when puppet-trace is invoked as root. If not installed, the Ruby-level flamegraph section shows "Not available".

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

### Remote dashboard

puppet-trace-server is a lightweight Python HTTP server that receives run artifacts from agents and exposes a multi-node dashboard.

Start it on a central host:

```bash
python3 puppet-trace-server.py
# or with env overrides:
PT_SERVER_PORT=9141 PT_REPORTS_DIR=/data/puppet-trace/reports python3 puppet-trace-server.py
```

On agents, pass `--push-server`:

```bash
sudo puppet-trace once --push-server karr.example.com:9141
```

Artifacts are uploaded after each run. The dashboard at `http://<host>:9141/` shows all nodes with their latest run status, wall time, resource counts, and PuppetDB enrichment status.

### Dry run (fixture data)

```bash
puppet-trace demo
```

Generates a rich example report without running Puppet, using a 40-resource fixture. No root required.

## Output

Each run produces a directory under `/var/log/puppet-trace/<timestamp>/`:

| File | Description |
|---|---|
| `report.html` | Self-contained HTML report (open in browser) |
| `run-meta.json` | Run metadata (exit code, wall time, idempotency, resource counts) |
| `io-correlation.json` | Per-resource strace correlation with timing and memory |
| `resource-report.json` | Top resources by duration (PuppetDB enriched if available) |
| `http-phases.json` | HTTP phase timestamps (facts→plugin sync→catalog→apply) |
| `puppet-timestamps.log` | Puppet log with timestamps (source for HTTP waterfall) |
| `proc-poll.log` | Memory samples at 1s intervals |
| `puppet.log` | Full puppet output with evaltrace |
| `strace.raw` | Raw strace output (large, excluded from ship by default) |
| `perf.data` | Raw perf data (large, excluded from ship by default) |
| `flamegraph.svg` | Puppet perf flamegraph |
| `flamegraph-profile.svg` | Puppetserver profile flamegraph (agent mode) |
| `ruby-flamegraph.svg` | Ruby-level flamegraph from rbspy (if installed) |

## Configuration

Environment variables (can be set before running or in `/etc/puppet-trace.conf`):

| Variable | Default | Description |
|---|---|---|
| `PUPPET_TRACE_SSH_KEY` | `~/.ssh/id_ed25519` | SSH key for Puppet server access |
| `PUPPET_TRACE_SSH_USER` | `puppet` | SSH user on Puppet server |
| `PUPPET_TRACE_SERVER_CONTAINER` | `puppetserver` | Docker container name for Puppet server |
| `PUPPET_TRACE_PDB_CONTAINER` | _(empty)_ | Docker container name for PuppetDB; empty = skip enrichment |
| `PUPPET_TRACE_LOG_DIR` | `/var/log/puppet-trace` | Base directory for run artifacts |

`PUPPET_TRACE_PDB_CONTAINER` defaults to empty — PuppetDB enrichment is opt-in. Set it explicitly or configure `PT_PDB_CONTAINER_NAME` on the push-server for auto-discovery.

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
- **PDB** badge (purple) when PuppetDB data is available for this resource

Click a row to expand full detail: before/after change diff, parameters, source file/line, memory stats, all files read/written, processes spawned.

### Memory chart

SVG chart showing RSS over the full run with:
- Colored bands for each resource eval window (green=changed, gray=unchanged, red=failed, orange=skipped)
- Reference lines for min / average / peak RSS
- Per-sample tooltips showing timestamp and RSS

### HTTP phase waterfall

Horizontal SVG timeline showing the major phases of a Puppet agent run — facts prefetch, plugin sync, facter, catalog request, catalog compile, catalog cache, apply, done — with timestamps derived from the puppet log. Helps identify where catalog compilation time is spent vs. agent-side apply time.

### Flamegraphs

Three interactively zoomable SVG flamegraphs embedded in the report:

1. **perf flamegraph** — kernel + userspace call stack sampled with `perf record`
2. **Puppetserver profile flamegraph** — function-level profiling from puppetserver's built-in JRuby profiler (agent mode only, requires Puppetserver access)
3. **rbspy Ruby flamegraph** — Ruby method-level sampling from rbspy (if installed on the agent)

All three support click-to-zoom, search, and reset zoom.

## Example reports

- [`example-report.html`](example-report.html) — full report with PuppetDB enrichment, before/after diffs, and Ruby-level flamegraph
- [`example-report-no-pdb.html`](example-report-no-pdb.html) — same run without PuppetDB enrichment (shows the "PuppetDB —" stat card and no PDB badges)

## How it works

1. **Wrap**: puppet run is started under `strace -f -ttt -e trace=openat,read,write,execve,clone` + `perf record -g -p <pid>` + `rbspy record --pid <pid>` in parallel
2. **Poll**: `proc-poll.log` captures RSS every 1 second via `/proc/<pid>/status`
3. **Timestamps**: puppet's `--logdest FILE` writes a timestamped log; phase markers (`Retrieving pluginfacts`, `Requesting catalog`, `Applying configuration`, etc.) are parsed to build the HTTP waterfall
4. **Correlate**: strace timestamps (float unix epoch) are joined to resource eval windows from evaltrace log
5. **Enrich**: PuppetDB REST API (via `docker exec` on Puppet server, reached over SSH) adds source file, line, parameters, and before/after values per resource
6. **Flamegraph**: `perf script | stackcollapse-perf.pl | flamegraph.pl` → SVG; rbspy writes its own SVG on SIGINT
7. **Report**: single-file HTML with embedded SVGs, inline CSS/JS, no external dependencies

## Security

- **Report contains sensitive data.** `report.html` includes puppet resource parameters, before/after change values, memory samples, and call stacks from the flamegraph. Treat it as you would a heap dump.
- **SVG sources are external tools.** The report embeds SVGs generated by `flamegraph.pl`, `stackcollapse-perf.pl`, `puppet-profile-parser.rb`, and rbspy. These are sanitized (script/link/handler stripping, attribute allowlisting) but verify those tools come from trusted packages before running puppet-trace.
- **Do not serve `report.html` over HTTP to untrusted users.** Serve it locally (`file://`) or over an authenticated channel only.
- **`strace.raw` contains partial file buffer data.** When `--include-strace` is used, the raw strace capture may include partial contents of files puppet read during the run. Keep it off shared filesystems.
- **Keep `OUTDIR` permissions at `0700` (the default).** Do not relax permissions or expose the output directory via a web server.
- **PuppetDB SSH access.** puppet-trace SSHes to the Puppet server host and runs `docker exec <pdb-container> curl ...` to query PuppetDB. Ensure the SSH key and sudo/docker permissions are scoped appropriately.

## License

MIT
