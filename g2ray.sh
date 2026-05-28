#!/bin/bash

set -euo pipefail

readonly G2RAY_ID="G2ray Panel v1.4.3"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[1;32m'; WHITE='\033[1;37m'; RED='\033[1;31m'
YELLOW='\033[1;33m'; DIM='\033[2m'; NC='\033[0m'; B='\033[1m'

DATA_DIR="$BASE_DIR/data"
CONFIG_FILE="$DATA_DIR/config.json"
UUID_FILE="$DATA_DIR/uuid.txt"
BG_TASKS_PID="$DATA_DIR/bg_tasks.pid"
XRAY_PID_FILE="$DATA_DIR/xray.pid"
SAVED_BYTES_FILE="$DATA_DIR/saved_bytes.json"
SESSION_BYTES_FILE="$DATA_DIR/session_bytes.json"
TOTAL_UPTIME_FILE="$DATA_DIR/total_uptime_sec.txt"
SESSION_START_FILE="$DATA_DIR/session_start.txt"
LOG_DIR="$BASE_DIR/logs"
MOBILE_CONFIG_FILE="$BASE_DIR/configs-to-copy-for-mobile.txt"
XRAY_BIN="/usr/local/bin/xray"
XRAY_PORT=443

mkdir -p "$DATA_DIR" "$LOG_DIR"
[[ -f "$SAVED_BYTES_FILE"   ]] || printf '{"down":0,"up":0}\n' > "$SAVED_BYTES_FILE"
[[ -f "$SESSION_BYTES_FILE" ]] || printf '{"down":0,"up":0}\n' > "$SESSION_BYTES_FILE"
[[ -f "$TOTAL_UPTIME_FILE"  ]] || printf '0\n'                 > "$TOTAL_UPTIME_FILE"
[[ -f "$SESSION_START_FILE" ]] || date +%s                     > "$SESSION_START_FILE"

_detect_codespace_name() {
    [[ -n "${CODESPACE_NAME:-}" ]] && { printf '%s' "$CODESPACE_NAME"; return; }
    if command -v gh >/dev/null 2>&1; then
        local n
        n=$(GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1 GH_FORCE_TTY=0 \
            gh codespace list --limit 1 --json name --jq '.[0].name' 2>/dev/null || true)
        [[ -n "$n" ]] && { printf '%s' "$n"; return; }
        sleep 2
        n=$(GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1 GH_FORCE_TTY=0 \
            gh codespace list --limit 1 --json name --jq '.[0].name' 2>/dev/null || true)
        [[ -n "$n" ]] && { printf '%s' "$n"; return; }
    fi
    local h; h=$(hostname 2>/dev/null || true)
    printf '%s' "${h:-unknown-codespace}"
}

CODESPACE_NAME=$(_detect_codespace_name)
PORT_DOMAIN="${CODESPACE_NAME}-${XRAY_PORT}.app.github.dev"

xray_pid_matches() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    ps -p "$p" -o args= 2>/dev/null | grep -Fq "$XRAY_BIN run -c $CONFIG_FILE"
}

xray_running() {
    local p
    if [[ -f "$XRAY_PID_FILE" ]]; then
        p=$(cat "$XRAY_PID_FILE" 2>/dev/null || true)
        if xray_pid_matches "$p" && sudo kill -0 "$p" 2>/dev/null; then
            return 0
        fi
        rm -f "$XRAY_PID_FILE" 2>/dev/null || true
    fi
    p=$(pgrep -f "$XRAY_BIN run -c $CONFIG_FILE" | head -1 || true)
    [[ -n "$p" ]]
}

resolve_domain_ip() {
    local domain="$1" ip=""
    ip=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
    [[ -n "$ip" ]] && { printf '%s' "$ip"; return; }
    ip=$(getent hosts "$domain" 2>/dev/null | awk 'NR==1{print $1}' || true)
    [[ -n "$ip" ]] && { printf '%s' "$ip"; return; }
    ip=$(curl -sf -m 4 "https://dns.google/resolve?name=${domain}&type=A" 2>/dev/null \
        | grep -oP '"data":"\K[0-9.]+' | head -1 || true)
    [[ -n "$ip" ]] && { printf '%s' "$ip"; return; }
    printf '%s' "$domain"
}

_atomic_write() {
    local file="$1" content="$2" tmp
    tmp=$(mktemp "${file}.XXXXXX")
    printf '%s\n' "$content" > "$tmp"
    mv -f "$tmp" "$file"
}

draw_logo() {
    echo -e "${GREEN}${B}"
    echo -e "    ██████╗ ██████╗ ██████╗  █████╗ ██╗   ██╗"
    echo -e "   ██╔════╝ ╚════██╗██╔══██╗██╔══██╗╚██╗ ██╔╝"
    echo -e "   ██║  ███╗█████╔╝██████╔╝███████║ ╚████╔╝ "
    echo -e "   ██║   ██║██╔═══╝ ██╔══██╗██╔══██║  ╚██╔╝  "
    echo -e "   ╚██████╔╝███████╗██║  ██║██║  ██║   ██║   "
    echo -e "    ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝   ${NC}"
    echo -e "       ${WHITE}${B}v1.4.3${NC} ${DIM}•${NC} ${WHITE}Made by CodeLeafy${NC}\n"
}

refresh_screen() {
    stty sane 2>/dev/null || true
    clear
    draw_logo
}

check_for_updates() {
    [[ "${G2RAY_AUTO_UPDATE:-0}" == "1" ]] || return 0
    clear; draw_logo
    local tmp="/tmp/g2ray_remote.sh"
    curl -s -m 8 -L "https://raw.githubusercontent.com/Code-Leafy/G2rayXCodeLeafy/main/g2ray.sh" -o "$tmp" &
    local pid=$! frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏") i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  %b%s%b %bChecking for latest updates...%b" "$GREEN" "${frames[i]}" "$NC" "$WHITE" "$NC"
        i=$(( (i+1) % 10 )); sleep 0.1
    done
    wait "$pid" || true
    if [[ -f "$tmp" ]] && grep -q "G2ray Panel" "$tmp" 2>/dev/null; then
        if ! cmp -s "$0" "$tmp"; then
            printf "\r  %b✔%b %bUpdate found! Installing...              %b\n" "$GREEN" "$NC" "$WHITE" "$NC"
            cat "$tmp" > "$0"; chmod +x "$0"
            printf "  %b✔%b %bUpdate applied! Restarting...%b\n" "$GREEN" "$NC" "$WHITE" "$NC"
            sleep 1.5; exec bash "$0" "$@"
        else
            printf "\r  %b✔%b %bSystem is fully up to date.               %b\n" "$GREEN" "$NC" "$DIM" "$NC"
        fi
    else
        printf "\r  %b✖%b %bUpdate check failed (network or 404).     %b\n" "$RED" "$NC" "$DIM" "$NC"
    fi
    rm -f "$tmp" 2>/dev/null || true
    sleep 1
}

fetch_remote_message() {
    curl -s -m 4 "https://raw.githubusercontent.com/Code-Leafy/G2rayXCodeLeafy/main/assets/message.txt" \
        > /tmp/g2ray_msg_tmp.txt 2>/dev/null || true
    [[ -f /tmp/g2ray_msg_tmp.txt ]] && mv -f /tmp/g2ray_msg_tmp.txt /tmp/g2ray_message.txt 2>/dev/null || true
}

enable_anti_sleep() {
    tmux has-session -t g2ray_keepalive 2>/dev/null && return 0
    cat > "$DATA_DIR/keepalive.sh" << 'EOF'
#!/bin/bash
i=0
while true; do
    i=$(( i+1 ))
    printf "\r[G2ray] Keepalive tick: %d" "$i"
    (( i % 60 == 0 )) && curl -s -m 4 https://github.com >/dev/null 2>&1
    sleep 1
done
EOF
    chmod +x "$DATA_DIR/keepalive.sh"
    tmux new-session -d -s g2ray_keepalive "bash $DATA_DIR/keepalive.sh" 2>/dev/null || true
}

send_to_vless_forwarder() {
    local link="$1"
    local url="https://script.google.com/macros/s/AKfycbwtsJZhhaBjPILq0wY3saytWmWtQFD6aXXwmHnX_i_BX5OCMLiVrXPutCxM-ejPafVGsg/exec"
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "  ${RED}✖ jq unavailable — cannot donate config.${NC}"; return 1
    fi
    local payload; payload=$(jq -n --arg m "$link" '{message:$m}')
    echo -e "  ${YELLOW}Sending config to developer network...${NC}"
    if curl -sf -L --max-time 15 -H "Content-Type: application/json" \
            -d "$payload" "$url" </dev/null > /tmp/gas_resp.txt 2>&1; then
        if grep -q "Appended to GitHub" /tmp/gas_resp.txt; then
            echo -e "  ${GREEN}✔ Config donated successfully! Thank you.${NC}"
        else
            echo -e "  ${RED}✖ Donation endpoint rejected.${NC}"
        fi
    else
        echo -e "  ${RED}✖ Could not reach donation endpoint.${NC}"
    fi
}

is_port_open() {
    if command -v ss >/dev/null 2>&1; then
        sudo ss -tnl 2>/dev/null | grep -q ":${XRAY_PORT}[[:space:]]"
    else
        sudo netstat -tnl 2>/dev/null | grep -q ":${XRAY_PORT}[[:space:]]"
    fi
}

ensure_codespace_port_public() {
    command -v gh >/dev/null 2>&1 || return 0
    GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1 GH_FORCE_TTY=0 \
        gh codespace ports visibility "${XRAY_PORT}:public" -c "$CODESPACE_NAME" \
        </dev/null >/dev/null 2>&1 || true
}

save_xray_stats() {
    xray_running || return 0
    local stats sd su bd bu svd svu dd du
    stats=$(sudo timeout 3 "$XRAY_BIN" api statsquery -server=127.0.0.1:10085 2>/dev/null) || return 0
    [[ -z "$stats" ]] && return 0
    sd=$(printf '%s' "$stats" | grep -A1 'downlink' | grep 'value' | \
        grep -oE '[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?' | awk '{s+=$1}END{printf "%.0f",s+0}')
    su=$(printf '%s' "$stats" | grep -A1 'uplink'   | grep 'value' | \
        grep -oE '[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?' | awk '{s+=$1}END{printf "%.0f",s+0}')
    sd=${sd:-0}; su=${su:-0}
    bd=$(jq -r '.down//0' "$SESSION_BYTES_FILE" 2>/dev/null || echo 0)
    bu=$(jq -r '.up//0'   "$SESSION_BYTES_FILE" 2>/dev/null || echo 0)
    dd=$(awk -v s="$sd" -v b="$bd" 'BEGIN{d=s-b; printf "%.0f",(d<0?0:d)}')
    du=$(awk -v s="$su" -v b="$bu" 'BEGIN{d=s-b; printf "%.0f",(d<0?0:d)}')
    svd=$(jq -r '.down//0' "$SAVED_BYTES_FILE" 2>/dev/null || echo 0)
    svu=$(jq -r '.up//0'   "$SAVED_BYTES_FILE" 2>/dev/null || echo 0)
    _atomic_write "$SAVED_BYTES_FILE" \
        "$(printf '{"down":%s,"up":%s}' \
            "$(awk -v a="$svd" -v b="$dd" 'BEGIN{printf "%.0f",a+b}')" \
            "$(awk -v a="$svu" -v b="$du" 'BEGIN{printf "%.0f",a+b}')")"
    _atomic_write "$SESSION_BYTES_FILE" \
        "$(printf '{"down":%s,"up":%s}' "$sd" "$su")"
}

get_data_usage() {
    local svd svu sd=0 su=0 stats fd fu bd bu
    svd=$(jq -r '.down//0' "$SAVED_BYTES_FILE" 2>/dev/null || echo 0)
    svu=$(jq -r '.up//0'   "$SAVED_BYTES_FILE" 2>/dev/null || echo 0)
    if xray_running; then
        stats=$(sudo timeout 3 "$XRAY_BIN" api statsquery -server=127.0.0.1:10085 2>/dev/null) || true
        if [[ -n "$stats" ]]; then
            fd=$(printf '%s' "$stats" | grep -A1 'downlink' | grep 'value' | \
                grep -oE '[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?' | awk '{s+=$1}END{printf "%.0f",s+0}')
            fu=$(printf '%s' "$stats" | grep -A1 'uplink'   | grep 'value' | \
                grep -oE '[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?' | awk '{s+=$1}END{printf "%.0f",s+0}')
            bd=$(jq -r '.down//0' "$SESSION_BYTES_FILE" 2>/dev/null || echo 0)
            bu=$(jq -r '.up//0'   "$SESSION_BYTES_FILE" 2>/dev/null || echo 0)
            sd=$(awk -v s="${fd:-0}" -v b="$bd" 'BEGIN{d=s-b; printf "%.0f",(d<0?0:d)}')
            su=$(awk -v s="${fu:-0}" -v b="$bu" 'BEGIN{d=s-b; printf "%.0f",(d<0?0:d)}')
        fi
    fi
    printf '%s %s' \
        "$(awk -v a="$svd" -v b="$sd" 'BEGIN{printf "%.0f",a+b}')" \
        "$(awk -v a="$svu" -v b="$su" 'BEGIN{printf "%.0f",a+b}')"
}

reset_session_bytes_baseline() {
    _atomic_write "$SESSION_BYTES_FILE" '{"down":0,"up":0}'
}

save_session_uptime() {
    local ss now elapsed prev
    ss=$(cat "$SESSION_START_FILE" 2>/dev/null || date +%s)
    now=$(date +%s)
    elapsed=$(( now - ss ))
    (( elapsed < 0    )) && elapsed=0
    (( elapsed > 3600 )) && elapsed=3600
    prev=$(cat "$TOTAL_UPTIME_FILE" 2>/dev/null || echo 0)
    printf '%s\n' $(( prev + elapsed )) > "$TOTAL_UPTIME_FILE"
    printf '%s\n' "$now"               > "$SESSION_START_FILE"
}

stop_xray() {
    save_xray_stats 2>/dev/null || true
    local p
    p=$(cat "$XRAY_PID_FILE" 2>/dev/null || true)
    if ! xray_pid_matches "$p"; then
        p=$(pgrep -f "$XRAY_BIN run -c $CONFIG_FILE" | head -1 || true)
    fi
    if xray_pid_matches "$p" && sudo kill -0 "$p" 2>/dev/null; then
        sudo kill "$p" >/dev/null 2>&1 || true
        sleep 0.5
        if sudo kill -0 "$p" 2>/dev/null; then
            sudo kill -9 "$p" >/dev/null 2>&1 || true
        fi
    fi
    rm -f "$XRAY_PID_FILE" 2>/dev/null || true
    sleep 0.5
}

start_xray() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "  ${RED}✖ No config found. Generate one first (Option 2).${NC}"
        return 1
    fi
    local launch_cmd pid
    launch_cmd=$(printf 'nohup %q run -c %q </dev/null >%q 2>&1 & printf "%%s\n" "$!"' \
        "$XRAY_BIN" "$CONFIG_FILE" "$LOG_DIR/xray.log")
    stop_xray
    reset_session_bytes_baseline
    pid=$(sudo bash -c "$launch_cmd" 2>/dev/null || true)
    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        echo -e "  ${RED}✖ Failed to start Xray.${NC}"
        return 1
    fi
    printf '%s\n' "$pid" > "$XRAY_PID_FILE"
}

wait_for_port() {
    local i=0
    echo -ne "  ${GREEN}⠋${NC} ${DIM}Initializing engine...${NC} "
    while ! is_port_open && (( i < 15 )); do sleep 1; i=$((i + 1)); done
    echo ""
    is_port_open
}

_background_tasks() {
    set +e
    local tick=0
    while true; do
        sleep 60
        if [[ "$PORT_DOMAIN" == unknown-codespace* ]]; then
            local n; n=$(_detect_codespace_name 2>/dev/null || true)
            if [[ -n "$n" && "$n" != "unknown-codespace" ]]; then
                CODESPACE_NAME="$n"
                PORT_DOMAIN="${CODESPACE_NAME}-${XRAY_PORT}.app.github.dev"
            fi
        fi
        [[ -f "$CONFIG_FILE" ]] || continue
        ensure_codespace_port_public >/dev/null 2>&1 || true
        if ! xray_running; then
            start_xray >/dev/null 2>&1 || true
            sleep 3
            ensure_codespace_port_public >/dev/null 2>&1 || true
        fi
        save_xray_stats    >/dev/null 2>&1 || true
        save_session_uptime >/dev/null 2>&1 || true
        (( ++tick >= 3 )) && { fetch_remote_message; tick=0; }
    done
}

start_background_tasks() {
    if [[ -f "$BG_TASKS_PID" ]]; then
        local p; p=$(cat "$BG_TASKS_PID" 2>/dev/null || true)
        [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && return 0
    fi
    _background_tasks </dev/null >/dev/null 2>&1 &
    printf '%s\n' $! > "$BG_TASKS_PID"
    disown 2>/dev/null || true
}

format_bytes() {
    awk -v b="${1:-0}" 'BEGIN{
        if      (b < 1048576)    printf "%.2f KB", b / 1024
        else if (b < 1073741824) printf "%.2f MB", b / 1048576
        else                     printf "%.2f GB", b / 1073741824
    }'
}

estimate_quota() {
    local prev ss now elapsed total rem h_used m_used h_left m_left dtime
    prev=$(cat "$TOTAL_UPTIME_FILE" 2>/dev/null || echo 0)
    ss=$(cat "$SESSION_START_FILE" 2>/dev/null || date +%s)
    now=$(date +%s); elapsed=$(( now - ss ))
    (( elapsed < 0    )) && elapsed=0
    (( elapsed > 3600 )) && elapsed=3600
    total=$(( prev + elapsed ))
    rem=$(( 216000 - total )); (( rem < 0 )) && rem=0
    h_used=$(( total / 3600 ));   m_used=$(( (total % 3600) / 60 ))
    h_left=$(( rem   / 3600 ));   m_left=$(( (rem   % 3600) / 60 ))
    dtime=$(date -d "+${rem} seconds" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "N/A")
    echo -e "  ${GREEN}● Codespace Quota${NC}"
    echo -e "  Total Used : ${WHITE}${h_used}h ${m_used}m${NC}"
    echo -e "  Remaining  : ${GREEN}${h_left}h ${m_left}m${NC} ${DIM}(of 60h tier)${NC}"
    echo -e "  Depletion  : ${DIM}${dtime}${NC}"
}

show_resource_stats() {
    refresh_screen
    echo -e "\n  ${GREEN}● Live Resource Stats${NC}"
    local xpid cpu mem_kb mem_mb
    xpid=$(pgrep -x "xray" | head -1 || pgrep -f "$XRAY_BIN run" | head -1 || true)
    if [[ -n "$xpid" ]]; then
        read -r cpu mem_kb <<< "$(ps -p "$xpid" -o %cpu,rss --no-headers 2>/dev/null || echo '0 0')"
        mem_mb=$(awk "BEGIN{printf \"%.1f\",${mem_kb:-0}/1024}")
        echo -e "  Engine : ${GREEN}Active${NC} (PID $xpid)"
        echo -e "  CPU    : ${WHITE}${cpu}%${NC}"
        echo -e "  Memory : ${WHITE}${mem_mb} MB${NC}"
    else
        echo -e "  Engine : ${RED}Offline${NC}"
    fi
    echo ""
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
}

check_port_visibility() {
    if ! is_port_open; then
        refresh_screen
        echo -e "  ${RED}✖ Engine is not running!${NC}"
        echo -e "  ${DIM}Start the engine first (Option 3).${NC}\n"
        echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
        return 1
    fi
    ensure_codespace_port_public
}

generate_config() {
    uuidgen > "$UUID_FILE"
    local uuid; uuid=$(cat "$UUID_FILE")
    cat > "$CONFIG_FILE" << JSONEOF
{
  "log": { "loglevel": "warning", "access": "none", "error": "${LOG_DIR}/xray-error.log" },
  "stats": {},
  "api": { "tag": "api", "services": ["StatsService"] },
  "policy": {
    "system": { "statsInboundDownlink": true, "statsInboundUplink": true },
    "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true, "handshake": 3, "connIdle": 600, "uplinkOnly": 1, "downlinkOnly": 2, "bufferSize": 512 } }
  },
  "dns": {
    "hosts": { "dns.google": "8.8.8.8", "dns.cloudflare": "1.1.1.1" },
    "servers": [
      { "address": "https://1.1.1.1/dns-query", "domains": ["geosite:geolocation-!cn"], "queryStrategy": "UseIPv4" },
      "8.8.4.4", "localhost"
    ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "tag": "vless-in", "port": ${XRAY_PORT}, "listen": "0.0.0.0", "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${uuid}", "flow": "", "level": 0, "email": "user@G2rayXCodeLeafy" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp", "security": "none",
        "xhttpSettings": { "mode": "packet-up", "path": "/", "maxUploadSize": 2000000, "maxConcurrentUploads": 16 }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": false }
    },
    { "listen": "127.0.0.1", "port": 10085, "protocol": "dokodemo-door", "settings": { "address": "127.0.0.1" }, "tag": "api" }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom",   "settings": { "domainStrategy": "UseIPv4" } },
    { "tag": "block",  "protocol": "blackhole",  "settings": { "response": { "type": "http" } } }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "inboundTag": ["api"],                                   "outboundTag": "api",    "type": "field" },
      { "type": "field", "ip":       ["geoip:private"],          "outboundTag": "block"  },
      { "type": "field", "protocol": ["bittorrent"],             "outboundTag": "block"  },
      { "type": "field", "domain":   ["geosite:category-ads-all"], "outboundTag": "block" }
    ]
  }
}
JSONEOF
    if start_xray && wait_for_port >/dev/null 2>&1; then
        echo -e "  ${GREEN}✔ Engine started on port ${XRAY_PORT}.${NC}"
    else
        echo -e "  ${YELLOW}⚠ Engine may not have bound to port ${XRAY_PORT}.${NC}"
    fi
    ensure_codespace_port_public
}

