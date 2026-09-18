#!/usr/bin/env bash
# shellcheck disable=SC2154 # config_dir is provided by tunnel-manager.sh before sourcing.
# Shared utilities used by every tunnel core (colorize/prompt helpers, TOML
# reader, network probes, generic backup/restore, benchmark probes).
# Sourced by tunnel-manager.sh before any core module.

colorize() {
local color="$1"
local text="$2"
local style="${3:-normal}"
local black="\033[30m" red="\033[31m" green="\033[32m" yellow="\033[33m"
local blue="\033[34m" magenta="\033[35m" cyan="\033[36m" white="\033[37m"
local reset="\033[0m" normal="\033[0m" bold="\033[1m" underline="\033[4m"
local color_code
case $color in
black) color_code=$black ;; red) color_code=$red ;;
green) color_code=$green ;; yellow) color_code=$yellow ;;
blue) color_code=$blue ;; magenta) color_code=$magenta ;;
cyan) color_code=$cyan ;; white) color_code=$white ;;
*) color_code=$reset ;;
esac
local style_code
case $style in
bold) style_code=$bold ;; underline) style_code=$underline ;;
normal | *) style_code=$normal ;;
esac
echo -e "${style_code}${color_code}${text}${reset}"
}
press_key() {
read -r -p "Press any key to continue..."
}
prompt_with_default() {
local prompt="$1"
local default="$2"
local var_name="$3"
local input
echo -ne "[-] $prompt (default: $default): "
read -r input
if [[ ! "$var_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*(\[[a-zA-Z0-9_]+\])?$ ]]; then
colorize red "Invalid internal variable target: $var_name"
return 1
fi
# printf -v performs assignment without parsing the value as shell code.  The
# old eval-based implementation executed command substitutions/backticks from
# passwords, tokens and other interactive values while the panel was root.
printf -v "$var_name" '%s' "${input:-$default}"
}
prompt_boolean() {
local prompt="$1"
local default="$2"
local var_name="$3"
while true; do
prompt_with_default "$prompt [true/false]" "$default" "$var_name"
local value="${!var_name}"
if [[ "$value" == "true" || "$value" == "false" ]]; then
break
fi
colorize red "Invalid input. Please enter 'true' or 'false'."
done
}
validate_cidr() {
local cidr="$1"
if [[ ! "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]]; then
return 1
fi
IFS='/' read -r ip mask <<< "$cidr"
IFS='.' read -r a b c d <<< "$ip"
a=$((10#$a)); b=$((10#$b)); c=$((10#$c)); d=$((10#$d)); mask=$((10#$mask))
if (( a<0 || a>255 || b<0 || b>255 || c<0 || c>255 || d<0 || d>255 )); then
return 1
fi
if (( mask < 1 || mask > 32 )); then
return 1
fi
local ip_int=$(( (a << 24) | (b << 16) | (c << 8) | d ))
local mask_int
if (( mask == 32 )); then
mask_int=0xFFFFFFFF
else
mask_int=$(( (0xFFFFFFFF << (32 - mask)) & 0xFFFFFFFF ))
fi
local net_int=$(( ip_int & mask_int ))
local broadcast_int=$(( net_int | (~mask_int & 0xFFFFFFFF) ))
if (( ip_int == net_int )); then
return 1
fi
if (( ip_int == broadcast_int )); then
return 1
fi
return 0
}
cidr_range() {
local cidr="$1"
local ip="${cidr%/*}"
local mask="${cidr#*/}"
local a b c d
IFS='.' read -r a b c d <<< "$ip"
a=$((10#$a)); b=$((10#$b)); c=$((10#$c)); d=$((10#$d)); mask=$((10#$mask))
local ip_int=$(( (a << 24) | (b << 16) | (c << 8) | d ))
local mask_int
if (( mask == 0 )); then
mask_int=0
else
mask_int=$(( (0xFFFFFFFF << (32 - mask)) & 0xFFFFFFFF ))
fi
local net_int=$(( ip_int & mask_int ))
local broadcast_int=$(( net_int | (~mask_int & 0xFFFFFFFF) ))
echo "$net_int $broadcast_int"
}
cidr_overlaps() {
local net1 bcast1 net2 bcast2
read -r net1 bcast1 <<< "$(cidr_range "$1")"
read -r net2 bcast2 <<< "$(cidr_range "$2")"
(( net1 <= bcast2 && net2 <= bcast1 ))
}
save_last_used() {
local key="$1" value="$2"
local file="${config_dir}/.last_used.conf"
[[ -z "$value" ]] && return 0
mkdir -p "$(dirname "$file")"
touch "$file"
grep -v "^${key}=" "$file" 2>/dev/null > "${file}.tmp"
echo "${key}=${value}" >> "${file}.tmp"
mv -f "${file}.tmp" "$file"
}
get_last_used() {
local key="$1" default="$2"
local file="${config_dir}/.last_used.conf"
local line
[[ -f "$file" ]] || { echo "$default"; return; }
line=$(grep "^${key}=" "$file" | tail -1)
if [[ -n "$line" ]]; then
echo "${line#*=}"
else
echo "$default"
fi
}
detect_default_interface() {
local iface
iface=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
if [[ -z "$iface" ]]; then
iface=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
fi
echo "$iface"
}
detect_route_source_ipv4() {
local interface="${1:-}" route source_ip
if [[ -n "$interface" ]]; then
route=$(ip -4 route get 1.1.1.1 oif "$interface" 2>/dev/null | head -1)
else
route=$(ip -4 route get 1.1.1.1 2>/dev/null | head -1)
fi
source_ip=$(awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' <<< "$route")
if [[ "$source_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
echo "$source_ip"
return 0
fi
return 1
}
ipv4_is_local_on_interface() {
local address="$1" interface="$2"
[[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && -n "$interface" ]] || return 1
ip -o -4 addr show dev "$interface" 2>/dev/null |
awk '{print $4}' | cut -d/ -f1 | grep -Fxq -- "$address"
}
detect_public_ipv4() {
local ip
for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
ip=$(curl -fsS4 --max-time 2 "$url" 2>/dev/null | tr -d '[:space:]')
[[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ip"; return 0; }
done
return 1
}
detect_public_ipv6() {
local ip
for url in "https://api6.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
ip=$(curl -fsS6 --max-time 2 "$url" 2>/dev/null | tr -d '[:space:]')
[[ "$ip" == *:* ]] && { echo "$ip"; return 0; }
done
return 1
}
sha256_file() {
local file="$1"
if command -v sha256sum &> /dev/null; then
sha256sum "$file" | awk '{print tolower($1)}'
elif command -v openssl &> /dev/null; then
openssl dgst -sha256 "$file" | awk '{print tolower($NF)}'
else
return 127
fi
}
verify_sha256() {
local file="$1" expected="${2,,}" label="${3:-download}"
local actual
if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
colorize red "No valid SHA256 is available for ${label}; refusing to install it."
return 1
fi
actual=$(sha256_file "$file") || {
colorize red "sha256sum or openssl is required to verify ${label}."
return 1
}
if [[ "$actual" != "$expected" ]]; then
colorize red "SHA256 mismatch for ${label} (expected ${expected}, got ${actual})."
return 1
fi
}
yaml_quote() {
local value="$1"
value="${value//\'/\'\'}"
printf "'%s'" "$value"
}
yaml_unquote() {
local value="$1"
if [[ "$value" == \'*\' && ${#value} -ge 2 ]]; then
value="${value:1:${#value}-2}"
value="${value//\'\'/\'}"
fi
printf '%s' "$value"
}
validate_safe_secret() {
local value="$1"
(( ${#value} >= 8 && ${#value} <= 128 )) && [[ "$value" =~ ^[a-zA-Z0-9._~!@#%+,:=^-]+$ ]]
}
value_in_list() {
local needle="$1" item
shift
for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
return 1
}
toml_quote() {
local value="$1"
value="${value//\\/\\\\}"
value="${value//\"/\\\"}"
value="${value//$'\t'/\\t}"
value="${value//$'\r'/\\r}"
value="${value//$'\n'/\\n}"
printf '"%s"' "$value"
}
github_release_asset_sha256() {
local repo="$1" tag="$2" asset="$3" digest
command -v jq &> /dev/null || return 1
digest=$(curl -fsSL \
-H 'Accept: application/vnd.github+json' \
-H 'X-GitHub-Api-Version: 2022-11-28' \
"https://api.github.com/repos/${repo}/releases/tags/${tag}" 2>/dev/null | \
jq -r --arg asset "$asset" '.assets[] | select(.name == $asset) | .digest // empty' | head -1)
digest="${digest#sha256:}"
[[ "$digest" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
echo "${digest,,}"
}
validate_port_number() {
local port="$1"
[[ "$port" =~ ^[0-9]+$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 ))
}
normalize_port_spec() {
local spec="${1// /}" allow_range="${2:-true}" start end
if [[ "$spec" =~ ^([0-9]+)[-:]([0-9]+)$ ]]; then
[[ "$allow_range" == "true" ]] || return 1
start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
validate_port_number "$start" && validate_port_number "$end" && (( 10#$start <= 10#$end )) || return 1
echo "${start}:${end}"
else
validate_port_number "$spec" || return 1
echo "$spec"
fi
}
validate_port_mapping_csv() {
local mapping="$1" allow_ranges="${2:-false}" entry listen dest
local -a entries=()
IFS=',' read -r -a entries <<< "$mapping"
(( ${#entries[@]} > 0 )) || return 1
for entry in "${entries[@]}"; do
entry="${entry// /}"
[[ -n "$entry" ]] || return 1
if [[ "$entry" == *=* ]]; then
listen="${entry%%=*}"; dest="${entry#*=}"
elif [[ "$entry" == *:* ]]; then
listen="${entry%%:*}"; dest="${entry#*:}"
else
listen="$entry"; dest="$entry"
fi
normalize_port_spec "$listen" "$allow_ranges" >/dev/null || return 1
normalize_port_spec "$dest" "$allow_ranges" >/dev/null || return 1
done
}
validate_port_list_csv() {
local list="$1" allow_ranges="${2:-false}" entry
local -a entries=()
IFS=',' read -r -a entries <<< "$list"
(( ${#entries[@]} > 0 )) || return 1
for entry in "${entries[@]}"; do
entry="${entry// /}"
[[ "$entry" != *[=:]* ]] || return 1
normalize_port_spec "$entry" "$allow_ranges" >/dev/null || return 1
done
}
validate_host_port() {
local value="$1" host port
if [[ "$value" =~ ^\[([0-9a-fA-F:]+)\]:([0-9]+)$ ]]; then
host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
elif [[ "$value" =~ ^([a-zA-Z0-9._-]+):([0-9]+)$ ]]; then
host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
else
return 1
fi
[[ -n "$host" ]] && validate_port_number "$port"
}
validate_host_port_csv() {
local value="$1" item
local -a items=()
IFS=',' read -r -a items <<< "$value"
(( ${#items[@]} > 0 )) || return 1
for item in "${items[@]}"; do
item="${item// /}"
validate_host_port "$item" || return 1
done
}
validate_listen_address() {
local value="$1"
if [[ "$value" =~ ^:([0-9]+)$ ]]; then
validate_port_number "${BASH_REMATCH[1]}"
else
validate_host_port "$value"
fi
}

# Firewall rules created by the panel are tracked by owner.  This prevents a
# tunnel removal from deleting an administrator's pre-existing rule and lets
# edits remove ports that are no longer configured.
TM_FIREWALL_STATE_DIR="${config_dir}/.firewall"
tm_firewall_owner_key() {
tr -c 'a-zA-Z0-9_.-' '_' <<< "$1" | tr -d '\n'
}
tm_firewall_state_file() {
echo "${TM_FIREWALL_STATE_DIR}/$(tm_firewall_owner_key "$1").rules"
}
tm_firewall_open_port() {
local owner="$1" raw_spec="$2" proto="$3" spec marker backend state_file
spec=$(normalize_port_spec "$raw_spec" true) || {
colorize red "Invalid firewall port/range: ${raw_spec}"
return 1
}
[[ "$proto" == "tcp" || "$proto" == "udp" ]] || return 1
marker="tunnel-manager:$(tm_firewall_owner_key "$owner")"
state_file=$(tm_firewall_state_file "$owner")
mkdir -p "$TM_FIREWALL_STATE_DIR"
if command -v ufw &> /dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
backend="ufw"
if ! ufw allow "${spec}/${proto}" comment "$marker" >/dev/null 2>&1; then
colorize red "Failed to open ${spec}/${proto} with UFW."
return 1
fi
elif command -v iptables &> /dev/null; then
backend="iptables"
if ! iptables -C INPUT -p "$proto" --dport "$spec" -m comment --comment "$marker" -j ACCEPT 2>/dev/null; then
iptables -I INPUT -p "$proto" --dport "$spec" -m comment --comment "$marker" -j ACCEPT || return 1
fi
else
colorize yellow "No supported firewall manager found; open ${spec}/${proto} manually."
return 0
fi
grep -qxF "${owner}|${backend}|${proto}|${spec}|${marker}" "$state_file" 2>/dev/null || \
echo "${owner}|${backend}|${proto}|${spec}|${marker}" >> "$state_file"
[[ "$backend" == "iptables" ]] && persist_iptables_rules
}
tm_firewall_close_owner() {
local owner="$1" state_file row_owner backend proto spec marker line number
state_file=$(tm_firewall_state_file "$owner")
[[ -f "$state_file" ]] || return 0
while IFS='|' read -r row_owner backend proto spec marker; do
[[ "$row_owner" == "$owner" ]] || continue
case "$backend" in
ufw)
if command -v ufw &> /dev/null; then
while line=$(ufw status numbered 2>/dev/null | grep -F "$marker" | tail -1) && [[ -n "$line" ]]; do
number=$(sed -n 's/^\[[[:space:]]*\([0-9][0-9]*\)\].*/\1/p' <<< "$line")
[[ -n "$number" ]] || break
ufw --force delete "$number" >/dev/null 2>&1 || break
done
fi
;;
iptables)
if command -v iptables &> /dev/null; then
while iptables -C INPUT -p "$proto" --dport "$spec" -m comment --comment "$marker" -j ACCEPT 2>/dev/null; do
iptables -D INPUT -p "$proto" --dport "$spec" -m comment --comment "$marker" -j ACCEPT 2>/dev/null || break
done
fi
;;
esac
done < "$state_file"
rm -f "$state_file"
command -v iptables &> /dev/null && persist_iptables_rules
}
tm_firewall_sync_mapping() {
local owner="$1" mapping="$2" protocols="$3" allow_ranges="${4:-false}"
local entry listen proto spec
local -a entries=() protos=()
validate_port_mapping_csv "$mapping" "$allow_ranges" || {
colorize red "Invalid port mapping: ${mapping}"
return 1
}
tm_firewall_close_owner "$owner"
IFS=',' read -r -a entries <<< "$mapping"
read -r -a protos <<< "$protocols"
for entry in "${entries[@]}"; do
entry="${entry// /}"
if [[ "$entry" == *=* ]]; then listen="${entry%%=*}"
elif [[ "$entry" == *:* ]]; then listen="${entry%%:*}"
else listen="$entry"
fi
spec=$(normalize_port_spec "$listen" "$allow_ranges") || return 1
for proto in "${protos[@]}"; do
if ! tm_firewall_open_port "$owner" "$spec" "$proto"; then
tm_firewall_close_owner "$owner"
return 1
fi
done
done
}
tm_firewall_cleanup_all() {
local f owner
for f in "${TM_FIREWALL_STATE_DIR}"/*.rules; do
[[ -f "$f" ]] || continue
owner=$(head -1 "$f" | cut -d'|' -f1)
[[ -n "$owner" ]] && tm_firewall_close_owner "$owner"
done
rmdir "$TM_FIREWALL_STATE_DIR" 2>/dev/null || true
}
service_should_run() {
systemctl is-enabled --quiet "$1" 2>/dev/null
}
watchdog_restart_if_enabled() {
local service_name="$1" log_tag="$2"
service_should_run "$service_name" || return 0
if ! systemctl is-active --quiet "$service_name" 2>/dev/null; then
logger -t "$log_tag" "${service_name} is enabled but inactive, restarting" 2>/dev/null
systemctl restart "$service_name" 2>/dev/null
fi
}
enable_service_checked() {
local service_name="$1" wait_seconds="${2:-2}"
systemctl daemon-reload || return 1
systemctl enable "$service_name" >/dev/null 2>&1 || return 1
if declare -F core_optimize_sync_for_tunnel >/dev/null; then
core_optimize_sync_for_tunnel before "$service_name" || true
fi
systemctl restart "$service_name" >/dev/null 2>&1 || return 1
sleep "$wait_seconds"
systemctl is-active --quiet "$service_name" 2>/dev/null || return 1
if declare -F core_optimize_sync_for_tunnel >/dev/null; then
core_optimize_sync_for_tunnel after "$service_name" || true
fi
return 0
}
cert_days_remaining() {
local cert_file="$1"
[[ -f "$cert_file" ]] || { echo "-1"; return 1; }
local end_date end_epoch now_epoch
end_date=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2-)
[[ -z "$end_date" ]] && { echo "-1"; return 1; }
end_epoch=$(date -d "$end_date" +%s 2>/dev/null)
[[ -z "$end_epoch" ]] && { echo "-1"; return 1; }
now_epoch=$(date +%s)
echo $(( (end_epoch - now_epoch) / 86400 ))
}
ensure_cert_fresh() {
local cert_file="$1" key_file="$2"
local days
if [[ -f "$cert_file" && -f "$key_file" ]]; then
days=$(cert_days_remaining "$cert_file")
if (( days > 0 )) && openssl x509 -in "$cert_file" -noout -ext subjectAltName 2>/dev/null | grep -q 'DNS:backhaul.com'; then
return 1
fi
colorize yellow "[*] TLS certificate is expired or lacks the required SAN; renewing..."
else
colorize yellow "[*] TLS certificate or key missing, generating a self-signed ECDSA cert..."
fi
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -x509 -days 3650 -sha256 \
-keyout "$key_file" -out "$cert_file" -subj "/CN=backhaul.com" \
-addext "subjectAltName=DNS:backhaul.com" || return 1
chmod 600 "$key_file"
chmod 644 "$cert_file"
colorize green "[*] Generated $cert_file and $key_file"
return 0
}
FAIL2BAN_JAIL_FILE="/etc/fail2ban/jail.d/tunnel-manager-ssh.conf"
fail2ban_ssh_status() {
[[ -f "$FAIL2BAN_JAIL_FILE" ]] && systemctl is-active --quiet fail2ban 2>/dev/null && echo "enabled" || echo "disabled"
}
enable_fail2ban_ssh_protection() {
if ! command -v fail2ban-client &> /dev/null; then
colorize yellow "Installing Fail2Ban..."
if command -v apt-get &> /dev/null; then
apt-get update -qq >/dev/null 2>&1
apt-get install -y fail2ban >/dev/null 2>&1
elif command -v dnf &> /dev/null; then
dnf install -y fail2ban >/dev/null 2>&1
elif command -v yum &> /dev/null; then
yum install -y fail2ban >/dev/null 2>&1
fi
fi
if ! command -v fail2ban-client &> /dev/null; then
colorize red "✘ Could not install Fail2Ban (unsupported package manager or no network)."
return 1
fi
mkdir -p "$(dirname "$FAIL2BAN_JAIL_FILE")"
cat > "$FAIL2BAN_JAIL_FILE" <<EOF
[sshd]
enabled = true
maxretry = 5
findtime = 10m
bantime = 1h
EOF
systemctl enable --now fail2ban >/dev/null 2>&1
systemctl restart fail2ban >/dev/null 2>&1
colorize green "✔ Fail2Ban SSH protection enabled (5 failed attempts in 10 min -> 1 hour ban)."
}
disable_fail2ban_ssh_protection() {
rm -f "$FAIL2BAN_JAIL_FILE"
systemctl restart fail2ban >/dev/null 2>&1
colorize yellow "Fail2Ban SSH jail removed (Fail2Ban itself stays installed/running for any other jails on the system)."
}
json_escape() {
local s="$1"
s="${s//\\/\\\\}"
s="${s//\"/\\\"}"
echo "$s"
}
# One JSON object per matching tunnel, one per line (caller joins with mapfile
# + IFS=,) — role is inferred from the iran/kharej filename prefix the same
# way every core's own listing UI already does it, active from systemctl.
emit_engine_tunnels_json() {
local dir="$1" engine="$2" prefix="$3" ext="$4" reverse_roles="${5:-false}"
local f name role active
for f in "${dir}"/iran*."${ext}" "${dir}"/kharej*."${ext}"; do
[[ -f "$f" ]] || continue
name=$(basename "${f%."${ext}"}")
if [[ "$name" == iran* ]]; then role="server"; else role="client"; fi
if [[ "$reverse_roles" == "true" ]]; then
case "$engine" in
hysteria2) role=$(core_hysteria2_role "$f") ;;
tuic) role=$(core_tuic_role "$f") ;;
esac
fi
if systemctl is-active --quiet "${prefix}-${name}.service" 2>/dev/null; then active="true"; else active="false"; fi
printf '{"engine":"%s","name":"%s","role":"%s","active":%s}\n' "$(json_escape "$engine")" "$(json_escape "$name")" "$role" "$active"
done
}
cpu_usage_percent() {
[[ -r /proc/stat ]] || { echo "NA"; return 1; }
local -a f1 f2
read -r -a f1 < /proc/stat
sleep 0.3
read -r -a f2 < /proc/stat
local i total1=0 total2=0
for ((i = 1; i < ${#f1[@]}; i++)); do total1=$((total1 + f1[i])); done
for ((i = 1; i < ${#f2[@]}; i++)); do total2=$((total2 + f2[i])); done
local idle1=$((f1[4] + f1[5])) idle2=$((f2[4] + f2[5]))
local total_delta=$((total2 - total1)) idle_delta=$((idle2 - idle1))
(( total_delta <= 0 )) && { echo "0"; return; }
echo $(( (100 * (total_delta - idle_delta)) / total_delta ))
}
mem_usage_info() {
[[ -r /proc/meminfo ]] || { echo "NA NA NA"; return 1; }
local total avail
total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
[[ -z "$total" || -z "$avail" || "$total" -le 0 ]] && { echo "NA NA NA"; return 1; }
echo "$(( (total - avail) / 1024 )) $((total / 1024)) $(( (100 * (total - avail)) / total ))"
}
net_rate_kbps() {
local iface="$1"
[[ -r /proc/net/dev ]] || { echo "NA NA"; return 1; }
local rx1 tx1 rx2 tx2
read -r rx1 tx1 <<< "$(awk -v ifc="${iface}:" '$1==ifc{print $2, $10}' /proc/net/dev)"
[[ -z "$rx1" ]] && { echo "NA NA"; return 1; }
sleep 1
read -r rx2 tx2 <<< "$(awk -v ifc="${iface}:" '$1==ifc{print $2, $10}' /proc/net/dev)"
echo "$(( (rx2 - rx1) / 1024 )) $(( (tx2 - tx1) / 1024 ))"
}
count_tunnels_multi() {
local dir="$1" prefix="$2" ext="$3"
local total=0 active=0 f name svc
for f in "${dir}"/iran*."${ext}" "${dir}"/kharej*."${ext}"; do
[[ -f "$f" ]] || continue
((total++))
name=$(basename "${f%."${ext}"}")
svc="${prefix}-${name}.service"
systemctl is-active --quiet "$svc" 2>/dev/null && ((active++))
done
echo "$active $total"
}
persist_line_once() {
local line="$1"
local file="$2"
mkdir -p "$(dirname "$file")"
touch "$file"
grep -qxF "$line" "$file" || echo "$line" >> "$file"
}
persist_iptables_rules() {
if command -v netfilter-persistent &> /dev/null; then
netfilter-persistent save >/dev/null 2>&1
elif command -v iptables-save &> /dev/null && [[ -d /etc/iptables ]]; then
iptables-save > /etc/iptables/rules.v4 2>/dev/null
else
colorize yellow "Note: this iptables rule is not persisted across reboot (install iptables-persistent to persist)."
fi
}
ensure_journal_limits() {
local conf_dir="/etc/systemd/journald.conf.d"
local conf_file="${conf_dir}/backhaul-tunnel.conf"
[[ -f "$conf_file" ]] && return
mkdir -p "$conf_dir" 2>/dev/null
cat > "$conf_file" <<EOF
[Journal]
SystemMaxUse=200M
EOF
systemctl restart systemd-journald >/dev/null 2>&1
}
toml_get() {
local file="$1" section="$2" key="$3"
awk -v want_section="[$section]" -v want_key="$key" '
FNR==1 { insec=0 }
/^\[/ { insec = ($0 == want_section) }
insec {
n = length(want_key)
if (substr($0,1,n) == want_key && substr($0,n+1,1) ~ /[ =]/) {
line=$0
sub(/^[^=]*=[ \t]*/, "", line)
gsub(/^"|"$/, "", line)
print line
exit
}
}
' "$file" 2>/dev/null
}
tcp_port_open() {
local host="$1" port="$2" timeout="${3:-3}"
timeout "$timeout" bash -c "echo > /dev/tcp/${host}/${port}" 2>/dev/null
}
ping_stats() {
local host="$1" count="${2:-5}"
if ! command -v ping &> /dev/null; then
echo "NA NA"; return 1
fi
local out
out=$(ping -c "$count" -W 2 "$host" 2>/dev/null)
if [[ -z "$out" ]]; then
echo "NA NA"; return 1
fi
local avg loss
avg=$(echo "$out" | grep -oP '(?<= = )[0-9.]+/[0-9.]+/[0-9.]+/[0-9.]+(?= ms)' | awk -F/ '{print $2}')
loss=$(echo "$out" | grep -oP '[0-9]+(?=% packet loss)')
echo "${avg:-NA} ${loss:-NA}"
}
tun_iface_exists() {
ip link show "$1" &>/dev/null
}
check_health_endpoint() {
local port="$1" http_code
[[ -z "$port" ]] && { echo "N/A"; return 1; }
if command -v curl &> /dev/null; then
http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://127.0.0.1:${port}/" 2>/dev/null)
if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
echo "OK"
return 0
fi
fi
if tcp_port_open "127.0.0.1" "$port" 2; then
echo "OPEN"
return 0
fi
echo "DOWN"
return 1
}
tunnel_traffic_stats() {
local service_name="$1" rx tx
rx=$(systemctl show "$service_name" -p IPIngressBytes --value 2>/dev/null)
tx=$(systemctl show "$service_name" -p IPEgressBytes --value 2>/dev/null)
if [[ -z "$rx" || "$rx" == "[not set]" || "$rx" == "18446744073709551615" ]]; then
echo ""
return
fi
if command -v numfmt &> /dev/null; then
rx=$(numfmt --to=iec --suffix=B "$rx" 2>/dev/null)
tx=$(numfmt --to=iec --suffix=B "$tx" 2>/dev/null)
fi
echo "RX ${rx:-0}  TX ${tx:-0}"
}
backup_tunnel() {
local config_path="$1" service_path="$2" config_name="$3" ts backup_dir meta_path
ts=$(date +%Y%m%d%H%M%S)
backup_dir="${config_dir}/.backups/${config_name}.${ts}"
mkdir -p "$backup_dir"
[[ -f "$config_path" ]] && cp -p "$config_path" "$backup_dir/config.toml"
[[ -f "$service_path" ]] && cp -p "$service_path" "$backup_dir/service.service"
if [[ "$config_name" =~ ^[a-zA-Z0-9._-]+$ ]] && declare -F tunnel_meta_file >/dev/null; then
printf '%s\n' "$config_name" > "$backup_dir/meta.name"
meta_path=$(tunnel_meta_file "$config_name")
[[ -f "$meta_path" ]] && cp -p "$meta_path" "$backup_dir/meta"
fi
echo "$backup_dir"
}
restore_tunnel_backup() {
local backup_dir="$1" config_path="$2" service_path="$3" service_name="$4" meta_name meta_path
[[ -f "$backup_dir/config.toml" ]] && cp -p "$backup_dir/config.toml" "$config_path"
[[ -f "$backup_dir/service.service" ]] && cp -p "$backup_dir/service.service" "$service_path"
if [[ -f "$backup_dir/meta.name" ]] && declare -F tunnel_meta_file >/dev/null; then
meta_name=$(<"$backup_dir/meta.name")
if [[ "$meta_name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
meta_path=$(tunnel_meta_file "$meta_name")
if [[ -f "$backup_dir/meta" ]]; then
mkdir -p "$(dirname "$meta_path")"
cp -p "$backup_dir/meta" "$meta_path"
else
rm -f "$meta_path"
fi
fi
fi
systemctl daemon-reload
systemctl restart "$service_name" 2>/dev/null
}
benchmark_tcp_probe() {
local peer_ip="$1" port="$2" start end elapsed success=0 i
local latencies=()
for i in 1 2 3 4 5; do
start=$(date +%s%N)
if tcp_port_open "$peer_ip" "$port" 2; then
end=$(date +%s%N)
elapsed=$(( (end-start)/1000000 ))
latencies+=("$elapsed")
success=$((success+1))
fi
done
local n=${#latencies[@]}
if (( n == 0 )); then
echo "NA NA NA"
return
fi
local sum=0 l
for l in "${latencies[@]}"; do sum=$((sum+l)); done
local avg=$((sum/n))
local loss=$(( (5-success)*100/5 ))
local throughput="NA"
if command -v iperf3 &> /dev/null; then
local iperf_out
iperf_out=$(timeout 6 iperf3 -c "$peer_ip" -p 5201 -t 3 -J 2>/dev/null)
if [[ -n "$iperf_out" ]]; then
throughput=$(echo "$iperf_out" | grep -oP '"bits_per_second":\s*\K[0-9.]+' | tail -1)
[[ -n "$throughput" ]] && throughput=$(awk -v b="$throughput" 'BEGIN{printf "%.0f", b/1000000}')
fi
fi
echo "$avg $loss ${throughput:-NA}"
}
benchmark_icmp_probe() {
local peer_ip="$1" avg loss
read -r avg loss <<< "$(ping_stats "$peer_ip" 10)"
echo "$avg $loss NA"
}
benchmark_raw_protocol_probe() {
local peer_ip="$1" proto_num="$2"
if ! command -v hping3 &> /dev/null; then
echo "UNSUPPORTED"
return
fi
if timeout 5 hping3 -c 3 --rawip -H "$proto_num" "$peer_ip" 2>/dev/null | grep -q "bytes from"; then
echo "OK"
else
echo "BLOCKED"
fi
}
score_result() {
local latency="$1" loss="$2"
if [[ "$latency" == "NA" ]]; then echo 999999; return; fi
latency=$(printf "%.0f" "$latency")
echo $(( latency + loss*20 ))
}
status_label() {
local latency="$1" loss="$2"
if [[ "$latency" == "NA" ]]; then echo "Unusable"; return; fi
latency=$(printf "%.0f" "$latency")
if (( loss == 0 && latency < 80 )); then echo "Excellent"
elif (( loss <= 2 && latency < 150 )); then echo "Good"
elif (( loss <= 5 && latency < 300 )); then echo "Fair"
else echo "Poor"
fi
}
restart_service() {
echo
colorize yellow "Restarting $1" bold
if systemctl list-units --type=service | grep -q "$1"; then
systemctl restart "$1"
colorize green "Service restarted successfully" bold
echo
else
colorize red "Service not found"
fi
press_key
}
view_service_logs() {
clear
journalctl -eu "$1" -f -o cat
}
view_service_status() {
clear
systemctl status "$1"
press_key
}
