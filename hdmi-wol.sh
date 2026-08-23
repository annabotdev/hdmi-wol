#!/bin/bash
# HDMI Smart Wake-on-LAN & Source Switcher
# A state-aware hardware abstraction layer for Tizen/WebOS displays

# Auto-elevate privileges for actions requiring system changes
if [ "$EUID" -ne 0 ]; then
    case "$1" in
        --install|--uninstall|--disable|--sync|-s|--pair|--force-pair|--repair|--update|--config)
            exec sudo "$0" "$@"
            ;;
    esac
fi

# Core Paths
CACHE_DIR="/var/cache/hdmi_wol"
LOG_FILE="$CACHE_DIR/service.log"
LOCK_FILE="/tmp/hdmi_smart_wol.lock"
TOKEN_FILE="$CACHE_DIR/samsung_token.txt"
CONFIG_FILE="/etc/hdmi_smart_wol.conf"
SERVICE_FILE="/etc/systemd/system/hdmi-smart-wol.service"
HOTPLUG_SERVICE="/etc/systemd/system/hdmi-hotplug-wol.service"
UDEV_RULE="/etc/udev/rules.d/99-hdmi-hotplug-wol.rules"
GLOBAL_BIN="/usr/local/bin/hdmi-wol"

# Generate default config if missing
if [ ! -f "$CONFIG_FILE" ]; then
    sudo bash -c "cat > $CONFIG_FILE" << 'CONFEOF'
# HDMI Smart WoL - Global Configuration

# Update URL (Hardcoded default)
GITHUB_REPO_URL="https://raw.githubusercontent.com/annabotdev/hdmi-wol/main/hdmi-wol.sh"

# Execution Thresholds
MAX_POLL_ATTEMPTS=20
WOL_BROADCAST_IP="255.255.255.255"

# Hardware Overrides (Leave blank for auto-discovery)
FORCE_MAC=""
FORCE_IP=""
FORCE_BRAND=""
CONFEOF
    chmod 644 "$CONFIG_FILE" 2>/dev/null || true
fi

source "$CONFIG_FILE"

ensure_cache_dir() {
    if [ ! -d "$CACHE_DIR" ]; then
        mkdir -p "$CACHE_DIR" 2>/dev/null || sudo mkdir -p "$CACHE_DIR"
        chmod 777 "$CACHE_DIR" 2>/dev/null || true
    fi
}

log_msg() {
    local msg="$1"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    >&2 echo "[$timestamp] $msg"
    ensure_cache_dir
    echo "[$timestamp] $msg" >> "$LOG_FILE" 2>/dev/null || true
    chmod 666 "$LOG_FILE" 2>/dev/null || true
}

get_wol_cmd() {
    if command -v ether-wake &>/dev/null; then echo "ether-wake"
    elif command -v wakeonlan &>/dev/null; then echo "wakeonlan"
    elif [ -x "/usr/local/bin/bash_wol" ]; then echo "/usr/local/bin/bash_wol"
    else echo ""; fi
}

check_and_install_deps() {
    log_msg "[DEPS] Verifying system dependencies..."
    local wol_bin=$(get_wol_cmd)

    if [ -z "$wol_bin" ]; then
        log_msg "[DEPS] Installing native zero-dependency WoL transmitter..."
        cat << "SUBEOF" | sudo tee /usr/local/bin/bash_wol > /dev/null
#!/bin/bash
TARGET_MAC="\$1"
BCAST="\$2"
[ -z "\$BCAST" ] && BCAST="255.255.255.255"
[ -z "\$TARGET_MAC" ] && exit 1
python3 -c "
import socket, sys
mac = sys.argv[1].replace(':', '').replace('-', '')
bcast = sys.argv[2]
if len(mac) != 12: sys.exit(1)
payload = bytes.fromhex('FF' * 6 + mac * 16)
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
sock.sendto(payload, (bcast, 9))
" "\$TARGET_MAC" "\$BCAST" 2>/dev/null
SUBEOF
        sudo chmod +x /usr/local/bin/bash_wol
        log_msg "[DEPS] Native WoL helper installed at /usr/local/bin/bash_wol"
    else
        log_msg "[DEPS] Active WoL engine: $wol_bin"
    fi
}