generate_link() {
    local uuid; uuid=$(cat "$UUID_FILE" 2>/dev/null) || { printf ''; return 1; }
    [[ -z "$uuid" ]] && { printf ''; return 1; }
    local address; address=$(resolve_domain_ip "$PORT_DOMAIN")
    printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&alpn=h2&insecure=1&allowInsecure=1&type=xhttp&host=%s&path=%%2F&mode=packet-up#G2rayXCodeLeafy|%s' \
        "$uuid" "$address" "$XRAY_PORT" "$PORT_DOMAIN" "$PORT_DOMAIN" "${GITHUB_USER:-User}"
}

do_donate_config() {
    check_port_visibility || return 0
    local vless; vless=$(generate_link)
    if [[ -z "$vless" ]]; then
        echo -e "  ${RED}✖ No config found. Generate one first (Option 2).${NC}"
        sleep 2; return 0
    fi
    refresh_screen
    echo -e "\n  ${GREEN}● Donate Configuration${NC}"
    echo -e "  ${WHITE}Help others connect securely for free.${NC}"
    echo -e "  ${DIM}• No speed or quota penalty.\n  • IP is already public; no extra risk.${NC}\n"
    echo -ne "  ${GREEN}╰─❯${NC} Confirm donation? (y/n): "
    read -r d
    if [[ "$d" =~ ^[Yy]$ ]]; then
        send_to_vless_forwarder "$vless"
        touch "$DATA_DIR/.prompted_$(printf '%s' "$vless" | md5sum | awk '{print $1}')"
    fi
    sleep 2
}

