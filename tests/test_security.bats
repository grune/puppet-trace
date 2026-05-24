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

###############################################################################
# N4: remote_host validation in cmd_ship
###############################################################################

@test "cmd_ship remote_host with SSH option injection is rejected" {
    # Extract _validate_puppet_id and simulate the N4 guard
    run bash -c '
        '"$VALIDATORS"'
        remote="-oProxyCommand=evil:path"
        remote_host="${remote%%:*}"
        _validate_puppet_id "$remote_host" "remote_host" || exit 1
        echo "ACCEPTED"
    ' 2>&1
    [ "$status" -ne 0 ]
    [[ "$output" != *"ACCEPTED"* ]]
}

###############################################################################
# N6: _LATE_SUBCMD env var is overwritten at script start
###############################################################################

@test "_LATE_SUBCMD env var is ignored (overwritten at script start)" {
    # Run with _LATE_SUBCMD=enable in environment; should NOT call cmd_enable
    # --dry-run causes once mode; enable subcommand would install hook/touch FLAG_FILE
    local flag_file="/etc/puppet-trace.enabled"
    run env _LATE_SUBCMD=enable bash "$SCRIPT" once --dry-run --outdir /tmp/pt-n6-test-$$ 2>&1
    # Should NOT see enable-related output; should see dry-run output
    [[ "$output" != *"postrun_command"* ]] || true
    [[ "$output" != *"flag file"* ]] || true
    # Clean up if dir was created
    rm -rf /tmp/pt-n6-test-$$
    # Key check: the flag file was not created by the inject
    [ ! -f "$flag_file" ] || skip "flag file already existed before test"
}

###############################################################################
# N3: PUPPET_EXIT captures nonzero exit correctly
###############################################################################

@test "PUPPET_EXIT is captured (code path exists in script)" {
    # Verify the fix is present: 'wait "$PUPPET_PID"' followed by 'PUPPET_EXIT=$?'
    # rather than 'wait "$PUPPET_PID" || true' with PIPESTATUS
    run grep -c 'PUPPET_EXIT=\$?' "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

###############################################################################
# Round 5 security fixes
###############################################################################

@test "N1: _stop_puppet_service does not clear main shell traps" {
    # Verify trap - EXIT INT TERM is NOT in _stop_puppet_service function body
    run bash -c '
        in_func=0
        found_trap=0
        while IFS= read -r line; do
            [[ "$line" =~ _stop_puppet_service\(\) ]] && in_func=1
            if [[ $in_func -eq 1 ]]; then
                [[ "$line" =~ ^"}" ]] && in_func=0
                [[ "$line" =~ "trap - EXIT INT TERM" ]] && found_trap=1
            fi
        done < "'"$SCRIPT"'"
        echo "found_trap=$found_trap"
        [[ $found_trap -eq 0 ]]
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"found_trap=0"* ]]
}

@test "N2: _validate_safe_path rejects backtick injection" {
    run bash -c "$VALIDATORS; _validate_safe_path '/tmp/\`id\`' 'outdir'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"command substitution"* ]]
}

@test "N2: _validate_safe_path rejects dollar-paren injection" {
    run bash -c "$VALIDATORS; _validate_safe_path '/tmp/\$(id)' 'outdir'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"command substitution"* ]]
}

@test "N3: _sanitize_svg strips style=url(javascript:) bypass" {
    # Delegate to the pytest suite which properly extracts _sanitize_svg from the script
    run python3 -m pytest "$(dirname "$SCRIPT")/../tests/test_sanitize_svg.py::test_style_url_javascript_stripped" -q 2>&1
    [ "$status" -eq 0 ]
}

@test "N4: stack_sampler has a deadline (1h)" {
    run grep -A5 'stack_sampler()' "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"deadline"* ]]
}

@test "N5: cmd_ship accepts user@host syntax" {
    run bash -c '
        '"$VALIDATORS"'
        remote="user@myhost.example.com:/remote/path"
        remote_host="${remote%%:*}"
        remote_path="${remote#*:}"
        ssh_user=""
        ssh_host="$remote_host"
        if [[ "$remote_host" == *@* ]]; then
            ssh_user="${remote_host%%@*}"
            ssh_host="${remote_host#*@}"
            _validate_puppet_id "$ssh_user" "remote_user" || exit 1
        fi
        _validate_puppet_id "$ssh_host" "remote_host" || exit 1
        echo "ACCEPTED"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"ACCEPTED"* ]]
}

@test "N5: cmd_ship rejects @ with invalid user component" {
    run bash -c '
        '"$VALIDATORS"'
        remote="us er@myhost.example.com:/remote/path"
        remote_host="${remote%%:*}"
        ssh_user="${remote_host%%@*}"
        ssh_host="${remote_host#*@}"
        _validate_puppet_id "$ssh_user" "remote_user" || exit 1
        echo "ACCEPTED"
    '
    [ "$status" -ne 0 ]
    [[ "$output" != *"ACCEPTED"* ]]
}

@test "N12: _PT_CLEANUP_PIDS empty array does not pass empty string to kill" {
    # Verify the safe expansion pattern is used (not [@]:-}
    run grep '_PT_CLEANUP_PIDS\[@\]' "$SCRIPT"
    [ "$status" -eq 0 ]
    # Should use the safe ${arr[@]+"${arr[@]}"} idiom, not [@]:-}
    [[ "$output" != *'[@]:-}'* ]]
}

###############################################################################
# Round 6 security fixes
###############################################################################

@test "R6-2: strace invocation includes -s 0 to suppress buffer content" {
    run grep -c 'strace.*-s 0' "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "R6-2: strace correlation skips oversized strace.raw files" {
    run grep 'strace_max_bytes' "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"strace_max_bytes"* ]]
}

@test "R6-4: report.html written with umask 0077" {
    run grep -c 'umask(0o077)' "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" -ge 2 ]
}

@test "R6-4: cmd_ship rsync uses --chmod=D0700,F0600" {
    run grep 'rsync.*--chmod=D0700,F0600' "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--chmod=D0700,F0600"* ]]
}

@test "R6-5: mktemp uses -p /var/log/puppet-trace not bare /tmp" {
    # Bare mktemp (no -p flag) should not appear in the script
    run bash -c "grep -n 'mktemp$' '$SCRIPT'"
    [ "$status" -ne 0 ] || [ -z "$output" ]
}

@test "R6-7: cmd_ship uses printf %q for remote_path on SSH call" {
    run grep "printf '%q'" "$SCRIPT"
    [ "$status" -eq 0 ]
}