get_edid_path() {
    local edid_file status_file
    for edid_file in /sys/class/drm/card*-HDMI-*/edid /sys/class/drm/card*-*/edid; do
        [ -f "$edid_file" ] || continue
        status_file="$(dirname "$edid_file")/status"
        if [ -f "$status_file" ] && grep -q "^connected" "$status_file" 2>/dev/null; then
            echo "$edid_file"
            return 0
        fi
    done
    return 1
}

get_edid_info() {
    local edid_path=$(get_edid_path)
    if [ -n "$edid_path" ]; then
        local ascii_id=$(strings "$edid_path" 2>/dev/null | grep -vE "^[0-9]+$" | tr -cd "[:alnum:]" | head -n 1)
        if [ -n "$ascii_id" ]; then echo "$ascii_id"
        else hexdump -n 16 -e '16/1 "%02x"' "$edid_path" 2>/dev/null
        fi
        return 0
    fi
    return 1
}

get_tv_brand() {
    if [ -n "$FORCE_BRAND" ]; then echo "$FORCE_BRAND"; return; fi
    local edid_path=$(get_edid_path)
    [ -z "$edid_path" ] && { echo "GENERIC"; return; }
    local pnp_hex=$(hexdump -s 8 -n 2 -e '2/1 "%02x"' "$edid_path" 2>/dev/null)
    local raw_strings=$(strings "$edid_path" 2>/dev/null)
    if [ "$pnp_hex" = "4c2d" ] || echo "$raw_strings" | grep -iE "SAM|Samsung" &>/dev/null; then
        echo "SAMSUNG"
    else
        echo "GENERIC"
    fi
}

get_hdmi_port_num() {
    local edid_path=$(get_edid_path)
    [ -z "$edid_path" ] && { echo "1"; return; }
    python3 -c "
import sys
try:
    data = open('$edid_path', 'rb').read()
    idx = data.find(b'\x03\x0c\x00')
    if idx != -1:
        port = (data[idx+3] >> 4) & 0x0F
        if 1 <= port <= 4:
            print(port); sys.exit(0)
except Exception: pass
print('1')
"
}

populate_arp_table() {
    local bcasts=$(ip -o -4 addr show | awk '{print $6}' | grep -v "^$" | grep -v "127.0.0.1")
    for b in $bcasts; do
        ping -c 1 -b -W 1 "$b" >/dev/null 2>&1 || true
    done
}