force_reconnect() {
    local no_prompt="${1:-}"
    echo -e "\n  ${GREEN}⠋${NC} ${WHITE}Running Clean Hard Restart & Reconnect Sequence...${NC}\n"

    echo -ne "  ${DIM}├─${NC} Detect Identity   : "
    CODESPACE_NAME=$(_detect_codespace_name 2>/dev/null || true)
    PORT_DOMAIN="${CODESPACE_NAME}-${XRAY_PORT}.app.github.dev"
    [[ "$CODESPACE_NAME" == "unknown-codespace" ]] \
        && echo -e "${RED}Failed${NC}" \
        || echo -e "${GREEN}${CODESPACE_NAME}${NC}"

    echo -ne "  ${DIM}├─${NC} Force Kill Engine : "
    stop_xray >/dev/null 2>&1
    echo -e "${GREEN}Done${NC}"

    echo -ne "  ${DIM}├─${NC} Start Engine      : "
    start_xray >/dev/null 2>&1 && wait_for_port >/dev/null 2>&1 \
        && echo -e "${GREEN}OK${NC}" \
        || echo -e "${RED}Failed${NC}"

    echo -ne "  ${DIM}├─${NC} Expose Tunnel     : "
    ensure_codespace_port_public >/dev/null 2>&1
    echo -e "${GREEN}Done${NC}"

    echo -ne "  ${DIM}╰─${NC} Verify External   : "
    local ok=false code
    for _i in 1 2 3 4; do
        code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "https://${PORT_DOMAIN}" 2>/dev/null || echo "0")
        [[ "$code" =~ ^[1-9][0-9]{2}$ ]] && { ok=true; break; }
        sleep 2
    done
    [[ "$ok" == true ]] \
        && echo -e "${GREEN}Live!${NC}\n" \
        || echo -e "${YELLOW}Pending / Delayed${NC}\n"

    [[ "$no_prompt" == "--no-prompt" ]] && { sleep 1; return; }
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
}

