#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/g2ray.sh"
GITIGNORE="$ROOT_DIR/.gitignore"
DOCKERFILE="$ROOT_DIR/.devcontainer/Dockerfile"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$1"
}

grep_fixed() {
    local pattern="$1" file="$2"
    grep -Fq -- "$pattern" "$file"
}

grep_regex() {
    local pattern="$1" file="$2"
    grep -Eq -- "$pattern" "$file"
}

test_wait_for_port_increment_is_set_e_safe() {
    if grep_fixed '(( i++ ))' "$SCRIPT"; then
        fail 'wait_for_port still uses post-increment, which exits under set -e when i is 0'
    fi
    grep_regex 'i=\$\(\(i \+ 1\)\)|\(\( \+\+i \)\)' "$SCRIPT" \
        || fail 'wait_for_port does not contain a set -e safe increment'
    pass 'wait_for_port increment is set -e safe'
}

test_process_management_uses_pid_file() {
    grep_fixed 'XRAY_PID_FILE=' "$SCRIPT" \
        || fail 'script does not define an Xray PID file'
    grep_fixed 'xray_pid_matches()' "$SCRIPT" \
        || fail 'script does not validate that a PID belongs to this Xray config'
    grep_fixed 'xray_pid_matches "$p"' "$SCRIPT" \
        || fail 'stop/status paths do not validate PID ownership before trusting the PID file'
    grep_fixed '> "$XRAY_PID_FILE"' "$SCRIPT" \
        || fail 'start_xray does not store the launched Xray PID'
    if grep_fixed 'pkill -x "xray"' "$SCRIPT" || grep_fixed 'pkill -9 -x "xray"' "$SCRIPT"; then
        fail 'script still kills every process named xray'
    fi
    pass 'process management is scoped through a PID file'
}

test_background_tasks_require_config() {
    grep_fixed '[[ -f "$CONFIG_FILE" ]] || continue' "$SCRIPT" \
        || fail 'background loop can still start Xray before config exists'
    if grep_fixed 'start_xray; wait_for_port' "$SCRIPT"; then
        fail 'menu paths still run start_xray without handling a failed start'
    fi
    grep_fixed 'start_xray >/dev/null 2>&1 && wait_for_port >/dev/null 2>&1' "$SCRIPT" \
        || fail 'force reconnect does not handle start_xray failure explicitly'
    pass 'background tasks skip Xray start until config exists'
}

test_self_update_is_opt_in() {
    grep_fixed 'G2RAY_AUTO_UPDATE' "$SCRIPT" \
        || fail 'self-update is not controlled by an opt-in environment variable'
    pass 'self-update is opt-in'
}

test_generated_files_are_ignored() {
    [[ -f "$GITIGNORE" ]] || fail '.gitignore is missing'
    for pattern in '/data/' '/logs/' '/configs-to-copy-for-mobile.txt'; do
        grep_fixed "$pattern" "$GITIGNORE" || fail ".gitignore missing $pattern"
    done
    pass 'generated runtime files are ignored'
}

test_xray_version_can_be_pinned() {
    grep_fixed 'ARG XRAY_VERSION=' "$DOCKERFILE" \
        || fail 'Dockerfile does not expose XRAY_VERSION for reproducible builds'
    if grep_fixed 'releases/latest/download' "$DOCKERFILE"; then
        fail 'Dockerfile still downloads Xray from latest'
    fi
    pass 'Dockerfile supports pinned Xray version'
}

test_generated_link_uses_resolved_address_with_domain_sni() {
    grep_fixed 'resolve_domain_ip()' "$SCRIPT" \
        || fail 'script does not provide a resolver for the Codespaces app domain'
    grep_fixed 'address=$(resolve_domain_ip "$PORT_DOMAIN")' "$SCRIPT" \
        || fail 'generate_link does not resolve the Codespaces domain for the VLESS address'
    grep_fixed '"$uuid" "$address" "$XRAY_PORT" "$PORT_DOMAIN" "$PORT_DOMAIN"' "$SCRIPT" \
        || fail 'generate_link must use resolved address while preserving PORT_DOMAIN as SNI and host'
    pass 'generated links use resolved address with Codespaces domain SNI/host'
}

test_wait_for_port_increment_is_set_e_safe
test_process_management_uses_pid_file
test_background_tasks_require_config
test_self_update_is_opt_in
test_generated_files_are_ignored
test_xray_version_can_be_pinned
test_generated_link_uses_resolved_address_with_domain_sni
