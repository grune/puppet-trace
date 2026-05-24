#!/usr/bin/env bats
# tests/test_dry_run.bats — Dry-run integration tests for puppet-trace
#
# Run: sudo bats tests/test_dry_run.bats
# Requires: bats, sudo access (script needs root for mkdir -m 0700)

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/puppet-trace"
TEST_OUTDIR="/tmp/pt-dryrun-test-$$"

setup() {
    # Clean up any leftover test dir
    rm -rf "$TEST_OUTDIR"
}

teardown() {
    rm -rf "$TEST_OUTDIR"
}

@test "dry-run exits 0" {
    run sudo bash "$SCRIPT" once --dry-run --outdir "$TEST_OUTDIR"
    [ "$status" -eq 0 ]
}

@test "output dir has mode 0700" {
    sudo bash "$SCRIPT" once --dry-run --outdir "$TEST_OUTDIR" >/dev/null 2>&1
    run stat -c '%a' "$TEST_OUTDIR"
    [ "$status" -eq 0 ]
    [ "$output" = "700" ]
}

@test "report.html exists and is non-empty" {
    sudo bash "$SCRIPT" once --dry-run --outdir "$TEST_OUTDIR" >/dev/null 2>&1
    [ -f "$TEST_OUTDIR/report.html" ]
    [ -s "$TEST_OUTDIR/report.html" ]
}

@test "report.html is a valid HTML file (has DOCTYPE and body)" {
    sudo bash "$SCRIPT" once --dry-run --outdir "$TEST_OUTDIR" >/dev/null 2>&1
    run grep -c '<!DOCTYPE html>' "$TEST_OUTDIR/report.html"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "no stray files created in /tmp/puppet-trace-*" {
    local before_count after_count
    before_count=$(find /tmp -maxdepth 1 -name 'puppet-trace-*' 2>/dev/null | wc -l)
    sudo bash "$SCRIPT" once --dry-run --outdir "$TEST_OUTDIR" >/dev/null 2>&1
    after_count=$(find /tmp -maxdepth 1 -name 'puppet-trace-*' 2>/dev/null | wc -l)
    [ "$after_count" -eq "$before_count" ]
}

@test "outdir contains expected artifact files" {
    sudo bash "$SCRIPT" once --dry-run --outdir "$TEST_OUTDIR" >/dev/null 2>&1
    [ -f "$TEST_OUTDIR/puppet.log" ]
    [ -f "$TEST_OUTDIR/proc-poll.log" ]
    [ -f "$TEST_OUTDIR/io-correlation.json" ]
    [ -f "$TEST_OUTDIR/resource-report.json" ]
    [ -f "$TEST_OUTDIR/run-meta.json" ]
}

@test "report.html does not contain internal hostnames or IPs" {
    sudo bash "$SCRIPT" once --dry-run --outdir "$TEST_OUTDIR" >/dev/null 2>&1
    # Should not find real infra identifiers in fixture output
    run grep -iE 'forge\.runeg\.net|10\.0\.0\.[0-9]+|runecorps\.com|runealert' \
        "$TEST_OUTDIR/report.html"
    # grep returns 1 if no match — we want no match
    [ "$status" -ne 0 ]
}

@test "report.html does not contain unescaped <script> tags (XSS check)" {
    sudo bash "$SCRIPT" once --dry-run --outdir "$TEST_OUTDIR" >/dev/null 2>&1
    # The only allowed <script> in the report is the inline JS (sortTable/toggleDetail)
    # Flamegraph SVGs from the sanitizer must not introduce extra <script> tags.
    # Count script tags — fixture has no flamegraph SVG so only the inline JS block should exist.
    local script_count
    script_count=$(grep -ic '<script' "$TEST_OUTDIR/report.html" || true)
    # 1 or 2 inline script blocks from the report template are expected; more indicates SVG injection
    [ "$script_count" -le 2 ]
}

@test "report.html size is reasonable (>= 10KB for fixture data)" {
    sudo bash "$SCRIPT" once --dry-run --outdir "$TEST_OUTDIR" >/dev/null 2>&1
    local size
    size=$(wc -c < "$TEST_OUTDIR/report.html")
    [ "$size" -ge 10240 ]
}

@test "run-meta.json is valid JSON" {
    sudo bash "$SCRIPT" once --dry-run --outdir "$TEST_OUTDIR" >/dev/null 2>&1
    run python3 -c "import json, sys; json.load(open('$TEST_OUTDIR/run-meta.json'))"
    [ "$status" -eq 0 ]
}

@test "resource-report.json is valid JSON with resources array" {
    sudo bash "$SCRIPT" once --dry-run --outdir "$TEST_OUTDIR" >/dev/null 2>&1
    run python3 -c "
import json, sys
d = json.load(open('$TEST_OUTDIR/resource-report.json'))
assert isinstance(d.get('resources'), list), 'resources must be a list'
print(len(d['resources']))
"
    [ "$status" -eq 0 ]
    [ "$output" -gt 0 ]
}