if [[ "${1:-}" == "--silent-start" ]]; then
    stop_xray >/dev/null 2>&1
    if [[ -f "$CONFIG_FILE" ]] && start_xray >/dev/null 2>&1 && wait_for_port >/dev/null 2>&1; then
        ensure_codespace_port_public
    fi
    start_background_tasks
    exit 0
fi

trap 'save_xray_stats 2>/dev/null||true; save_session_uptime 2>/dev/null||true
      echo -e "\n  ${DIM}Goodbye.${NC}"; exit 0' EXIT INT TERM

check_for_updates "$@"
start_background_tasks
fetch_remote_message
enable_anti_sleep

if [[ ! -f "$CONFIG_FILE" ]]; then
    refresh_screen
    echo -e "  ${GREEN}● Welcome to G2ray${NC}"
    echo -e "  ${WHITE}No configuration found. First run setup.${NC}\n"
    echo -e "  ${GREEN}1)${NC} Generate Config & Start"
    echo -e "  ${DIM}2)${NC} Exit\n"
    echo -ne "  ${GREEN}╰─❯${NC} "
    read -r setup
    if [[ "$setup" == "1" ]]; then
        generate_config
        echo -e "\n  ${GREEN}✔ Setup complete!${NC}"
        sleep 1
    else
        exit 0
    fi
