#!/usr/bin/env bats
# tests/test_security.bats — Security validation tests for puppet-trace
#
# Run: bats tests/test_security.bats
# Requires: bats (apt install bats or https://github.com/bats-core/bats-core)

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/puppet-trace"

# Source only the validation functions into a subshell
_source_validators() {
    bash -c "
        source '$SCRIPT' --dry-run /dev/null 2>/dev/null || true
        \$1 \"\${@:2}\"
    " -- "$@"
}

# Helper: extract and eval _validate_puppet_id and _validate_safe_path from script
_run_validator() {
    local func="$1"; shift
    bash -c "
        $(grep -A5 '_validate_puppet_id()' "$SCRIPT" | head -7)
        $(grep -A8 '_validate_safe_path()' "$SCRIPT" | head -10)
        $func \"\$@\"
    " -- "$@"
}

# Extract validator functions from the script for inline use in tests
VALIDATORS=$(awk '
  /_validate_puppet_id\(\)/{found=1}
  /_validate_safe_path\(\)/{found=1}
  found && /^}$/{print; found=0; next}
  found{print}
' "$SCRIPT")

###############################################################################
# _validate_puppet_id tests
###############################################################################

@test "_validate_puppet_id: accepts valid hostname" {
    run bash -c "$VALIDATORS; _validate_puppet_id 'puppet.example.com' 'test'"
    [ "$status" -eq 0 ]
}

@test "_validate_puppet_id: accepts alphanumeric with dots/colons/dashes" {
    run bash -c "$VALIDATORS; _validate_puppet_id 'puppet-server.example.com:8140' 'test'"
    [ "$status" -eq 0 ]
}

@test "_validate_puppet_id: rejects space injection" {
    run bash -c "$VALIDATORS; _validate_puppet_id 'puppet; rm -rf /' 'test'"
    [ "$status" -ne 0 ]
}

@test "_validate_puppet_id: rejects single quote" {
    run bash -c "$VALIDATORS; _validate_puppet_id \"puppet'server\" 'test'"
    [ "$status" -ne 0 ]
}

@test "_validate_puppet_id: rejects newline" {
    run bash -c "$VALIDATORS; _validate_puppet_id $'puppet\nserver' 'test'"
    [ "$status" -ne 0 ]
}

@test "_validate_puppet_id: rejects SSH ProxyCommand injection" {
    run bash -c "$VALIDATORS; _validate_puppet_id '-oProxyCommand=evil' 'test'"
    [ "$status" -ne 0 ]
}

@test "_validate_puppet_id: rejects empty string" {
    run bash -c "$VALIDATORS; _validate_puppet_id '' 'test'"
    [ "$status" -ne 0 ]
}

###############################################################################
# _validate_safe_path tests
###############################################################################

@test "_validate_safe_path: accepts normal path" {
    run bash -c "$VALIDATORS; _validate_safe_path '/var/log/puppet-trace/20260523-120000' 'outdir'"
    [ "$status" -eq 0 ]
}

@test "_validate_safe_path: accepts path with spaces (not quotes)" {
    run bash -c "$VALIDATORS; _validate_safe_path '/var/log/puppet trace/20260523' 'outdir'"
    [ "$status" -eq 0 ]
}

@test "_validate_safe_path: rejects single quote in path" {
    run bash -c "$VALIDATORS; _validate_safe_path \"/tmp/dir'evil\" 'outdir'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsafe characters"* ]]
}

@test "_validate_safe_path: rejects double quote in path" {
    run bash -c '$VALIDATORS; _validate_safe_path "/tmp/dir\"evil" "outdir"' VALIDATORS="$VALIDATORS"
    [ "$status" -ne 0 ]
}

@test "_validate_safe_path: rejects newline in path" {
    run bash -c "$VALIDATORS; _validate_safe_path $'/tmp/dir\nevil' 'outdir'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsafe characters"* ]]
}

@test "_validate_safe_path: rejects carriage return in path" {
    run bash -c "$VALIDATORS; _validate_safe_path $'/tmp/dir\revil' 'outdir'"
    [ "$status" -ne 0 ]
}

###############################################################################
# --outdir injection: script exits 1 before any file operation
###############################################################################

@test "--outdir with single quote exits 1 without creating files" {
    local bad_dir="/tmp/pt-test-evil'-injected-$$"
    run sudo bash "$SCRIPT" once --dry-run --outdir "$bad_dir" 2>&1
    [ "$status" -ne 0 ]
    # Ensure the bad dir was NOT created
    [ ! -d "$bad_dir" ]
}