discover_samsung_via_api() {
    local tmp_results=$(mktemp)
    local candidate_ips=()
    mapfile -t candidate_ips < <(ip neigh show 2>/dev/null | awk '{print $1}' | grep -E "^([0-9]{1,3}\.){3}[0-9]{1,3}$")
    if [ ${#candidate_ips[@]} -eq 0 ] || command -v arp &>/dev/null; then
        mapfile -t arp_ips < <(arp -an 2>/dev/null | grep -Eo "([0-9]{1,3}\.){3}[0-9]{1,3}")
        candidate_ips+=("${arp_ips[@]}")
    fi
    local unique_ips=($(printf "%s\n" "${candidate_ips[@]}" | sort -u))
    for target_ip in "${unique_ips[@]}"; do
        (
            local response=$(curl -s --connect-timeout 1.5 -m 2.0 "http://${target_ip}:8001/api/v2/")
            if [ -n "$response" ] && echo "$response" | grep -iq "Samsung"; then
                local mac=$(echo "$response" | grep -oEi '"wifiMac":"[^"]*"' | head -n1 | cut -d'"' -f4)
                [ -z "$mac" ] && mac=$(echo "$response" | grep -oEi '"mac":"[^"]*"' | head -n1 | cut -d'"' -f4)
                local name=$(echo "$response" | grep -oEi '"name":"[^"]*"' | head -n 1 | cut -d'"' -f4)
                local model=$(echo "$response" | grep -oEi '"modelName":"[^"]*"' | head -n1 | cut -d'"' -f4)
                if [ -n "$mac" ]; then
                    echo "$mac|$target_ip|${name:-Samsung TV}|${model:-SmartTV}" >> "$tmp_results"
                fi
            fi
        ) &
    done
    wait
    if [ -s "$tmp_results" ]; then
        cat "$tmp_results"
        rm -f "$tmp_results"
        return 0
    fi
    rm -f "$tmp_results"
    return 1
}

discover_and_select_mac() {
    local brand="$1"
    local edid_id="$2"
    
    if [ -n "$FORCE_MAC" ] && [ -n "$FORCE_IP" ]; then
        log_msg "[DISCOVERY] Using config overrides -> MAC: $FORCE_MAC, IP: $FORCE_IP"
        echo "${FORCE_MAC}:${FORCE_IP}"
        return 0
    fi

    log_msg "[DISCOVERY] Querying local subnet nodes on port 8001..."
    populate_arp_table >/dev/null 2>&1
    if [ "$brand" = "SAMSUNG" ]; then
        local api_matches=()
        mapfile -t api_matches < <(discover_samsung_via_api)
        if [ ${#api_matches[@]} -ge 1 ]; then
            local matched_mac=$(echo "${api_matches[0]}" | cut -d"|" -f1 | tr '[:upper:]' '[:lower:]')
            local matched_ip=$(echo "${api_matches[0]}" | cut -d"|" -f2)
            local matched_name=$(echo "${api_matches[0]}" | cut -d"|" -f3)
            local matched_model=$(echo "${api_matches[0]}" | cut -d"|" -f4)
            log_msg "[DISCOVERY] Match verified: $matched_name ($matched_model) -> MAC: $matched_mac, IP: $matched_ip"
            echo "${matched_mac}:${matched_ip}"
            return 0
        fi
    fi
    log_msg "[DISCOVERY] Warning: No matching TV nodes found via API scan."
    echo "NO_CANDIDATES"
    return 1
}

get_samsung_power_state() {
    local ip="$1"
    local raw_info=$(curl -s --connect-timeout 1.5 -m 2.0 "http://${ip}:8001/api/v2/" 2>/dev/null)
    [ -z "$raw_info" ] && { echo "OFFLINE"; return; }
    local pstate=$(echo "$raw_info" | grep -oEi '"PowerState":"[^"]*"' | cut -d'"' -f4 | tr '[:upper:]' '[:lower:]')
    echo "${pstate:-UNKNOWN}"
}

pair_samsung_websocket() {
    local ip="$1"
    [ -z "$ip" ] && return 1
    
    >&2 echo ""
    >&2 echo "=================================================="
    >&2 echo "       Samsung TV WebSocket Authentication        "
    >&2 echo "=================================================="
    >&2 echo "Connecting to $ip on port 8002..."
    >&2 echo "👉 LOOK AT YOUR TV SCREEN AND CLICK 'ALLOW' WITH YOUR REMOTE"
    >&2 echo "=================================================="
    log_msg "[PAIRING] Requesting WebSocket token from TV at $ip:8002..."

    local result=$(python3 -c "
import socket, ssl, json, base64, time, sys
tv_ip = '$ip'
app_name = base64.b64encode(b'Bazzite Console').decode('utf-8')
url_path = '/api/v2/channels/samsung.remote.control?name=' + app_name
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
try:
    s = socket.create_connection((tv_ip, 8002), timeout=15)
    ss = ctx.wrap_socket(s)
    handshake = (
        'GET ' + url_path + ' HTTP/1.1\r\n'
        'Host: ' + tv_ip + ':8002\r\n'
        'Upgrade: websocket\r\n'
        'Connection: Upgrade\r\n'
        'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
        'Sec-WebSocket-Version: 13\r\n\r\n'
    )
    ss.sendall(handshake.encode())
    start_t = time.time()
    while time.time() - start_t < 25:
        data = ss.recv(4096)
        if not data: break
        raw_text = data.decode('utf-8', errors='ignore')
        if 'token' in raw_text:
            idx = raw_text.find('{')
            if idx != -1:
                try:
                    parsed = json.loads(raw_text[idx:])
                    token = parsed.get('data', {}).get('token')
                    if token: print(token); sys.exit(0)
                except Exception: pass
except Exception: pass
sys.exit(1)
")
    local clean_result=$(echo "$result" | tail -n 1)
    if [ -n "$clean_result" ]; then
        ensure_cache_dir
        echo "$clean_result" > "$TOKEN_FILE"
        log_msg "[PAIRING] Successful! Token saved: $clean_result"
        >&2 echo "[✓] Pairing successful! Token saved."
        return 0
    else
        log_msg "[PAIRING] Failed: Timed out or rejected on TV."
        >&2 echo "[-] Pairing timed out or dismissed on TV."
        return 1
    fi
}

dispatch_wol_magic_packet() {
    local mac="$1"
    log_msg "[WOL] Transmitting broadcast magic packet to MAC: $mac"
    python3 -c "
import socket, sys, subprocess
mac_str = '$mac'.replace(':', '').replace('-', '')
if len(mac_str) != 12: sys.exit(1)
payload = bytes.fromhex('FF' * 6 + mac_str * 16)
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
try:
    sock.sendto(payload, ('$WOL_BROADCAST_IP', 9))
    sock.sendto(payload, ('$WOL_BROADCAST_IP', 7))
except Exception: pass
try:
    subnets = subprocess.check_output(['ip', '-o', '-4', 'addr', 'show']).decode()
    for line in subnets.splitlines():
        parts = line.strip().split()
        if 'brd' in parts:
            sock.sendto(payload, (parts[parts.index('brd') + 1], 9))
except Exception: pass
"
}

send_samsung_macro() {
    local ip="$1"
    local target_key="$2"
    local token=""
    [ -s "$TOKEN_FILE" ] && token=$(cat "$TOKEN_FILE" | tr -d '[:space:]')
    [ -z "$token" ] || [ -z "$ip" ] && return 1

    python3 -c "
import socket, ssl, json, base64, struct, time, sys

tv_ip = '$ip'
token = '$token'
target_key = '$target_key'

app_name = base64.b64encode(b'Bazzite Console').decode('utf-8')
url_path = '/api/v2/channels/samsung.remote.control?name=' + app_name + '&token=' + token
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

def build_frame(p):
    l = len(p)
    mask = b'\x12\x34\x56\x78'
    h = bytearray([0x81, 0x80 | (l if l < 126 else 126)])
    if l >= 126: h.extend(struct.pack('>H', l))
    h.extend(mask)
    return bytes(h + bytearray([b ^ mask[i % 4] for i, b in enumerate(p)]))

max_retries = 3
for attempt in range(1, max_retries + 1):
    try:
        s = socket.create_connection((tv_ip, 8002), timeout=3.0)
        ss = ctx.wrap_socket(s)
        handshake = (
            'GET ' + url_path + ' HTTP/1.1\r\n'
            'Host: ' + tv_ip + ':8002\r\n'
            'Upgrade: websocket\r\n'
            'Connection: Upgrade\r\n'
            'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
            'Sec-WebSocket-Version: 13\r\n\r\n'
        )
        ss.sendall(handshake.encode())
        resp = ss.recv(2048).decode('utf-8', errors='ignore')
        if '101' not in resp:
            ss.close()
            time.sleep(1.0)
            continue

        keys = [target_key, 'KEY_ENTER', 'KEY_EXIT']
        for k in keys:
            payload = json.dumps({'method': 'ms.remote.control', 'params': {'Cmd': 'Click', 'DataOfCmd': k, 'Option': 'false', 'TypeOfRemote': 'SendRemoteKey'}}).encode('utf-8')
            ss.sendall(build_frame(payload))
            time.sleep(0.3)
                
        time.sleep(0.2)
        ss.close()
        sys.exit(0)
    except Exception as e:
        time.sleep(1.0)

sys.exit(1)
" && return 0
    return 1
}

send_brand_power_cmd() {
    local mac="$1"
    local ip="$2"
    local brand="$3"
    log_msg "[WOL] Executing wake sequence for $brand ($mac | IP: ${ip:-N/A})"
    
    local attempt=1
    local max_attempts=$MAX_POLL_ATTEMPTS
    while [ $attempt -le $max_attempts ]; do
        local pstate=$(get_samsung_power_state "$ip")
        log_msg "[WOL] PowerState poll attempt $attempt: [$pstate]"
        if [ "$pstate" = "on" ]; then
            log_msg "[WOL] Panel confirmed ON."
            if [ "$attempt" -gt 3 ]; then
                log_msg "[WOL] OS Booting: Giving security daemon 3s to initialize..."
                sleep 3
            else
                sleep 1
            fi
            break
        fi
        dispatch_wol_magic_packet "$mac"
        sleep 2
        ((attempt++))
    done

    local port_num=$(get_hdmi_port_num)
    local target_key="KEY_EXT4${port_num}"
    
    log_msg "[WOL] Sending direct input switch to HDMI ${port_num} ($target_key)..."
    if ! send_samsung_macro "$ip" "$target_key"; then
        log_msg "[WOL] Input switch failed: Token rejected or TV unreachable."
    fi
}

manual_sync() {
    ensure_cache_dir
    local force_flag="$1"
    EDID_ID=$(get_edid_info)
    [ -z "$EDID_ID" ] && { log_msg "[SYNC] Error: No active HDMI display found."; exit 1; }
    TV_BRAND=$(get_tv_brand)
    CACHE_FILE="$CACHE_DIR/${EDID_ID}.mac"

    log_msg "[SYNC] Syncing display identifier: $EDID_ID ($TV_BRAND)"
    local raw_discovery=$(discover_and_select_mac "$TV_BRAND" "$EDID_ID")
    local CLEAN_RESULT=$(echo "$raw_discovery" | tail -n 1)

    if [ -n "$CLEAN_RESULT" ] && [ "$CLEAN_RESULT" != "NO_CANDIDATES" ]; then
        echo "$CLEAN_RESULT" > "$CACHE_FILE"
        log_msg "[SYNC] Binding successfully cached -> $CLEAN_RESULT"
        local ip=$(echo "$CLEAN_RESULT" | cut -d":" -f7)
        if [ "$TV_BRAND" = "SAMSUNG" ]; then
            if [ ! -s "$TOKEN_FILE" ] || [ "$force_flag" = "--force" ]; then
                pair_samsung_websocket "$ip"
            else
                log_msg "[SYNC] TV is already paired. Skipping token request."
                >&2 echo "[✓] TV is already synced and paired!"
            fi
        fi
    fi
}

run_wol_sync() {
    touch "$LOCK_FILE" 2>/dev/null || true
    chmod 666 "$LOCK_FILE" 2>/dev/null || true
    exec 200>"$LOCK_FILE"
    flock -n 200 || { log_msg "[RUN] Wake routine already locked in another process."; exit 0; }

    log_msg "[RUN] Wake trigger fired from system event."
    ensure_cache_dir
    EDID_ID=$(get_edid_info)
    [ -z "$EDID_ID" ] && { log_msg "[RUN] Aborted: No active display detected."; exit 0; }
    TV_BRAND=$(get_tv_brand)
    CACHE_FILE="$CACHE_DIR/${EDID_ID}.mac"

    if [ -s "$CACHE_FILE" ]; then
        CACHED_ENTRY=$(cat "$CACHE_FILE" | tail -n 1)
        CACHED_MAC=$(echo "$CACHED_ENTRY" | cut -d":" -f1-6)
        CACHED_IP=$(echo "$CACHED_ENTRY" | cut -d":" -f7)
        send_brand_power_cmd "$CACHED_MAC" "$CACHED_IP" "$TV_BRAND"
    else
        log_msg "[RUN] No cache found for $EDID_ID. Running automatic sync..."
        manual_sync
    fi
}

update_script() {
    log_msg "[UPDATE] Checking for updates from $GITHUB_REPO_URL..."
    local tmp_dl=$(mktemp)
    local cache_url="${GITHUB_REPO_URL}?cb=$(date +%s)"
    if curl -sL "$cache_url" -o "$tmp_dl"; then
        if grep -q "#!/bin/bash" "$tmp_dl"; then
            if [ -f "$GLOBAL_BIN" ]; then
                local current_hash=$(tr -d '\r' < "$GLOBAL_BIN" | sha256sum | awk '{print $1}')
                local remote_hash=$(tr -d '\r' < "$tmp_dl" | sha256sum | awk '{print $1}')
                if [ "$current_hash" = "$remote_hash" ]; then
                    echo "[✓] You are already on the latest version! No update needed."
                    rm -f "$tmp_dl"
                    exit 0
                fi
            fi
            sudo mkdir -p "$(dirname "$GLOBAL_BIN")"
            sudo cp "$tmp_dl" "$GLOBAL_BIN"
            sudo chmod +x "$GLOBAL_BIN"
            log_msg "[UPDATE] Successfully updated to latest version."
            echo "[✓] Update complete! New version applied."
            rm -f "$tmp_dl"
        else
            echo "[-] Invalid file downloaded. Update aborted."
            rm -f "$tmp_dl"
        fi
    else
        echo "[-] Network request failed. Update aborted."
    fi
    exit 0
}

copy_to_clipboard() {
    local text="$1"
    if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
        local base64_payload=$(printf "%s" "$text" | base64 | tr -d '\r\n')
        printf "\033]52;c;%s\a" "$base64_payload" > /dev/tty 2>/dev/null && return 0
    fi
    return 1
}

show_logs() {
    echo "=================================================="
    echo "       HDMI Smart WoL History Log (Last 1000)     "
    echo "=================================================="
    local all_logs=""
    if [ -f "$LOG_FILE" ]; then
        all_logs=$(tail -n 1000 "$LOG_FILE")
        echo "$all_logs"
    else
        echo "(No logs found at $LOG_FILE)"
    fi
    echo "=================================================="
    if [ -n "$all_logs" ]; then
        copy_to_clipboard "$all_logs"
        >&2 echo -e "\n[✓] Log output copied to clipboard!"
    fi
    exit 0
}

show_live_status() {
    trap "tput cnorm; clear; exit 0" INT TERM
    tput civis
    local frame=0
    while true; do
        clear
        local brand=$(get_tv_brand)
        local port_num=$(get_hdmi_port_num)
        local pstate="OFFLINE"
        local ip_addr="N/A"
        local model_name="Unknown Display"

        local cache_file=$(ls -t /var/cache/hdmi_wol/*.mac 2>/dev/null | head -n 1)
        if [ -n "$cache_file" ] && [ -s "$cache_file" ]; then
            local entry=$(cat "$cache_file" | tail -n 1)
            ip_addr=$(echo "$entry" | cut -d":" -f7)
            if [ -n "$ip_addr" ] && [ "$brand" = "SAMSUNG" ]; then
                local api_json=$(curl -s --connect-timeout 1.0 -m 1.2 "http://${ip_addr}:8001/api/v2/" 2>/dev/null)
                if [ -n "$api_json" ]; then
                    local raw_state=$(echo "$api_json" | grep -oEi '"PowerState":"[^"]*"' | head -n1 | cut -d'"' -f4 | tr '[:lower:]' '[:upper:]')
                    pstate="${raw_state:-ON}"
                    model_name=$(echo "$api_json" | grep -oEi '"modelName":"[^"]*"' | head -n1 | cut -d'"' -f4)
                else
                    pstate="STANDBY"
                fi
            fi
        fi

        local screen_content=""
        local led_color=""
        case "$pstate" in
            "ON")
                if [ $((frame % 2)) -eq 0 ]; then
                    screen_content="   [ BAZZITE 4K ]   "
                else
                    screen_content="   > HDMI ${port_num} ACTIVE <  "
                fi
                led_color="\e[32m●\e[0m"
                ;;
            "STANDBY")
                screen_content="    [ Zzz... ]      "
                led_color="\e[33m●\e[0m"
                ;;
            *)
                screen_content="    [ OFFLINE ]     "
                led_color="\e[31m●\e[0m"
                ;;
        esac

        echo -e "=================================================="
        echo -e "         HDMI Smart WoL - LIVE MONITOR            "
        echo -e "=================================================="
        echo -e ""
        echo -e "       ___________________________________        "
        echo -e "      /                                   \\       "
        echo -e "     |     $screen_content      |      "
        echo -e "     |___________________________________|        "
        echo -e "             \\_______       _______/              "
        echo -e "                     |     |                      "
        echo -e "                  ___|_____|___                   "
        echo -e "                 |             |                  "
        echo -e "                 |    [$led_color] TIZEN    |                  "
        echo -e "                 |_____________|                  "
        echo -e ""
        echo -e "--------------------------------------------------"
        echo -e " Target Model        : ${model_name:-Samsung TV}"
        echo -e " IP Address          : $ip_addr"
        echo -e " Active Port         : HDMI ${port_num}"
        echo -e " Power State         : $pstate"
        echo -e "--------------------------------------------------"
        echo -e " Press [Ctrl + C] to exit live view."
        echo -e "=================================================="

        ((frame++))
        sleep 2
    done
}

show_status() {
    echo "=================================================="
    echo "              HDMI Smart WoL Status               "
    echo "=================================================="
    
    local brand=$(get_tv_brand)
    local port_num=$(get_hdmi_port_num)

    echo "Display Brand         : $brand"
    echo "Connected HDMI Port   : HDMI ${port_num}"

    local cache_file=$(ls -t /var/cache/hdmi_wol/*.mac 2>/dev/null | head -n 1)
    if [ -n "$cache_file" ] && [ -s "$cache_file" ]; then
        local entry=$(cat "$cache_file" | tail -n 1)
        local mac_addr=$(echo "$entry" | cut -d":" -f1-6)
        local ip_addr=$(echo "$entry" | cut -d":" -f7)

        if [ -n "$ip_addr" ] && [ "$brand" = "SAMSUNG" ]; then
            local api_json=$(curl -s --connect-timeout 1.5 -m 2.0 "http://${ip_addr}:8001/api/v2/" 2>/dev/null)
            if [ -n "$api_json" ]; then
                local name=$(echo "$api_json" | grep -oEi '"name":"[^"]*"' | head -n1 | cut -d'"' -f4)
                local model=$(echo "$api_json" | grep -oEi '"modelName":"[^"]*"' | head -n1 | cut -d'"' -f4)
                local os_ver=$(echo "$api_json" | grep -oEi '"OS":"[^"]*"' | head -n1 | cut -d'"' -f4)
                local pstate=$(echo "$api_json" | grep -oEi '"PowerState":"[^"]*"' | head -n1 | cut -d'"' -f4 | tr '[:lower:]' '[:upper:]')
                
                local sz=$(echo "$model" | grep -oE '[0-9]{2}' | head -n 1)
                local screen_size=""
                [ -n "$sz" ] && [ "$sz" -ge 32 ] && [ "$sz" -le 98 ] && screen_size="${sz}\" Class 4K UHD Display"

                echo "TV Model & Name       : ${model:-Samsung TV} (\"${name:-Smart TV}\")"
                [ -n "$screen_size" ] && echo "Estimated Panel Size  : $screen_size"
                echo "Native Resolution     : 3840x2160 @ 60Hz (4K UHD)"
                [ -n "$os_ver" ] && echo "Firmware / OS         : Tizen OS ($os_ver)"
                echo "Network Connection    : IP Address ($ip_addr)"
                echo "Tizen Power State     : ${pstate:-ON}"
            else
                echo "Tizen Power State     : STANDBY / UNREACHABLE ($ip_addr)"
            fi
        fi
        echo "Hardware MAC Address  : $mac_addr"
        
        if [ -s "$TOKEN_FILE" ]; then
            local t_val=$(cat "$TOKEN_FILE" | tr -d '[:space:]')
            echo "WebSocket Token       : Present & Cached ($t_val)"
        else
            echo "WebSocket Token       : Missing (Run hdmi-wol --pair)"
        fi
    else
        echo "Current TV Sync       : Unsynced (Run hdmi-wol --sync)"
    fi

    echo "--------------------------------------------------"
    local wol_bin=$(get_wol_cmd)
    echo "WoL Engine Active     : ${wol_bin:-Native Python Sender}"
    
    if systemctl is-enabled hdmi-smart-wol.service &>/dev/null; then
        echo "Systemd Startup Hook  : Enabled"
    else
        echo "Systemd Startup Hook  : Disabled"
    fi

    if [ -f "$UDEV_RULE" ]; then
        echo "Hotplug DRM Trigger   : Enabled"
    else
        echo "Hotplug DRM Trigger   : Disabled"
    fi
    echo "=================================================="
    exit 0
}

show_help() {
    echo "=================================================="
    echo "       HDMI Smart Wake-on-LAN & Switcher          "
    echo "=================================================="
    echo "Usage: $(basename "$0") [OPTION]"
    echo ""
    echo "Core Features:"
    echo "  --status         Display TV status and model info."
    echo "  --live, -l       Display live updating TV status animation."
    echo "  --sendwol, -w    Trigger wake sequence and switch to active HDMI input."
    echo "  --sync, -s       Discover connected TV and authenticate WebSocket."
    echo "  --pair           Force-pair local Samsung WebSocket on port 8002."
    echo "  --repair         Purge stale bindings and run clean automated re-setup."
    echo "  --logs           View execution log history."
    echo ""
    echo "Management:"
    echo "  --config         Open the global configuration file in your editor."
    echo "  --update         Pull and install the latest script version from GitHub."
    echo "  --install        Install systemd boot, suspend/resume, and hotplug hooks."
    echo "  --uninstall      Cleanly disable and remove all hooks and configuration."
    echo "  --help, -h       Display this help menu."
    echo "=================================================="
    exit 0
}

install_service() {
    check_and_install_deps
    ensure_cache_dir

    cat << 'SUBEOF' | sudo tee "$SERVICE_FILE" > /dev/null
[Unit]
Description=Smart HDMI Display Auto Wake-on-LAN & Source Switcher
After=network-online.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/hdmi-wol --sendwol

[Install]
WantedBy=multi-user.target sleep.target
SUBEOF

    cat << 'SUBEOF' | sudo tee "$HOTPLUG_SERVICE" > /dev/null
[Unit]
Description=HDMI Display Hotplug Auto Wake-on-LAN
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/hdmi-wol --sendwol
SUBEOF

    cat << 'SUBEOF' | sudo tee "$UDEV_RULE" > /dev/null
ACTION=="change", SUBSYSTEM=="drm", ENV{HOTPLUG}=="1", TAG+="systemd", ENV{SYSTEMD_WANTS}+="hdmi-hotplug-wol.service"
SUBEOF

    sudo systemctl daemon-reload
    sudo udevadm control --reload-rules 2>/dev/null || true
    sudo systemctl enable hdmi-smart-wol.service
    log_msg "[INSTALL] Setup complete. Boot, Resume, and Cable Hotplug hooks active."
    manual_sync
    exit 0
}

uninstall_service() {
    [ -f "$SERVICE_FILE" ] && sudo systemctl disable --now hdmi-smart-wol.service 2>/dev/null && sudo rm -f "$SERVICE_FILE"
    [ -f "$HOTPLUG_SERVICE" ] && sudo rm -f "$HOTPLUG_SERVICE"
    [ -f "$UDEV_RULE" ] && sudo rm -f "$UDEV_RULE"
    [ -d "$CACHE_DIR" ] && sudo rm -rf "$CACHE_DIR"
    sudo udevadm control --reload-rules 2>/dev/null || true
    sudo systemctl daemon-reload
    echo "Clean disable complete."
    exit 0
}

case "$1" in
    --status) show_status ;;
    --live|-l) show_live_status ;;
    --logs) show_logs ;;
    --sync|-s) manual_sync ;;
    --pair|--force-pair) manual_sync --force ;;
    --repair) sudo rm -rf "$CACHE_DIR"; install_service ;;
    --sendwol|-w|--run) run_wol_sync ;;
    --install) install_service ;;
    --uninstall|--disable) uninstall_service ;;
    --update) update_script ;;
    --config) ${EDITOR:-nano} "$CONFIG_FILE" ;;
    --help|-h|"") show_help ;;
    *) show_help ;;
esac