else
    refresh_screen
    force_reconnect --no-prompt
fi

while true; do
    ( fetch_remote_message >/dev/null 2>&1 & )
    refresh_screen

    if xray_running; then
        _STATUS="${GREEN}▶ RUNNING${NC}"
    else
        _STATUS="${RED}■ STOPPED${NC}"
    fi

    if tmux has-session -t g2ray_keepalive 2>/dev/null; then
        _KA="${GREEN}Enabled${NC}"
    else
        _KA="${DIM}Disabled${NC}"
    fi

    echo -e "  ${WHITE}${B}Engine Status  :${NC} $(echo -e "$_STATUS")"
    echo -e "  ${WHITE}${B}Anti-Sleep Mode:${NC} $(echo -e "$_KA")\n"
    echo -e "  ${WHITE}${B}● CORE CONTROLS${NC}"
    echo -e "   ${GREEN}1)${NC} View Config & QR Code       ${GREEN}4)${NC} Stop Engine"
    echo -e "   ${GREEN}2)${NC} Generate New Config         ${GREEN}5)${NC} Restart Engine"
    echo -e "   ${GREEN}3)${NC} Start Engine                ${GREEN}6)${NC} Force Reconnect"
    echo ""
    echo -e "  ${WHITE}${B}● SYSTEM CONFIGURATION${NC}"
    echo -e "   ${GREEN}7)${NC} Toggle Anti-Sleep Mode"
    echo -e "   ${GREEN}8)${NC} Donate Config"
    echo ""
    echo -e "  ${WHITE}${B}● ANALYTICS & TOOLS${NC}"
    echo -e "   ${GREEN}9)${NC} Data Usage                 ${GREEN}12)${NC} Server Location"
    echo -e "  ${GREEN}10)${NC} Resource Stats             ${GREEN}13)${NC} View Engine Logs"
    echo -e "  ${GREEN}11)${NC} Quota & Uptime"
    echo ""
    echo -e "   ${RED}0)${NC} Exit Panel"
    echo -e "  ${DIM}───────────────────────────────────────────────────────────${NC}"

    if [[ -s "/tmp/g2ray_message.txt" ]]; then
        local_msg=$(sed 's/\r//g' /tmp/g2ray_message.txt 2>/dev/null)
        if [[ "$local_msg" != *"404"* && -n "$(printf '%s' "$local_msg" | tr -d ' \n\t')" ]]; then
            echo -e "  ${YELLOW}📢 Dev Note: ${WHITE}${local_msg}${NC}"
            echo -e "  ${DIM}───────────────────────────────────────────────────────────${NC}"
        fi
    fi

    echo -ne "  ${GREEN}╰─❯${NC} "
    read -r _choice

    case $_choice in
        1)
            check_port_visibility || continue
            _VLESS=$(generate_link)
            [[ -z "$_VLESS" ]] && { echo -e "  ${RED}✖ Error generating link.${NC}"; sleep 2; continue; }
            printf '%s\n' "$_VLESS" > "$MOBILE_CONFIG_FILE"
            _VHASH=$(printf '%s' "$_VLESS" | md5sum | awk '{print $1}')
            _PFLAG="$DATA_DIR/.prompted_${_VHASH}"
            if [[ ! -f "$_PFLAG" ]]; then
                refresh_screen
                echo -e "  ${GREEN}🎉 Node is Ready!${NC}\n"
                echo -e "  ${WHITE}Donate this config to help others connect freely?${NC}"
                echo -e "  ${DIM}(No impact on your speed, quota, or security)${NC}\n"
                echo -ne "  ${GREEN}╰─❯${NC} Donate? (y/n): "
                read -r _share
                [[ "$_share" =~ ^[Yy]$ ]] && { send_to_vless_forwarder "$_VLESS"; sleep 1; }
                touch "$_PFLAG"
            fi
            refresh_screen
            echo -e "  ${GREEN}● Scan to Connect${NC}"
            if command -v qrencode >/dev/null 2>&1; then
                qrencode -m 2 -t ANSIUTF8 "$_VLESS" | sed 's/^/  /'
            else
                echo -e "  ${DIM}(qrencode not installed — QR unavailable)${NC}"
            fi
            echo -e "\n  ${GREEN}● Direct VLESS Link${NC}"
            echo -e "  ${WHITE}${_VLESS}${NC}\n"
            _COUNTRY=$(curl -s --max-time 3 https://ipinfo.io/country </dev/null 2>/dev/null || echo "Unknown")
            if [[ "$_COUNTRY" != "DE" && "$_COUNTRY" != "NL" && "$_COUNTRY" != "Unknown" ]]; then
                echo -e "  ${RED}⚠ WARNING: Codespace is NOT in Germany (${_COUNTRY})!${NC}"
                echo -e "  ${DIM}Set region to 'Europe West' in GitHub for optimal speeds.${NC}\n"
            fi
            echo -e "  ${DIM}Not working? Visit:${NC} ${GREEN}https://code-leafy.github.io/NetLeafy${NC}\n"
            echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
            ;;
        2)
            echo -e "\n  ${YELLOW}⚠ Overwrite current config and restart engine?${NC}"
            echo -ne "  ${GREEN}╰─❯${NC} Proceed (y/n): "
            read -r _confirm
            [[ "$_confirm" =~ ^[Yy]$ ]] && { generate_config; sleep 1; }
            ;;
        3)
            if xray_running; then
                echo -e "\n  ${WHITE}Engine is already running.${NC}"
            else
                if start_xray && wait_for_port; then
                    ensure_codespace_port_public
                fi
            fi
            sleep 1
            ;;
        4)
            stop_xray
            echo -e "\n  ${RED}■ Engine stopped.${NC}"
            sleep 1
            ;;
        5)
            if start_xray && wait_for_port; then
                ensure_codespace_port_public
            fi
            sleep 1
            ;;
        6) force_reconnect ;;
        7)
            if tmux has-session -t g2ray_keepalive 2>/dev/null; then
                tmux kill-session -t g2ray_keepalive
                echo -e "\n  ${RED}■ Anti-Sleep disabled.${NC}"
            else
                enable_anti_sleep
                echo -e "\n  ${GREEN}▶ Anti-Sleep enabled.${NC}"
            fi
            sleep 2
            ;;
        8) do_donate_config ;;
        9)
            refresh_screen
            read -r _TD _TU <<< "$(get_data_usage)"
            _TD=${_TD:-0}; _TU=${_TU:-0}
            if (( _TD == 0 && _TU == 0 )); then
                echo -e "\n  ${DIM}No traffic data recorded yet. Connect and browse first.${NC}\n"
            else
                _TT=$(( _TD + _TU ))
                echo -e "\n  ${GREEN}● Data Usage (All Sessions)${NC}"
                echo -e "  Download (RX) : ${WHITE}$(format_bytes "$_TD")${NC}"
                echo -e "  Upload   (TX) : ${WHITE}$(format_bytes "$_TU")${NC}"
                echo -e "  Total Traffic : ${GREEN}$(format_bytes "$_TT")${NC}\n"
            fi
            echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
            ;;
        10) show_resource_stats ;;
        11)
            refresh_screen; echo ""
            estimate_quota
            echo ""; echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
            ;;
        12)
            refresh_screen
            echo -e "\n  ${DIM}Fetching server details...${NC}\n"
            if command -v jq >/dev/null 2>&1; then
                _RES=$(curl -sf -m 5 https://ipinfo.io/json 2>/dev/null || echo "{}")
                _IP=$(printf '%s' "$_RES" | jq -r '.ip // empty' 2>/dev/null || true)
                if [[ -z "$_IP" ]]; then
                    echo -e "  ${RED}✖ Could not fetch location.${NC}"
                else
                    echo -e "  ${GREEN}● Server Location${NC}"
                    echo -e "  IP       : ${GREEN}$(printf '%s' "$_RES" | jq -r '.ip')${NC}"
                    echo -e "  Location : ${WHITE}$(printf '%s' "$_RES" | jq -r '.city'), $(printf '%s' "$_RES" | jq -r '.country')${NC}"
                    echo -e "  ISP/Host : ${WHITE}$(printf '%s' "$_RES" | jq -r '.org')${NC}"
                fi
            else
                echo -e "  ${RED}✖ jq not installed.${NC}"
            fi
            echo ""; echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
            ;;
        13)
            refresh_screen
            echo -e "\n  ${GREEN}● Live Engine Logs${NC}"
            if [[ -s "$LOG_DIR/xray.log" ]]; then
                tail -n 15 "$LOG_DIR/xray.log" | sed 's/^/  /'
            else
                echo -e "  ${DIM}Log file empty or missing.${NC}"
            fi
            echo -e "\n  ${DIM}(Log level: warning — empty log means no errors)${NC}\n"
            echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
            ;;
        0) echo -e "\n  ${GREEN}Exiting G2ray Panel...${NC}"; exit 0 ;;
        *) echo -e "  ${RED}✖ Invalid option.${NC}"; sleep 1 ;;
    esac
done