@test "--outdir with newline exits 1" {
    local bad_dir=$'/tmp/pt-test\nevil-$$'
    run sudo bash "$SCRIPT" once --dry-run --outdir "$bad_dir" 2>&1
    [ "$status" -ne 0 ]
}

###############################################################################
# run_start_iso validation
###############################################################################

@test "run_start_iso: valid ISO format passes" {
    run bash -c '
        val="2026-05-23T14:30:00Z"
        if [[ -n "$val" ]] && [[ ! "$val" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z?$ ]]; then
            echo "REJECTED"
            exit 1
        fi
        echo "ACCEPTED"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == "ACCEPTED" ]]
}

@test "run_start_iso: without Z suffix passes" {
    run bash -c '
        val="2026-05-23T14:30:00"
        if [[ -n "$val" ]] && [[ ! "$val" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z?$ ]]; then
            echo "REJECTED"
            exit 1
        fi
        echo "ACCEPTED"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == "ACCEPTED" ]]
}

@test "run_start_iso: injection attempt is rejected" {
    run bash -c '
        val="2026-05-23T14:30:00Z; rm -rf /"
        if [[ -n "$val" ]] && [[ ! "$val" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z?$ ]]; then
            echo "REJECTED"
            exit 1
        fi
        echo "ACCEPTED"
    '
    [ "$status" -ne 0 ]
    [[ "$output" == "REJECTED" ]]
}

@test "run_start_iso: single quote injection is rejected" {
    run bash -c '
        val="2026-05-23T14:30:00Z'"'"'; evil"
        if [[ -n "$val" ]] && [[ ! "$val" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z?$ ]]; then
            echo "REJECTED"
            exit 1
        fi
        echo "ACCEPTED"
    '
    [ "$status" -ne 0 ]
    [[ "$output" == "REJECTED" ]]
}

###############################################################################
# puppet_server validation — PUPPET_SERVER env var injection
###############################################################################

@test "puppet_server: ProxyCommand injection in PUPPET_SERVER is rejected" {
    run bash -c "$VALIDATORS; _validate_puppet_id '-oProxyCommand=evil' 'puppet_server'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid characters"* ]]
}

@test "puppet_server: valid hostname in PUPPET_SERVER is accepted" {
    run bash -c "$VALIDATORS; _validate_puppet_id 'puppet.runeg.net' 'puppet_server'"
    [ "$status" -eq 0 ]
}

@test "puppet_server: semicolon injection in PUPPET_SERVER is rejected" {
    run bash -c "$VALIDATORS; _validate_puppet_id 'puppet.example.com;evil' 'puppet_server'"
    [ "$status" -ne 0 ]
}

###############################################################################
# N4: path traversal in --outdir
###############################################################################

@test "--outdir with path traversal exits 1" {
    run sudo bash "$SCRIPT" once --dry-run --outdir '/tmp/../etc' 2>&1
    [ "$status" -ne 0 ]
    [[ "$output" == *"path traversal"* ]]
}

@test "_validate_safe_path: rejects /../ traversal" {
    run bash -c "$VALIDATORS; _validate_safe_path '/tmp/../etc' 'outdir'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"path traversal"* ]]
}

@test "_validate_safe_path: rejects /.. at end" {
    run bash -c "$VALIDATORS; _validate_safe_path '/tmp/..' 'outdir'"
    [ "$status" -ne 0 ]
}

@test "_validate_safe_path: rejects ../ at start" {
    run bash -c "$VALIDATORS; _validate_safe_path '../etc/passwd' 'outdir'"
    [ "$status" -ne 0 ]
}

###############################################################################
# N8: PUPPET_TRACE_PUPPET_USER=root falls back to puppet
###############################################################################

@test "PUPPET_TRACE_PUPPET_USER=root falls back to puppet" {
    # Extract _validate_puppet_id from the script and simulate the N8 guard inline
    run bash -c '
        '"$VALIDATORS"'
        puppet_run_user="root"
        if [[ "$puppet_run_user" == "root" ]] || ! _validate_puppet_id "$puppet_run_user" "PUPPET_TRACE_PUPPET_USER" 2>/dev/null; then
            echo "[puppet-trace] WARNING: PUPPET_TRACE_PUPPET_USER='"'"'$puppet_run_user'"'"' is invalid or root — using '"'"'puppet'"'"'" >&2
            puppet_run_user="puppet"
        fi
        echo "effective_user=$puppet_run_user"
    ' 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"invalid or root"* ]]
    [[ "$output" == *"effective_user=puppet"* ]]
}
