#!/usr/bin/env bash
# shellcheck disable=SC2154 # config_dir/service_dir are provided by tunnel-manager.sh.
# Backhaul tunnel core. Behavior is unchanged from the original single-file
# backhaul.sh; this is the same code, just living in its own module so other
# cores (rathole, and later gost/frp/...) can sit alongside it without
# touching this file. Requires lib/common.sh to already be sourced.

VALID_ALGORITHMS=("aes-256-gcm" "chacha20-poly1305" "aes-128-gcm")
BACKHAUL_WATCHDOG_FAILURE_LIMIT=3
BACKHAUL_HEALTH_SAMPLE_INTERVAL=300
# CONFIG must be associative: bare `CONFIG=()` makes it an indexed array, and
# every non-numeric subscript (CONFIG[bind_addr], CONFIG[transport_type], ...)
# then evaluates as an unset-variable arithmetic expression == 0, so every
# field silently collapses onto the same index-0 slot and overwrites every
# other field. Declaring it here once, at source time, is what actually keeps
# each field independent everywhere else in this file.
declare -A CONFIG

existing_tun_cidrs() {
local excluded_config="${1:-}"
local file
for file in "${config_dir}"/*.toml; do
[[ -f "$file" ]] || continue
if [[ -n "$excluded_config" ]] && { [[ "$file" == "$excluded_config" ]] || [[ "$file" -ef "$excluded_config" ]]; }; then
continue
fi
awk '
FNR==1 { in_tun=0 }
/^\[/ { in_tun = ($0 == "[tun]") }
in_tun && /^(local_addr|remote_addr) = "/ {
if (match($0, /"[^"]*"/)) print substr($0, RSTART+1, RLENGTH-2)
}
' "$file" 2>/dev/null
done
}
toml_tun_name() {
local file="$1"
awk '
FNR==1 { in_tun=0 }
/^\[/ { in_tun = ($0 == "[tun]") }
in_tun && /^name = "/ {
if (match($0, /"[^"]*"/)) print substr($0, RSTART+1, RLENGTH-2)
}
' "$file" 2>/dev/null
}
toml_ipx_profile() {
local file="$1"
awk '
FNR==1 { in_ipx=0 }
/^\[/ { in_ipx = ($0 == "[ipx]") }
in_ipx && /^profile = "/ {
if (match($0, /"[^"]*"/)) print substr($0, RSTART+1, RLENGTH-2)
}
' "$file" 2>/dev/null
}
has_any_tun_config() {
grep -l '^\[tun\]$' "${config_dir}"/*.toml 2>/dev/null | grep -q .
}
profile_still_in_use() {
local profile="$1"
local f
for f in "${config_dir}"/*.toml; do
[[ -f "$f" ]] || continue
[[ "$(toml_ipx_profile "$f")" == "$profile" ]] && return 0
done
return 1
}
is_tun_subnet_in_use() {
local cidr="$1"
local excluded_config="${2:-}"
local existing
while IFS= read -r existing; do
[[ -z "$existing" ]] && continue
if cidr_overlaps "$cidr" "$existing"; then
return 0
fi
done <<< "$(existing_tun_cidrs "$excluded_config")"
return 1
}
suggest_tun_subnet_third_octet() {
local used
used=$(existing_tun_cidrs | grep -oE '^10\.10\.[0-9]{1,3}\.' | cut -d. -f3)
local third=10
while grep -qx "$third" <<< "$used"; do
((third++))
done
echo "$third"
}
is_tun_name_in_use() {
local name="$1"
local excluded_config="${2:-}"
local file
for file in "${config_dir}"/*.toml; do
[[ -f "$file" ]] || continue
if [[ -n "$excluded_config" ]] && { [[ "$file" == "$excluded_config" ]] || [[ "$file" -ef "$excluded_config" ]]; }; then
continue
fi
[[ "$(toml_tun_name "$file")" == "$name" ]] && return 0
done
return 1
}
is_tunnel_port_in_use() {
local mode="$1"
local port="$2"
local excluded_config="${3:-}"
local prefix
[[ "$mode" == "server" ]] && prefix="iran" || prefix="kharej"
local candidate="${config_dir}/${prefix}${port}.toml"
[[ -f "$candidate" ]] || return 1
if [[ -n "$excluded_config" ]] && { [[ "$candidate" == "$excluded_config" ]] || [[ "$candidate" -ef "$excluded_config" ]]; }; then
return 1
fi
return 0
}
is_port_listening_system_wide() {
local port="$1"
if command -v ss &> /dev/null; then
ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q . && return 0
ss -H -lun "sport = :${port}" 2>/dev/null | grep -q . && return 0
return 1
fi
timeout 1 bash -c "echo > /dev/tcp/127.0.0.1/${port}" 2>/dev/null
}
suggest_free_tunnel_port() {
local mode="$1"
local prefix
[[ "$mode" == "server" ]] && prefix="iran" || prefix="kharej"
local port=1234
while [[ -f "${config_dir}/${prefix}${port}.toml" ]] || is_port_listening_system_wide "$port"; do
((port++))
done
echo "$port"
}
suggest_tunnel_bind_port() {
local mode="$1"
local last
last=$(get_last_used "${mode}_tunnel_port" "")
if [[ -n "$last" ]] && ! is_tunnel_port_in_use "$mode" "$last" && ! is_port_listening_system_wide "$last"; then
echo "$last"
return
fi
suggest_free_tunnel_port "$mode"
}
is_valid_tun_name() {
local name="$1"
[[ "$name" =~ ^[A-Za-z0-9_-]{1,15}$ ]]
}
suggest_tun_name() {
local base="backhaul"
local used
used=$(grep -h -oE '^name = "[^"]*"' "${config_dir}"/*.toml 2>/dev/null | sed -E 's/^name = "(.*)"$/\1/')
local candidate="$base"
local n=1
while grep -qx "$candidate" <<< "$used"; do
((n++))
candidate="${base}${n}"
done
echo "$candidate"
}
prepare_tun_ipx_kernel() {
local is_ipx="$1"
local profile="$2"
local tun_name="$3"
colorize yellow "Applying kernel prerequisites for TUN..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1
persist_line_once "net.ipv4.ip_forward=1" "/etc/sysctl.d/99-backhaul-tunnel.conf"
persist_line_once "net.ipv4.conf.all.rp_filter=0" "/etc/sysctl.d/99-backhaul-tunnel.conf"
persist_line_once "net.ipv4.conf.default.rp_filter=0" "/etc/sysctl.d/99-backhaul-tunnel.conf"
local rp_file
for rp_file in /proc/sys/net/ipv4/conf/*/rp_filter; do
{ echo 0 > "$rp_file"; } 2>/dev/null
done
sysctl -p /etc/sysctl.d/99-backhaul-tunnel.conf >/dev/null 2>&1
if command -v iptables &> /dev/null && [[ -n "$tun_name" ]]; then
local forward_changed="false"
if ! iptables -C FORWARD -i "$tun_name" -j ACCEPT 2>/dev/null; then
iptables -I FORWARD -i "$tun_name" -j ACCEPT
forward_changed="true"
fi
if ! iptables -C FORWARD -o "$tun_name" -j ACCEPT 2>/dev/null; then
iptables -I FORWARD -o "$tun_name" -j ACCEPT
forward_changed="true"
fi
[[ "$forward_changed" == "true" ]] && persist_iptables_rules
fi
if [[ "$is_ipx" == "true" ]]; then
local mod=""
case "$profile" in
gre) mod="ip_gre" ;;
ipip) mod="ipip" ;;
esac
if [[ -n "$mod" ]] && command -v modprobe &> /dev/null; then
lsmod | grep -qw "$mod" || modprobe "$mod" >/dev/null 2>&1
persist_line_once "$mod" "/etc/modules-load.d/backhaul-tunnel.conf"
fi
fi
colorize green "Kernel prerequisites applied."
}
allow_forwarded_ports_firewall() {
local owner="$1" mapping="$2" accept_udp="$3" protocols="tcp"
[[ "$accept_udp" == "true" ]] && protocols="tcp udp"
tm_firewall_sync_mapping "$owner" "$mapping" "$protocols" true
}
parse_port_entry() {
local entry="$1" listen dest
if [[ "$entry" == *=* ]]; then
listen="${entry%%=*}"; dest="${entry#*=}"
elif [[ "$entry" == *:* ]]; then
listen="${entry%%:*}"; dest="${entry#*:}"
else
listen="$entry"; dest="$entry"
fi
listen="${listen//-/:}"
dest="${dest//-/:}"
echo "$listen $dest"
}
ensure_tun_masquerade() {
local tun_name="$1"
command -v iptables &> /dev/null || return
if ! iptables -t nat -C POSTROUTING -o "$tun_name" -j MASQUERADE 2>/dev/null; then
iptables -t nat -A POSTROUTING -o "$tun_name" -j MASQUERADE
persist_iptables_rules
fi
}
apply_iptables_dnat_forwarding() {
local mapping="$1" target="$2" entry listen dest proto
if ! command -v iptables &> /dev/null; then
colorize red "iptables is not available; cannot set up iptables forwarding."
return 1
fi
local -a entries=()
IFS=',' read -r -a entries <<< "$mapping"
local changed="false"
for entry in "${entries[@]}"; do
entry="${entry// /}"
[[ -z "$entry" ]] && continue
read -r listen dest <<< "$(parse_port_entry "$entry")"
for proto in tcp udp; do
if ! iptables -t nat -C PREROUTING -p "$proto" --dport "$listen" -j DNAT --to-destination "${target}:${dest}" 2>/dev/null; then
iptables -t nat -A PREROUTING -p "$proto" --dport "$listen" -j DNAT --to-destination "${target}:${dest}"
changed="true"
fi
if ! iptables -C FORWARD -p "$proto" -d "$target" --dport "$dest" -j ACCEPT 2>/dev/null; then
iptables -I FORWARD -p "$proto" -d "$target" --dport "$dest" -j ACCEPT
changed="true"
fi
done
done
[[ "$changed" == "true" ]] && persist_iptables_rules
}
remove_iptables_dnat_forwarding() {
local mapping="$1" target="$2" entry listen dest proto
command -v iptables &> /dev/null || return 0
local -a entries=()
IFS=',' read -r -a entries <<< "$mapping"
for entry in "${entries[@]}"; do
entry="${entry// /}"
[[ -z "$entry" ]] && continue
read -r listen dest <<< "$(parse_port_entry "$entry")"
for proto in tcp udp; do
iptables -t nat -D PREROUTING -p "$proto" --dport "$listen" -j DNAT --to-destination "${target}:${dest}" 2>/dev/null
iptables -D FORWARD -p "$proto" -d "$target" --dport "$dest" -j ACCEPT 2>/dev/null
done
done
persist_iptables_rules
}
ensure_haproxy_installed() {
if ! command -v haproxy &> /dev/null; then
if command -v apt-get &> /dev/null; then
colorize yellow "Installing haproxy..."
apt-get update -qq >/dev/null 2>&1
apt-get install -y haproxy >/dev/null 2>&1
fi
fi
command -v haproxy &> /dev/null
}
apply_haproxy_forwarding() {
local mapping="$1" target="$2" config_name="$3"
ensure_haproxy_installed || { colorize red "haproxy is not available; cannot set up haproxy forwarding."; return 1; }
local cfg="/etc/haproxy/haproxy.cfg"
if [[ ! -f "$cfg" ]]; then
mkdir -p "$(dirname "$cfg")"
cat > "$cfg" <<'EOF'
global
    maxconn 20000
defaults
    mode tcp
    timeout connect 5s
    timeout client 1m
    timeout server 1m
EOF
fi
local marker_start="# BEGIN backhaul:${config_name}"
local marker_end="# END backhaul:${config_name}"
awk -v s="$marker_start" -v e="$marker_end" '
$0==s {skip=1}
!skip {print}
$0==e {skip=0}
' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
local entry listen dest idx=0
local -a entries=()
IFS=',' read -r -a entries <<< "$mapping"
{
echo "$marker_start"
for entry in "${entries[@]}"; do
entry="${entry// /}"
[[ -z "$entry" ]] && continue
read -r listen dest <<< "$(parse_port_entry "$entry")"
if [[ "$listen" == *:* ]]; then
colorize yellow "HAProxy forwarder does not support port ranges (${listen}); skipping this entry."
continue
fi
((idx++))
echo "frontend backhaul_${config_name}_${idx}"
echo "    bind *:${listen}"
echo "    default_backend backhaul_${config_name}_${idx}_be"
echo "backend backhaul_${config_name}_${idx}_be"
echo "    server srv1 ${target}:${dest} check"
done
echo "$marker_end"
} >> "$cfg"
if haproxy -c -f "$cfg" &> /dev/null; then
systemctl enable --now haproxy >/dev/null 2>&1
systemctl reload haproxy 2>/dev/null || systemctl restart haproxy 2>/dev/null
colorize green "✔ HAProxy forwarding configured."
else
colorize red "✘ Generated HAProxy config is invalid; not applying. Check with: haproxy -c -f ${cfg}"
return 1
fi
}
remove_haproxy_block() {
local config_name="$1"
local cfg="/etc/haproxy/haproxy.cfg"
[[ -f "$cfg" ]] || return
local marker_start="# BEGIN backhaul:${config_name}"
local marker_end="# END backhaul:${config_name}"
awk -v s="$marker_start" -v e="$marker_end" '
$0==s {skip=1; next}
$0==e {skip=0; next}
!skip {print}
' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
if command -v haproxy &> /dev/null && haproxy -c -f "$cfg" &> /dev/null; then
systemctl reload haproxy 2>/dev/null
fi
}
ensure_ipvsadm_installed() {
if ! command -v ipvsadm &> /dev/null; then
if command -v apt-get &> /dev/null; then
colorize yellow "Installing ipvsadm..."
apt-get update -qq >/dev/null 2>&1
apt-get install -y ipvsadm >/dev/null 2>&1
fi
fi
command -v ipvsadm &> /dev/null
}
apply_ipvs_forwarding() {
local mapping="$1" target="$2" entry listen dest
ensure_ipvsadm_installed || { colorize red "ipvsadm is not available; cannot set up IPVS forwarding."; return 1; }
modprobe ip_vs 2>/dev/null
local -a entries=()
IFS=',' read -r -a entries <<< "$mapping"
for entry in "${entries[@]}"; do
entry="${entry// /}"
[[ -z "$entry" ]] && continue
read -r listen dest <<< "$(parse_port_entry "$entry")"
if [[ "$listen" == *:* ]]; then
colorize yellow "IPVS forwarder does not support port ranges (${listen}); skipping this entry."
continue
fi
ipvsadm -D -t "0.0.0.0:${listen}" 2>/dev/null
ipvsadm -A -t "0.0.0.0:${listen}" -s wrr
ipvsadm -a -t "0.0.0.0:${listen}" -r "${target}:${dest}" -m
done
if command -v ipvsadm-save &> /dev/null; then
ipvsadm-save -n > /etc/ipvsadm.rules 2>/dev/null
systemctl enable ipvsadm >/dev/null 2>&1
fi
colorize green "✔ IPVS forwarding configured."
}
remove_ipvs_forwarding() {
local mapping="$1" entry listen dest
command -v ipvsadm &> /dev/null || return
local -a entries=()
IFS=',' read -r -a entries <<< "$mapping"
for entry in "${entries[@]}"; do
entry="${entry// /}"
[[ -z "$entry" ]] && continue
read -r listen dest <<< "$(parse_port_entry "$entry")"
[[ "$listen" == *:* ]] && continue
ipvsadm -D -t "0.0.0.0:${listen}" 2>/dev/null
done
if command -v ipvsadm-save &> /dev/null; then
ipvsadm-save -n > /etc/ipvsadm.rules 2>/dev/null
fi
}
apply_tun_port_forwarding() {
local mapping="$1" forwarder="$2" tun_remote_addr="$3" tun_name="$4" config_name="$5"
[[ -z "$mapping" ]] && return
local target="${tun_remote_addr%/*}"
allow_forwarded_ports_firewall "backhaul:${config_name}" "$mapping" "true" || return 1
case "$forwarder" in
iptables)
ensure_tun_masquerade "$tun_name"
apply_iptables_dnat_forwarding "$mapping" "$target"
;;
haproxy)
apply_haproxy_forwarding "$mapping" "$target" "$config_name"
;;
ipvs)
ensure_tun_masquerade "$tun_name"
apply_ipvs_forwarding "$mapping" "$target"
;;
*)
:
;;
esac
}
remove_tun_port_forwarding() {
local mapping="$1" forwarder="$2" tun_remote_addr="$3" config_name="$4"
local target="${tun_remote_addr%/*}"
case "$forwarder" in
iptables) remove_iptables_dnat_forwarding "$mapping" "$target" ;;
haproxy) remove_haproxy_block "$config_name" ;;
ipvs) remove_ipvs_forwarding "$mapping" ;;
esac
}
ensure_watchdog_installed() {
local unit_service="${service_dir}/backhaul-watchdog.service"
local unit_timer="${service_dir}/backhaul-watchdog.timer"
if [[ -f "$unit_timer" ]] && grep -q '^OnUnitActiveSec=30s$' "$unit_timer" &&
systemctl is-enabled --quiet backhaul-watchdog.timer 2>/dev/null; then
return
fi
cat > "$unit_service" <<EOF
[Unit]
Description=Backhaul tunnel watchdog

[Service]
Type=oneshot
ExecStart=${PANEL_PATH} --watchdog
EOF
cat > "$unit_timer" <<EOF
[Unit]
Description=Run Backhaul watchdog periodically

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=5s
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now backhaul-watchdog.timer >/dev/null 2>&1
}
backhaul_watchdog_state_file() {
local config_name="$1" suffix="$2"
echo "${config_dir}/.watchdog/${config_name}.${suffix}"
}
backhaul_watchdog_reset_failures() {
rm -f -- "$(backhaul_watchdog_state_file "$1" failures)"
}
backhaul_watchdog_path_ok() {
local config_path="$1" tun_name="$2" remote mtu large_payload
remote=$(toml_get "$config_path" "tun" "remote_addr")
remote="${remote%/*}"
[[ -n "$remote" && -n "$tun_name" ]] || return 1
ping -I "$tun_name" -c 1 -W 2 -s 32 "$remote" >/dev/null 2>&1 && return 0
mtu=$(toml_get "$config_path" "tun" "mtu")
[[ "$mtu" =~ ^[0-9]+$ ]] || mtu=1320
large_payload=$((mtu - 28))
(( large_payload >= 32 )) || large_payload=32
ping -I "$tun_name" -c 1 -W 2 -M "do" -s "$large_payload" "$remote" >/dev/null 2>&1
}
backhaul_watchdog_check_path() {
local config_path="$1" config_name="$2" service_name="$3" tun_name="$4"
local failure_file failures=0
failure_file=$(backhaul_watchdog_state_file "$config_name" failures)
if backhaul_watchdog_path_ok "$config_path" "$tun_name"; then
backhaul_watchdog_reset_failures "$config_name"
return 0
fi
mkdir -p "${config_dir}/.watchdog"
[[ -f "$failure_file" ]] && read -r failures < "$failure_file"
[[ "$failures" =~ ^[0-9]+$ ]] || failures=0
failures=$((failures + 1))
printf '%s\n' "$failures" > "$failure_file"
if (( failures < BACKHAUL_WATCHDOG_FAILURE_LIMIT )); then
return 1
fi
logger -t backhaul-watchdog "${service_name} tunnel path failed ${failures} consecutive checks, restarting" 2>/dev/null
systemctl restart "$service_name" >/dev/null 2>&1 || true
backhaul_watchdog_reset_failures "$config_name"
return 1
}
backhaul_watchdog_health_due() {
local config_name="$1" stamp_file now last=0
stamp_file=$(backhaul_watchdog_state_file "$config_name" health)
now=$(date +%s)
[[ -f "$stamp_file" ]] && read -r last < "$stamp_file"
[[ "$last" =~ ^[0-9]+$ ]] || last=0
if (( now - last < BACKHAUL_HEALTH_SAMPLE_INTERVAL )); then
return 1
fi
mkdir -p "${config_dir}/.watchdog"
printf '%s\n' "$now" > "$stamp_file"
return 0
}
core_backhaul_watchdog_check_all() {
local config_path config_name service_name is_tun is_ipx tun_name
for config_path in "${config_dir}"/{iran,kharej}*.toml; do
[[ -f "$config_path" ]] || continue
config_name=$(basename "${config_path%.toml}")
service_name="backhaul-${config_name}.service"
if ! service_should_run "$service_name"; then
continue
fi
is_ipx="false"; tunnel_is_ipx "$config_path" && is_ipx="true"
if ! systemctl is-active --quiet "$service_name" 2>/dev/null; then
[[ "$is_ipx" == "true" ]] && tunnel_health_run "$config_path" watchdog || true
watchdog_restart_if_enabled "$service_name" "backhaul-watchdog"
backhaul_watchdog_reset_failures "$config_name"
continue
fi
is_tun="false"; tunnel_is_tun "$config_path" && is_tun="true"
if [[ "$is_tun" == "true" ]]; then
tun_name=$(toml_tun_name "$config_path")
if [[ -n "$tun_name" ]] && ! tun_iface_exists "$tun_name"; then
[[ "$is_ipx" == "true" ]] && tunnel_health_run "$config_path" watchdog || true
logger -t backhaul-watchdog "${service_name} TUN interface ${tun_name} is down, restarting" 2>/dev/null
systemctl restart "$service_name" 2>/dev/null
backhaul_watchdog_reset_failures "$config_name"
continue
fi
if [[ "$is_ipx" == "true" ]]; then
backhaul_watchdog_check_path "$config_path" "$config_name" "$service_name" "$tun_name" || true
if backhaul_watchdog_health_due "$config_name"; then
tunnel_health_run "$config_path" watchdog || true
automtu_run "$config_path" watchdog || true
fi
fi
fi
done
}
allow_ipx_protocol_firewall() {
local profile="$1"
local proto=""
case "$profile" in
gre) proto="47" ;;
ipip) proto="4" ;;
icmp) proto="icmp" ;;
*) return 0 ;;
esac
# ufw's `proto` option only recognizes a small keyword whitelist (no raw protocol
# numbers, and no "ipip" keyword at all), so iptables is the actual enforcement here
# regardless of ufw; inserting at the head of INPUT means it takes effect even when
# ufw is separately active, since ACCEPT there is terminal for matching packets.
if command -v iptables &> /dev/null; then
if ! iptables -C INPUT -p "$proto" -j ACCEPT 2>/dev/null; then
iptables -I INPUT -p "$proto" -j ACCEPT
colorize green "Firewall rule added: allow protocol ${proto} (iptables)"
persist_iptables_rules
fi
else
colorize yellow "iptables not found; cannot automatically open protocol ${proto} in the firewall."
fi
if [[ "$profile" == "gre" ]] && command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
ufw allow proto gre from any to any comment "backhaul-ipx-gre" >/dev/null 2>&1
fi
}
tunnel_meta_file() {
echo "${config_dir}/.meta/$1.meta"
}
write_tunnel_meta() {
local config_name="$1" peer_ip="$2" peer_ssh_port="$3" forward_ports="${4:-}"
mkdir -p "${config_dir}/.meta"
{
echo "peer_ip=${peer_ip}"
echo "peer_ssh_port=${peer_ssh_port:-22}"
[[ -n "$forward_ports" ]] && echo "forward_ports=${forward_ports}"
} > "$(tunnel_meta_file "$config_name")"
}
read_tunnel_meta() {
local config_name="$1" key="$2" meta_file
meta_file=$(tunnel_meta_file "$config_name")
[[ -f "$meta_file" ]] || return 1
grep "^${key}=" "$meta_file" 2>/dev/null | tail -1 | cut -d= -f2-
}
write_tunnel_last_test() {
local config_name="$1" result="$2"
mkdir -p "${config_dir}/.status"
echo "${result}|$(date '+%Y-%m-%d %H:%M:%S')" > "${config_dir}/.status/${config_name}.status"
}
read_tunnel_last_test() {
local config_name="$1"
local f="${config_dir}/.status/${config_name}.status"
[[ -f "$f" ]] && cat "$f" || echo "Never tested|-"
}
tunnel_role() {
local file="$1"
if grep -q '^\[listener\]$' "$file" 2>/dev/null; then
echo "server"; return
fi
if grep -q '^\[dialer\]$' "$file" 2>/dev/null; then
echo "client"; return
fi
toml_get "$file" "ipx" "mode"
}
tunnel_is_tun() { grep -q '^\[tun\]$' "$1" 2>/dev/null; }
tunnel_is_ipx() { grep -q '^\[ipx\]$' "$1" 2>/dev/null; }
tunnel_port_number() {
local file="$1" role="$2" addr
if [[ "$role" == "server" ]]; then
addr=$(toml_get "$file" "listener" "bind_addr")
else
addr=$(toml_get "$file" "dialer" "remote_addr")
fi
if [[ -z "$addr" ]]; then
toml_get "$file" "tun" "health_port"
return
fi
echo "${addr##*:}"
}
tunnel_peer_ip() {
local file="$1" config_name="$2" ip
ip=$(read_tunnel_meta "$config_name" "peer_ip")
[[ -z "$ip" ]] && ip=$(toml_get "$file" "ipx" "dst_ip")
echo "$ip"
}
tunnel_peer_ssh_port() {
local p
p=$(read_tunnel_meta "$1" "peer_ssh_port")
echo "${p:-22}"
}
local_role_ready() {
local config_path="$1" is_tun="$2" tun_name="$3" config_name service_name
config_name=$(basename "${config_path%.toml}")
service_name="backhaul-${config_name}.service"
if ! systemctl is-active --quiet "$service_name" 2>/dev/null; then
ROLE_READY=0; ROLE_REASON="service ${service_name} is not active"
return
fi
if [[ "$is_tun" == "true" ]] && ! tun_iface_exists "$tun_name"; then
ROLE_READY=0; ROLE_REASON="TUN interface (${tun_name}) is not up yet"
return
fi
ROLE_READY=1; ROLE_REASON="ready"
}
run_tunnel_diagnostics() {
local config_path="$1"
if [[ ! -f "$config_path" ]]; then
colorize red "Config not found."; press_key; return 1
fi
local config_name role is_tun is_ipx tun_name port peer_ip ssh_port my_label peer_label
config_name=$(basename "${config_path%.toml}")
role=$(tunnel_role "$config_path")
is_tun="false"; tunnel_is_tun "$config_path" && is_tun="true"
is_ipx="false"; tunnel_is_ipx "$config_path" && is_ipx="true"
tun_name=$(toml_tun_name "$config_path")
port=$(tunnel_port_number "$config_path" "$role")
peer_ip=$(tunnel_peer_ip "$config_path" "$config_name")
ssh_port=$(tunnel_peer_ssh_port "$config_name")
if [[ "$role" == "server" ]]; then my_label="IRAN"; peer_label="KHAREJ"; else my_label="KHAREJ"; peer_label="IRAN"; fi

clear
colorize cyan "Tunnel Diagnostics: ${config_name}" bold
echo ""
colorize blue "── ${my_label} side (this server) ──" bold
local_role_ready "$config_path" "$is_tun" "$tun_name"
if [[ "$ROLE_READY" == "1" ]]; then
colorize green "✔ ${my_label} side is ready"
else
colorize red "✘ ${my_label} side is not ready — ${ROLE_REASON}"
fi
if [[ "$is_tun" == "true" ]]; then
local health_port health_status
health_port=$(toml_get "$config_path" "tun" "health_port")
if [[ -n "$health_port" ]]; then
health_status=$(check_health_endpoint "$health_port")
case "$health_status" in
OK) colorize green "✔ Health endpoint (:${health_port}): responding" ;;
OPEN) colorize yellow "Health endpoint (:${health_port}): port open but no HTTP response (may not be an HTTP endpoint)" ;;
*) colorize red "✘ Health endpoint (:${health_port}): not responding" ;;
esac
fi
fi
echo ""

local avg="NA" loss="NA"
if [[ -z "$peer_ip" ]]; then
colorize yellow "Peer IP is not set. Set it from the tunnel's Edit menu to enable full diagnostics (SSH/port/latency/loss)."
echo ""
else
colorize blue "── ${peer_label} side (${peer_ip}) ──" bold
read -r avg loss <<< "$(ping_stats "$peer_ip" 5)"
if [[ "$avg" == "NA" ]]; then
colorize red "✘ ${peer_label} side is not reachable (ping failed)"
else
colorize green "✔ Reachability: OK"
echo "  Latency: ${avg} ms"
echo "  Packet loss: ${loss}%"
fi
if tcp_port_open "$peer_ip" "$ssh_port" 3; then
colorize green "✔ SSH port (${ssh_port}) is open"
else
colorize red "✘ SSH port (${ssh_port}) is closed or filtered"
fi
if [[ "$is_ipx" != "true" && -n "$port" ]]; then
if tcp_port_open "$peer_ip" "$port" 3; then
colorize green "✔ Tunnel port (${port}) is open on this side"
else
colorize yellow "Tunnel port (${port}) did not respond (normal if the peer only listens the other way)"
fi
fi
echo ""
fi

if [[ "$ROLE_READY" != "1" ]]; then
colorize red "Result: ${my_label} side is not ready."
press_key
return 1
fi
if [[ -z "$peer_ip" || "$avg" == "NA" ]]; then
colorize red "Result: ${peer_label} side is not ready or not reachable."
press_key
return 1
fi

colorize blue "── Final End-to-End Test ──" bold
local result="fail"
if [[ "$is_tun" == "true" ]]; then
local tun_remote
tun_remote=$(toml_get "$config_path" "tun" "remote_addr")
tun_remote="${tun_remote%/*}"
if command -v ping &> /dev/null && ping -c 3 -W 2 "$tun_remote" &> /dev/null; then
colorize green "✔ Tunnel is up — ${tun_remote} is reachable through the tunnel"
result="ok"
else
colorize red "✘ Services are up but the tunnel isn't answering yet."
colorize yellow "Check that the peer side is configured with matching settings (tunnel name, subnet)."
fi
else
colorize green "✔ Both sides are reachable and services are active."
colorize yellow "For this transport, the real connection is established once traffic flows; check the service status from Tunnel Management too."
result="ok"
fi
write_tunnel_last_test "$config_name" "$result"
echo ""
press_key
}
install_jq() {
if ! command -v jq &> /dev/null; then
if command -v apt-get &> /dev/null; then
colorize yellow "Installing jq..."
apt-get update && apt-get install -y jq
else
colorize red "Error: Unsupported package manager. Please install jq manually."
press_key
exit 1
fi
fi
}
download_and_extract_backhaul() {
local is_menu="false"
if [[ "${1:-}" == "menu" ]]; then
is_menu="true"
else
[[ -f "${config_dir}/backhaul_premium" ]] && return 1
fi
local arch repo_raw expected tmp_bin commit_sha
arch=$(uname -m)
if [[ "$arch" != "x86_64" ]]; then
colorize red "The repository currently publishes a verified Backhaul Premium binary for x86_64 only (detected: ${arch})."
[[ "$is_menu" == "true" ]] && { press_key; return 1; }
exit 1
fi
if ! commit_sha=$(curl -fsSL "https://api.github.com/repos/dr-hoseyn/tunnel-manager/commits/main" | jq -r '.sha') || [[ ! "$commit_sha" =~ ^[0-9a-f]{40}$ ]]; then
colorize red "Could not resolve the repository commit; keeping the current Backhaul binary."
[[ "$is_menu" == "true" ]] && { press_key; return 1; }
exit 1
fi
repo_raw="https://raw.githubusercontent.com/dr-hoseyn/tunnel-manager/${commit_sha}"
mkdir -p "$config_dir"
tmp_bin=$(mktemp "${config_dir}/.backhaul_premium.XXXXXX")
echo "Downloading verified Backhaul core from the project repository..."
if ! expected=$(curl -fsSL "${repo_raw}/backhaul_premium.sha256" | awk '{print $1}'); then
colorize red "Could not download the Backhaul checksum; refusing an unverified update."
rm -f "$tmp_bin"
[[ "$is_menu" == "true" ]] && { press_key; return 1; }
exit 1
fi
if ! curl -fsSL "${repo_raw}/backhaul_premium" -o "$tmp_bin" || ! verify_sha256 "$tmp_bin" "$expected" "Backhaul core"; then
rm -f "$tmp_bin"
[[ "$is_menu" == "true" ]] && { press_key; return 1; }
exit 1
fi
chmod 0755 "$tmp_bin"
if ! "$tmp_bin" -v &> /dev/null; then
colorize red "Verified core failed its version sanity check; keeping the previous binary."
rm -f "$tmp_bin"
[[ "$is_menu" == "true" ]] && { press_key; return 1; }
exit 1
fi
mv -f "$tmp_bin" "${config_dir}/backhaul_premium"
if [[ "$is_menu" == "true" ]]; then
colorize cyan "Restarting enabled Backhaul services on the verified core..." bold
local service
while IFS= read -r service; do
[[ "$service" == backhaul-iran*.service || "$service" == backhaul-kharej*.service ]] || continue
service_should_run "$service" && systemctl restart "$service" 2>/dev/null
done < <(systemctl list-unit-files 'backhaul-*.service' --no-legend 2>/dev/null | awk '{print $1}')
fi
colorize green "Backhaul installation completed."
}
reset_config() {
CONFIG=()
}
save_config_last_used() {
local mode="$1"
save_last_used "transport_type" "${CONFIG[transport_type]}"
save_last_used "peer_ip" "${CONFIG[peer_ip]}"
if [[ "$mode" == "server" ]]; then
save_last_used "server_tunnel_port" "$(echo "${CONFIG[bind_addr]}" | grep -oP ':\K[0-9]+$')"
else
save_last_used "client_remote_addr" "${CONFIG[remote_addr]}"
fi
}
prompt_connection_section() {
local mode="$1"  # server or client
colorize blue "━━━ Connection Configuration ━━━" bold
if [[ "$mode" == "server" ]]; then
local default_bind_addr="${CONFIG[bind_addr]}"
if [[ -z "$default_bind_addr" ]]; then
default_bind_addr=":$(suggest_tunnel_bind_port "$mode")"
fi
prompt_with_default "Bind Address" "$default_bind_addr" CONFIG[bind_addr]
if [[ -n "${CONFIG[bind_addr]}" && "${CONFIG[bind_addr]}" != *:* ]]; then
CONFIG[bind_addr]=":${CONFIG[bind_addr]}"
fi
else
local old_remote_addr="${CONFIG[remote_addr]}"
local default_remote_addr="${old_remote_addr:-$(get_last_used "client_remote_addr" "")}"
while true; do
if [[ -n "$default_remote_addr" ]]; then
echo -ne "[*] IRAN Server Address [IP:Port] or [Domain:Port] (default: $default_remote_addr): "
else
echo -ne "[*] IRAN Server Address [IP:Port] or [Domain:Port]: "
fi
read -r 'CONFIG[remote_addr]'
CONFIG[remote_addr]="${CONFIG[remote_addr]:-$default_remote_addr}"
if [[ -z "${CONFIG[remote_addr]}" ]]; then
colorize red "Server address cannot be empty."
continue
fi
if [[ "${CONFIG[remote_addr]}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ || \
"${CONFIG[remote_addr]}" =~ ^[a-zA-Z0-9.-]+:[0-9]{1,5}$ ]]; then
break
else
colorize red "Invalid format. Use IP:Port or Domain:Port."
fi
done
if [[ "${CONFIG[transport_type]}" == "ws" || "${CONFIG[transport_type]}" == "wss" || "${CONFIG[transport_type]}" == "wsmux" || "${CONFIG[transport_type]}" == "wssmux" || "${CONFIG[transport_type]}" == "xwsmux" ]]; then
local old_edge_ip="${CONFIG[edge_ip]}"
if [[ -n "$old_edge_ip" ]]; then
echo -ne "[-] Edge IP/Domain (optional, current: $old_edge_ip, press Enter to keep): "
else
echo -ne "[-] Edge IP/Domain (optional, press Enter to skip): "
fi
read -r 'CONFIG[edge_ip]'
CONFIG[edge_ip]="${CONFIG[edge_ip]:-$old_edge_ip}"
fi
CONFIG[dial_timeout]="10"
CONFIG[retry_interval]="3"
fi
local default_peer_ip="${CONFIG[peer_ip]}"
if [[ -z "$default_peer_ip" ]]; then
if [[ "$mode" == "client" ]]; then
default_peer_ip="${CONFIG[remote_addr]%%:*}"
[[ "$default_peer_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || default_peer_ip=""
fi
[[ -z "$default_peer_ip" ]] && default_peer_ip=$(get_last_used "peer_ip" "")
fi
prompt_with_default "Peer Server IP (other side, optional, enables cross-server diagnostics)" "$default_peer_ip" CONFIG[peer_ip]
if [[ -n "${CONFIG[peer_ip]}" ]]; then
prompt_with_default "Peer SSH Port (for diagnostics)" "${CONFIG[peer_ssh_port]:-22}" CONFIG[peer_ssh_port]
fi
echo ""
}
is_valid_algorithm() {
local input="$1"
for alg in "${VALID_ALGORITHMS[@]}"; do
if [[ "$input" == "$alg" ]]; then
return 0
fi
done
return 1
}
prompt_security_section() {
local is_ipx="$1"
colorize blue "━━━ Security Configuration ━━━" bold
if [[ "$is_ipx" == "true" ]]; then
prompt_boolean "Enable Encryption" "${CONFIG[enable_encryption]:-true}" CONFIG[enable_encryption]
if [[ "${CONFIG[enable_encryption]}" == "true" ]]; then
echo
while true; do
colorize magenta "Available algorithms: aes-256-gcm, chacha20-poly1305, aes-128-gcm"
prompt_with_default "Algorithm" "${CONFIG[algorithm]:-aes-256-gcm}" CONFIG[algorithm]
if is_valid_algorithm "${CONFIG[algorithm]}"; then
break
else
colorize red "Invalid algorithm selected. Please choose one from the list."
echo
fi
done
prompt_with_default "PSK (32-char base64)" "${CONFIG[psk]:-pN9m6m0tH3nE3V8xKZ6Lq5yYcW2K1S7QG9u4cF0A8M4=}" CONFIG[psk]
prompt_with_default "KDF Iterations" "${CONFIG[kdf_iterations]:-100000}" CONFIG[kdf_iterations]
fi
else
prompt_with_default "Security Token" "${CONFIG[token]:-your_token}" CONFIG[token]
CONFIG[enable_encryption]="false"
fi
echo ""
}
prompt_transport_section() {
local mode="$1"
local is_ipx="false"
colorize blue "━━━ Transport Configuration ━━━" bold
local valid_transports=(tcp tcpmux xtcpmux ws wss wsmux wssmux xwsmux anytls tun)
echo "Available transports:"
printf '  • %s\n' "${valid_transports[@]}"
local default_transport
default_transport="${CONFIG[transport_type]:-$(get_last_used "transport_type" "tcp")}"
while true; do
echo -ne "Select transport (default: $default_transport): "
read -r 'CONFIG[transport_type]'
CONFIG[transport_type]="${CONFIG[transport_type]:-$default_transport}"
value_in_list "${CONFIG[transport_type]}" "${valid_transports[@]}" && break
colorize red "Invalid transport."
done
if [[ "${CONFIG[transport_type]}" == "tun" ]]; then
echo
local encapsulations=(tcp ipx)
local default_encapsulation="${CONFIG[tun_encapsulation]:-tcp}"
echo "Available encapsulations:"
printf '  • %s\n' "${encapsulations[@]}"
while true; do
echo -ne "Select encapsulation (default: $default_encapsulation): "
read -r 'CONFIG[tun_encapsulation]'
CONFIG[tun_encapsulation]="${CONFIG[tun_encapsulation]:-$default_encapsulation}"
value_in_list "${CONFIG[tun_encapsulation]}" "${encapsulations[@]}" && break
colorize red "Invalid encapsulation."
done
fi
echo
if [[ "${CONFIG[tun_encapsulation]}" == "ipx" ]]; then
is_ipx="true"
fi
if [[ "$is_ipx" != "true" ]]; then
prompt_boolean "Enable TCP_NODELAY" "${CONFIG[nodelay]:-true}" CONFIG[nodelay]
fi
if [[ "$mode" == "server" ]]; then
if [[ "${CONFIG[transport_type]}" == "tcp" ]]; then
prompt_boolean "Accept UDP over TCP" "${CONFIG[accept_udp]:-false}" CONFIG[accept_udp]
fi
if [[ ! "${CONFIG[transport_type]}" =~ ^(tun|ws)$ ]] && [[ "$is_ipx" != "true" ]]; then
prompt_boolean "Enable Proxy Protocol" "${CONFIG[proxy_protocol]:-false}" CONFIG[proxy_protocol]
fi
else
if [[ "${CONFIG[transport_type]}" != "tun" ]]; then
prompt_with_default "Connection Pool" "${CONFIG[connection_pool]:-8}" CONFIG[connection_pool]
fi
fi
CONFIG[heartbeat_interval]="10"
if [[ "$is_ipx" == "true" ]]; then
# IPX traffic can remain usable while its built-in heartbeat is delayed on a
# congested route. The external watchdog performs a three-sample TUN-path
# check, so a long native timeout avoids false reconnect loops without hiding
# a genuinely dead tunnel.
CONFIG[heartbeat_timeout]="604800"
else
CONFIG[heartbeat_timeout]="25"
fi
if [[ "$is_ipx" != "true" ]]; then
CONFIG[keepalive_period]="40"
fi
echo ""
}
prompt_mux_section() {
local transport="$1"
if [[ ! "$transport" =~ mux$ ]]; then
return
fi
colorize blue "━━━ Mux Configuration ━━━" bold
prompt_with_default "Mux Version [1 or 2]" "${CONFIG[mux_version]:-2}" CONFIG[mux_version]
prompt_with_default "Mux Concurrency" "${CONFIG[mux_concurrency]:-8}" CONFIG[mux_concurrency]
CONFIG[mux_framesize]="32768"
CONFIG[mux_recievebuffer]="4194304"
CONFIG[mux_streambuffer]="2097152"
echo ""
}
prompt_tun_section() {
local transport="$1"
local mode="$2"
local is_ipx="$3"
local excluded_config="${4:-}"
[[ "$transport" != "tun" ]] && return
colorize blue "━━━ TUN Configuration ━━━" bold
local suggested_name
suggested_name="${CONFIG[tun_name]:-$(suggest_tun_name)}"
while true; do
prompt_with_default "TUN Device Name" "$suggested_name" CONFIG[tun_name]
if ! is_valid_tun_name "${CONFIG[tun_name]}"; then
colorize red "Invalid name. Use up to 15 letters/digits/-/_ characters (Linux interface name limit)."
elif is_tun_name_in_use "${CONFIG[tun_name]}" "$excluded_config"; then
colorize red "Device name '${CONFIG[tun_name]}' is already used by another tunnel on this server. Choose another."
else
break
fi
done
local suggested_third
suggested_third=$(suggest_tun_subnet_third_octet)
local default_local default_remote
if [[ "$mode" == "server" ]]; then
default_local="${CONFIG[tun_local_addr]:-10.10.${suggested_third}.1/24}"
default_remote="${CONFIG[tun_remote_addr]:-10.10.${suggested_third}.2/24}"
else
default_local="${CONFIG[tun_local_addr]:-10.10.${suggested_third}.2/24}"
default_remote="${CONFIG[tun_remote_addr]:-10.10.${suggested_third}.1/24}"
fi
while true; do
prompt_with_default "TUN Local Address (CIDR)" "$default_local" CONFIG[tun_local_addr]
if ! validate_cidr "${CONFIG[tun_local_addr]}"; then
colorize red "Invalid CIDR format."
continue
fi
if is_tun_subnet_in_use "${CONFIG[tun_local_addr]}" "$excluded_config"; then
colorize red "This subnet overlaps with an existing tunnel's TUN subnet. Choose a different one."
continue
fi
break
done
while true; do
prompt_with_default "TUN Remote Address (CIDR)" "$default_remote" CONFIG[tun_remote_addr]
if ! validate_cidr "${CONFIG[tun_remote_addr]}"; then
colorize red "Invalid CIDR format."
continue
fi
if is_tun_subnet_in_use "${CONFIG[tun_remote_addr]}" "$excluded_config"; then
colorize red "This subnet overlaps with an existing tunnel's TUN subnet. Choose a different one."
continue
fi
break
done
if [[ "$is_ipx" == "true" ]]; then
local original_health_port="${CONFIG[tun_health_port]}"
local suggested_port="${original_health_port:-$(suggest_free_tunnel_port "$mode")}"
while true; do
prompt_with_default "Health Port" "$suggested_port" CONFIG[tun_health_port]
if is_tunnel_port_in_use "$mode" "${CONFIG[tun_health_port]}" "$excluded_config"; then
colorize red "Port ${CONFIG[tun_health_port]} is already used by another ${mode} tunnel on this server. Choose another."
elif [[ "${CONFIG[tun_health_port]}" != "$original_health_port" ]] && is_port_listening_system_wide "${CONFIG[tun_health_port]}"; then
colorize red "Port ${CONFIG[tun_health_port]} is already in use by another process on this server. Choose another."
else
break
fi
done
else
prompt_with_default "Health Port" "${CONFIG[tun_health_port]:-1234}" CONFIG[tun_health_port]
fi
if [[ "$is_ipx" == "true" ]]; then
while true; do
prompt_with_default "MTU" "${CONFIG[tun_mtu]:-1320}" CONFIG[tun_mtu]
if [[ "${CONFIG[tun_mtu]}" =~ ^[0-9]+$ ]] && (( CONFIG[tun_mtu] >= AUTOMTU_HARD_MIN && CONFIG[tun_mtu] <= AUTOMTU_HARD_MAX )); then
break
fi
colorize red "MTU must be between ${AUTOMTU_HARD_MIN} and ${AUTOMTU_HARD_MAX}."
done
prompt_boolean "Enable Smart Auto-MTU" "${CONFIG[smart_auto_mtu]:-false}" CONFIG[smart_auto_mtu]
if [[ "${CONFIG[smart_auto_mtu]}" == "true" ]]; then
while true; do
prompt_with_default "Smart MTU Minimum" "${CONFIG[smart_mtu_min]:-$AUTOMTU_DEFAULT_MIN}" CONFIG[smart_mtu_min]
prompt_with_default "Smart MTU Maximum" "${CONFIG[smart_mtu_max]:-$AUTOMTU_DEFAULT_MAX}" CONFIG[smart_mtu_max]
prompt_with_default "Smart MTU Step" "${CONFIG[smart_mtu_step]:-$AUTOMTU_DEFAULT_STEP}" CONFIG[smart_mtu_step]
if automtu_validate_settings "${CONFIG[smart_mtu_min]}" "${CONFIG[smart_mtu_max]}" "${CONFIG[smart_mtu_step]}" &&
(( CONFIG[tun_mtu] >= CONFIG[smart_mtu_min] && CONFIG[tun_mtu] <= CONFIG[smart_mtu_max] )); then
break
fi
colorize red "Invalid Smart MTU range/step, or current MTU is outside the selected range."
done
fi
else
while true; do
prompt_with_default "MTU" "${CONFIG[tun_mtu]:-1500}" CONFIG[tun_mtu]
if [[ "${CONFIG[tun_mtu]}" =~ ^[0-9]+$ ]] && (( CONFIG[tun_mtu] >= AUTOMTU_HARD_MIN && CONFIG[tun_mtu] <= AUTOMTU_HARD_MAX )); then
break
fi
colorize red "MTU must be between ${AUTOMTU_HARD_MIN} and ${AUTOMTU_HARD_MAX}."
done
CONFIG[smart_auto_mtu]="false"
fi
echo ""
}
prompt_tls_section() {
local mode="$1"
local transport="$2"
if [[ ! "$transport" =~ ^(anytls|wss|wssmux)$ ]]; then
return
fi
colorize blue "━━━ TLS Configuration ━━━" bold
if [[ "$transport" == "anytls" ]]; then
prompt_with_default "SNI" "${CONFIG[tls_sni]:-www.digikala.com}" CONFIG[tls_sni]
fi
if [[ "$mode" == "client" ]]; then
echo
return
fi
ensure_cert_fresh "$CERT_FILE" "$KEY_FILE" && echo
prompt_with_default "TLS Certificate Path" "${CONFIG[tls_cert]:-$CERT_FILE}" CONFIG[tls_cert]
prompt_with_default "TLS Key Path" "${CONFIG[tls_key]:-$KEY_FILE}" CONFIG[tls_key]
echo ""
}
prompt_tuning_section() {
local is_ipx="$1"
local is_tun="$2"
colorize blue "━━━ Tuning Configuration ━━━" bold
prompt_boolean "Enable Auto Tuning" "${CONFIG[auto_tuning]:-true}" CONFIG[auto_tuning]
echo
colorize magenta "Profiles: balanced, fast, latency, resource" normal
local default_tuning_profile="balanced"
[[ "$is_tun" == "true" ]] && default_tuning_profile="fast"
prompt_with_default "Kernel Tuning Profile" "${CONFIG[tuning_profile]:-$default_tuning_profile}" CONFIG[tuning_profile]
prompt_with_default "Workers (0 = auto)" "${CONFIG[workers]:-0}" CONFIG[workers]
if [[ "$is_tun" != "true" ]]; then
prompt_with_default "Channel Size" "${CONFIG[channel_size]:-4096}" CONFIG[channel_size]
fi
if [[ "$is_tun" == "true" ]]; then
CONFIG[channel_size]="10_000"
fi
if [[ "$is_ipx" == "true" ]]; then
prompt_with_default "Batch Size" "${CONFIG[batch_size]:-2048}" CONFIG[batch_size]
prompt_with_default "SO_SNDBUF (0 = auto)" "${CONFIG[so_sndbuf]:-0}" CONFIG[so_sndbuf]
else
prompt_with_default "TCP MSS (0 = auto)" "${CONFIG[tcp_mss]:-0}" CONFIG[tcp_mss]
prompt_with_default "SO_RCVBUF (0 = auto)" "${CONFIG[so_rcvbuf]:-0}" CONFIG[so_rcvbuf]
prompt_with_default "SO_SNDBUF (0 = auto)" "${CONFIG[so_sndbuf]:-0}" CONFIG[so_sndbuf]
fi
if [[ "$is_tun" != "true" ]] && [[ "$is_ipx" != "true" ]]; then
echo
colorize magenta "Buffer Profiles: extreme_low_cpu, ultra_low_cpu, low_cpu, balanced, low_memory" normal
prompt_with_default "Buffer Profile" "${CONFIG[buffer_profile]:-balanced}" CONFIG[buffer_profile]
prompt_with_default "Read Timeout" "${CONFIG[read_timeout]:-120}" CONFIG[read_timeout]
fi
echo ""
}
prompt_logging_section() {
colorize blue "━━━ Logging Configuration ━━━" bold
colorize magenta "Levels: panic, fatal, error, warn, info, debug, trace"
prompt_with_default "Log Level" "${CONFIG[log_level]:-info}" CONFIG[log_level]
echo ""
}
prompt_accept_udp_section() {
local accept_udp="$1"
[[ "$accept_udp" != "true" ]] && return
CONFIG[ring_size]="64"
CONFIG[frame_size]="2048"
CONFIG[peer_idle_timeout_s]="120"
CONFIG[write_timeout_ms]="3"
}
prompt_ports_section() {
local mode="$1"
local is_tun="$2"
[[ "$mode" != "server" ]] && return
if [[ "$is_tun" != "true" ]]; then
colorize blue "━━━ Port Mapping Configuration ━━━" bold
colorize green "Supported formats:"
echo "  1. 443           - Listen on 443, forward to 443"
echo "  2. 443=5000      - Listen on 443, forward to 5000"
echo "  3. 443-600       - Listen on range 443-600"
echo "  4. 443-600:5201  - Range forwarding to 5201"
echo ""
local old_mapping="${CONFIG[ports_mapping]}"
if [[ -n "$old_mapping" ]]; then
echo -ne "Enter port mappings (comma-separated, current: $old_mapping): "
else
echo -ne "Enter port mappings (comma-separated): "
fi
read -r 'CONFIG[ports_mapping]'
CONFIG[ports_mapping]="${CONFIG[ports_mapping]:-$old_mapping}"
echo ""
else
colorize blue "━━━ Port Mapping Configuration (tun helper) ━━━" bold
colorize magenta "Forwarder engines:"
echo "  backhaul  - internal TCP-only proxy, no extra setup"
echo "  iptables  - kernel DNAT, TCP + UDP, lowest overhead"
echo "  haproxy   - userspace TCP proxy with backend health-check"
echo "  ipvs      - kernel-level load balancer (ipvsadm), TCP + UDP"
local -a valid_forwarders=(backhaul iptables haproxy ipvs)
while true; do
prompt_with_default "Forwarder" "${CONFIG[forwarder]:-backhaul}" CONFIG[forwarder]
CONFIG[forwarder]="${CONFIG[forwarder],,}"
[[ " ${valid_forwarders[*]} " == *" ${CONFIG[forwarder]} "* ]] && break
colorize red "Invalid forwarder. Choose one of: ${valid_forwarders[*]}"
done
echo ""
colorize green "Supported formats:"
echo "  1. 443           - Listen on 443, forward to 443"
echo "  2. 443=5000      - Listen on 443, forward to 5000"
echo ""
local old_mapping="${CONFIG[ports_mapping]}"
if [[ -n "$old_mapping" ]]; then
echo -ne "Enter port mappings (comma-separated, current: $old_mapping): "
else
echo -ne "Enter port mappings (comma-separated): "
fi
read -r 'CONFIG[ports_mapping]'
CONFIG[ports_mapping]="${CONFIG[ports_mapping]:-$old_mapping}"
echo ""
fi
}
prompt_ipx_section() {
local is_ipx="$1"
local mode="$2"
[[ "$is_ipx" != "true" ]] && return
colorize blue "━━━ IPX Configuration ━━━" bold
CONFIG[ipx_mode]="$mode"
AVAILABLE_PROFILES=("icmp" "ipip" "udp" "tcp" "gre" "bip")
colorize magenta "Available profiles: ${AVAILABLE_PROFILES[*]}"
while true; do
prompt_with_default "Profile" "${CONFIG[ipx_profile]:-tcp}" CONFIG[ipx_profile]
CONFIG[ipx_profile]="${CONFIG[ipx_profile],,}"
for profile in "${AVAILABLE_PROFILES[@]}"; do
if [[ "${CONFIG[ipx_profile]}" == "$profile" ]]; then
break 2
fi
done
colorize red "Invalid profile: ${CONFIG[ipx_profile]}"
echo
colorize yellow "Please choose one of: ${AVAILABLE_PROFILES[*]}"
done
local interface route_source listen_default
interface="${CONFIG[ipx_interface]:-$(detect_default_interface)}"
prompt_with_default "Network Interface" "$interface" CONFIG[ipx_interface]
route_source=$(detect_route_source_ipv4 "${CONFIG[ipx_interface]}" 2>/dev/null || true)
listen_default="${CONFIG[ipx_listen_ip]:-${route_source:-${SERVER_IP:-${PUBLIC_IPV4:-}}}}"
while true; do
prompt_with_default "Listen IP" "$listen_default" CONFIG[ipx_listen_ip]
if ipv4_is_local_on_interface "${CONFIG[ipx_listen_ip]}" "${CONFIG[ipx_interface]}"; then
break
fi
colorize red "Listen IP must be assigned to ${CONFIG[ipx_interface]}."
colorize yellow "The route-source address (${route_source:-unknown}) is normally the correct choice on multi-IP servers."
done
while :; do
prompt_with_default "Destination IP" "${CONFIG[ipx_dst_ip]:-$(get_last_used "peer_ip" "")}" CONFIG[ipx_dst_ip]
if [[ -n "${CONFIG[ipx_dst_ip]}" ]]; then
break
fi
colorize red "Destination IP cannot be empty."
done
if [[ "${CONFIG[ipx_profile]}" == "icmp" ]]; then
prompt_with_default "ICMP Type" "${CONFIG[ipx_icmp_type]:-0}" CONFIG[ipx_icmp_type]
prompt_with_default "ICMP Code" "${CONFIG[ipx_icmp_code]:-0}" CONFIG[ipx_icmp_code]
fi
echo ""
}
generate_toml_config() {
local mode="$1"
local output_file="$2"
local is_tun="$3"
local is_ipx="$4"
{
if [[ "$mode" == "server" ]] && [[ "$is_ipx" == "false" ]]; then
echo "[listener]"
echo "bind_addr = $(toml_quote "${CONFIG[bind_addr]}")"
echo ""
elif [[ "$is_ipx" == "false" ]]; then
echo "[dialer]"
echo "remote_addr = $(toml_quote "${CONFIG[remote_addr]}")"
[[ -n "${CONFIG[edge_ip]}" ]] && echo "edge_ip = $(toml_quote "${CONFIG[edge_ip]}")"
echo "dial_timeout = ${CONFIG[dial_timeout]}"
echo "retry_interval = ${CONFIG[retry_interval]}"
echo ""
fi
echo "[transport]"
echo "type = $(toml_quote "${CONFIG[transport_type]}")"
[[ -n "${CONFIG[nodelay]}" ]] && echo "nodelay = ${CONFIG[nodelay]}"
[[ -n "${CONFIG[keepalive_period]}" ]] && echo "keepalive_period = ${CONFIG[keepalive_period]}"
if [[ "$mode" == "server" ]]; then
[[ -n "${CONFIG[accept_udp]}" ]] && echo "accept_udp = ${CONFIG[accept_udp]}"
[[ -n "${CONFIG[proxy_protocol]}" ]] && echo "proxy_protocol = ${CONFIG[proxy_protocol]}"
else
[[ -n "${CONFIG[connection_pool]}" ]] && [[ "${CONFIG[connection_pool]}" != "0" ]] && \
echo "connection_pool = ${CONFIG[connection_pool]}"
fi
[[ -n "${CONFIG[heartbeat_interval]}" ]] && echo "heartbeat_interval = ${CONFIG[heartbeat_interval]}"
[[ -n "${CONFIG[heartbeat_timeout]}" ]] && echo "heartbeat_timeout = ${CONFIG[heartbeat_timeout]}"
echo ""
if [[ "$is_tun" == "true" ]]; then
echo "[tun]"
echo "encapsulation = $(toml_quote "${CONFIG[tun_encapsulation]}")"
echo "name = $(toml_quote "${CONFIG[tun_name]}")"
echo "local_addr = $(toml_quote "${CONFIG[tun_local_addr]}")"
echo "remote_addr = $(toml_quote "${CONFIG[tun_remote_addr]}")"
echo "health_port = ${CONFIG[tun_health_port]}"
echo "mtu = ${CONFIG[tun_mtu]}"
echo ""
fi
if [[ "$is_ipx" == "true" ]]; then
echo "[ipx]"
echo "mode = $(toml_quote "${CONFIG[ipx_mode]}")"
echo "profile = $(toml_quote "${CONFIG[ipx_profile]}")"
echo "listen_ip = $(toml_quote "${CONFIG[ipx_listen_ip]}")"
echo "dst_ip = $(toml_quote "${CONFIG[ipx_dst_ip]}")"
echo "interface = $(toml_quote "${CONFIG[ipx_interface]}")"
[[ -n "${CONFIG[ipx_icmp_type]}" ]] && echo "icmp_type = ${CONFIG[ipx_icmp_type]}"
[[ -n "${CONFIG[ipx_icmp_code]}" ]] && echo "icmp_code = ${CONFIG[ipx_icmp_code]}"
echo ""
fi
if [[ "${CONFIG[transport_type]}" =~ mux$ ]]; then
echo "[mux]"
echo "mux_version = ${CONFIG[mux_version]}"
echo "mux_framesize = ${CONFIG[mux_framesize]}"
echo "mux_recievebuffer = ${CONFIG[mux_recievebuffer]}"
echo "mux_streambuffer = ${CONFIG[mux_streambuffer]}"
[[ -n "${CONFIG[mux_concurrency]}" ]] && echo "mux_concurrency = ${CONFIG[mux_concurrency]}"
echo ""
fi
echo "[security]"
if [[ "$is_ipx" == "true" ]]; then
echo "enable_encryption = ${CONFIG[enable_encryption]}"
[[ "${CONFIG[enable_encryption]}" == "true" ]] && {
echo "algorithm = $(toml_quote "${CONFIG[algorithm]}")"
echo "psk = $(toml_quote "${CONFIG[psk]}")"
echo "kdf_iterations = ${CONFIG[kdf_iterations]}"
}
else
echo "token = $(toml_quote "${CONFIG[token]}")"
fi
echo ""
if [[ -n "${CONFIG[tls_sni]}" || -n "${CONFIG[tls_cert]}" ]]; then
echo "[tls]"
[[ -n "${CONFIG[tls_sni]}" ]]  && echo "sni = $(toml_quote "${CONFIG[tls_sni]}")"
[[ -n "${CONFIG[tls_cert]}" ]] && echo "tls_cert = $(toml_quote "${CONFIG[tls_cert]}")"
[[ -n "${CONFIG[tls_key]}" ]]  && echo "tls_key = $(toml_quote "${CONFIG[tls_key]}")"
echo ""
fi
echo "[tuning]"
[[ -n "${CONFIG[auto_tuning]}" ]]     && echo "auto_tuning = ${CONFIG[auto_tuning]}"
[[ -n "${CONFIG[tuning_profile]}" ]]  && echo "tuning_profile = $(toml_quote "${CONFIG[tuning_profile]}")"
[[ -n "${CONFIG[workers]}" ]]         && echo "workers = ${CONFIG[workers]}"
[[ -n "${CONFIG[channel_size]}" ]]    && echo "channel_size = ${CONFIG[channel_size]}"
[[ -n "${CONFIG[tcp_mss]}" ]]         && echo "tcp_mss = ${CONFIG[tcp_mss]}"
[[ -n "${CONFIG[so_rcvbuf]}" ]]       && echo "so_rcvbuf = ${CONFIG[so_rcvbuf]}"
[[ -n "${CONFIG[so_sndbuf]}" ]]       && echo "so_sndbuf = ${CONFIG[so_sndbuf]}"
[[ -n "${CONFIG[buffer_profile]}" ]]  && echo "buffer_profile = $(toml_quote "${CONFIG[buffer_profile]}")"
[[ -n "${CONFIG[batch_size]}" ]]      && echo "batch_size = ${CONFIG[batch_size]}"
[[ -n "${CONFIG[read_timeout]}" ]]    && echo "read_timeout = ${CONFIG[read_timeout]}"
echo ""
if [[ "${CONFIG[accept_udp]}" == "true" ]]; then
echo "[accept_udp]"
echo "ring_size = ${CONFIG[ring_size]}"
echo "frame_size = ${CONFIG[frame_size]}"
echo "peer_idle_timeout_s = ${CONFIG[peer_idle_timeout_s]}"
echo "write_timeout_ms = ${CONFIG[write_timeout_ms]}"
echo ""
fi
echo "[logging]"
echo "log_level = $(toml_quote "${CONFIG[log_level]}")"
echo ""
if [[ "$mode" == "server" ]] ; then
echo "[ports]"
[[ -n "${CONFIG[forwarder]}" ]]  && echo "forwarder = $(toml_quote "${CONFIG[forwarder]}")"
echo "mapping = ["
IFS=',' read -r -a ports <<< "${CONFIG[ports_mapping]}"
for port in "${ports[@]}"; do
[[ -n "$port" ]] && echo "    $(toml_quote "${port// /}"),"
done
echo "]"
fi
} > "$output_file"
}
configure_server() {
local mode="$1"  # server or client
local mode_name
if [[ "$mode" == "server" ]]; then
mode_name="IRAN (Server)"
else
mode_name="KHAREJ (Client)"
fi
clear
colorize cyan "Configuring $mode_name" bold
echo ""
reset_config
prompt_transport_section "$mode"
local is_tun="false"
local is_ipx="false"
[[ "${CONFIG[transport_type]}" == "tun" ]] && is_tun="true"
[[ "${CONFIG[tun_encapsulation]}" == "ipx" ]] && is_ipx="true"
prompt_tun_section "${CONFIG[transport_type]}" "$mode" "$is_ipx"
prompt_ipx_section "$is_ipx" "$mode"
if [[ "$is_ipx" != "true" ]]; then
prompt_connection_section "$mode"
fi
prompt_security_section "$is_ipx"
prompt_accept_udp_section "${CONFIG[accept_udp]}"
prompt_mux_section "${CONFIG[transport_type]}"
prompt_tls_section "$mode" "${CONFIG[transport_type]}"
prompt_tuning_section "$is_ipx" "$is_tun"
prompt_logging_section
prompt_ports_section "$mode" "$is_tun"
if [[ "$mode" == "server" ]] && ! validate_port_mapping_csv "${CONFIG[ports_mapping]}" true; then
colorize red "Invalid port mapping. Use forms such as 443, 443=5000 or 443-600:5201."
press_key
return 1
fi
local tunnel_port
if [[ "$mode" == "server" ]]; then
tunnel_port=$(echo "${CONFIG[bind_addr]}" | grep -oP ':\K[0-9]+$')
else
tunnel_port=$(echo "${CONFIG[remote_addr]}" | grep -oP ':\K[0-9]+$')
fi
if [[ -z "$tunnel_port" ]]; then
tunnel_port=$(echo "${CONFIG[tun_health_port]}")
fi
if ! validate_port_number "$tunnel_port"; then
colorize red "Invalid tunnel/control port: ${tunnel_port}"
press_key
return 1
fi
local config_file
if [[ "$mode" == "server" ]]; then
config_file="${config_dir}/iran${tunnel_port}.toml"
else
config_file="${config_dir}/kharej${tunnel_port}.toml"
fi
if [[ -e "$config_file" ]]; then
colorize red "A Backhaul tunnel already uses port ${tunnel_port} on this side. Choose a different port."
press_key
return 1
fi
generate_toml_config "$mode" "$config_file" "$is_tun" "$is_ipx"
save_config_last_used "$mode"
local service_type
[[ "$mode" == "server" ]] && service_type="iran" || service_type="kharej"
if [[ "$is_tun" == "true" ]]; then
prepare_tun_ipx_kernel "$is_ipx" "${CONFIG[ipx_profile]}" "${CONFIG[tun_name]}"
fi
if [[ "$is_ipx" == "true" ]]; then
allow_ipx_protocol_firewall "${CONFIG[ipx_profile]}"
fi
local config_name
config_name=$(basename "${config_file%.toml}")
local firewall_ok="true"
if [[ "$mode" == "server" ]]; then
tm_firewall_close_owner "backhaul:${config_name}:control"
if [[ "$is_ipx" != "true" ]]; then
tm_firewall_open_port "backhaul:${config_name}:control" "$tunnel_port" tcp || firewall_ok="false"
elif [[ "${CONFIG[ipx_profile]}" == "tcp" || "${CONFIG[ipx_profile]}" == "udp" ]]; then
tm_firewall_open_port "backhaul:${config_name}:control" "$tunnel_port" "${CONFIG[ipx_profile]}" || firewall_ok="false"
fi
if [[ "$firewall_ok" == "true" ]]; then
if [[ "$is_tun" == "true" ]]; then
apply_tun_port_forwarding "${CONFIG[ports_mapping]}" "${CONFIG[forwarder]}" "${CONFIG[tun_remote_addr]}" "${CONFIG[tun_name]}" "$config_name" || firewall_ok="false"
else
allow_forwarded_ports_firewall "backhaul:${config_name}" "${CONFIG[ports_mapping]}" "${CONFIG[accept_udp]}" || firewall_ok="false"
fi
fi
fi
if [[ "$firewall_ok" != "true" ]]; then
tm_firewall_close_owner "backhaul:${config_name}"
tm_firewall_close_owner "backhaul:${config_name}:control"
[[ "$is_tun" == "true" ]] && remove_tun_port_forwarding "${CONFIG[ports_mapping]}" "${CONFIG[forwarder]}" "${CONFIG[tun_remote_addr]}" "$config_name"
rm -f "$config_file"
return 1
fi
if ! create_systemd_service "$service_type" "$tunnel_port" "$config_file"; then
tm_firewall_close_owner "backhaul:${config_name}"
tm_firewall_close_owner "backhaul:${config_name}:control"
[[ "$is_tun" == "true" ]] && remove_tun_port_forwarding "${CONFIG[ports_mapping]}" "${CONFIG[forwarder]}" "${CONFIG[tun_remote_addr]}" "$config_name"
rm -f "$config_file" "${service_dir}/backhaul-${service_type}${tunnel_port}.service"
systemctl daemon-reload
colorize red "Service failed to start. Check: journalctl -eu backhaul-${service_type}${tunnel_port}.service"
return 1
fi
local peer_ip_for_meta="${CONFIG[peer_ip]}"
[[ -z "$peer_ip_for_meta" && "$is_ipx" == "true" ]] && peer_ip_for_meta="${CONFIG[ipx_dst_ip]}"
write_tunnel_meta "$config_name" "$peer_ip_for_meta" "${CONFIG[peer_ssh_port]}"
if [[ "$is_ipx" == "true" ]]; then
automtu_save_settings "$config_name" "${CONFIG[smart_auto_mtu]:-false}" "${CONFIG[smart_mtu_min]:-$AUTOMTU_DEFAULT_MIN}" "${CONFIG[smart_mtu_max]:-$AUTOMTU_DEFAULT_MAX}" "${CONFIG[smart_mtu_step]:-$AUTOMTU_DEFAULT_STEP}"
automtu_reset_learning "$config_name"
else
automtu_delete_state "$config_name" 2>/dev/null || true
fi
ensure_watchdog_installed
ensure_journal_limits
echo ""
colorize green "✔ Configuration completed successfully!" bold
echo ""
run_tunnel_diagnostics "$config_file"
}
create_systemd_service() {
local type="$1"
local port="$2"
local config_file="$3"
local service_file="${service_dir}/backhaul-${type}${port}.service"
local desc_type
desc_type="$(tr '[:lower:]' '[:upper:]' <<< "${type:0:1}")${type:1}"
cat > "$service_file" <<EOF
[Unit]
Description=Backhaul $desc_type Port $port
After=network.target
[Service]
Type=simple
User=root
ExecStart=${config_dir}/backhaul_premium -c $config_file
Restart=always
RestartSec=3
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity
IPAccounting=yes
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
if ! enable_service_checked "backhaul-${type}${port}.service"; then
colorize red "Backhaul service backhaul-${type}${port} did not become active."
return 1
fi
colorize green "✔ Service backhaul-${type}${port} created and started" bold
}
display_logo() {
echo -e "\033[36m"
cat << "EOF"
▗▄▄▖  ▗▄▖  ▗▄▄▖▗▖ ▗▖▗▖ ▗▖ ▗▄▖ ▗▖ ▗▖▗▖
▐▌ ▐▌▐▌ ▐▌▐▌   ▐▌▗▞▘▐▌ ▐▌▐▌ ▐▌▐▌ ▐▌▐▌
▐▛▀▚▖▐▛▀▜▌▐▌   ▐▛▚▖ ▐▛▀▜▌▐▛▀▜▌▐▌ ▐▌▐▌
▐▙▄▞▘▐▌ ▐▌▝▚▄▄▖▐▌ ▐▌▐▌ ▐▌▐▌ ▐▌▝▚▄▞▘▐▙▄▄▖
Lightning-fast reverse tunneling solution
EOF
echo -e "\033[0m\033[32m"
echo -e "Script Version: \033[33m${SCRIPT_VERSION}\033[32m"
[[ -f "${config_dir}/backhaul_premium" ]] && \
echo -e "Core Version: \033[33m$($config_dir/backhaul_premium -v)\033[32m"
}
display_server_info() {
echo -e "\e[93m═══════════════════════════════════════════\e[0m"
echo -e "\033[36mLocal IP:\033[0m $SERVER_IP"
[[ -n "$PUBLIC_IPV4" ]] && echo -e "\033[36mPublic IPv4:\033[0m $PUBLIC_IPV4"
[[ -n "$PUBLIC_IPV6" ]] && echo -e "\033[36mPublic IPv6:\033[0m $PUBLIC_IPV6"
echo -e "\033[36mLocation:\033[0m $SERVER_COUNTRY"
echo -e "\033[36mDatacenter:\033[0m $SERVER_ISP"
}
display_backhaul_core_status() {
if [[ -f "${config_dir}/backhaul_premium" ]]; then
echo -e "\033[36mBackhaul Core:\033[0m \033[32mInstalled\033[0m"
else
echo -e "\033[36mBackhaul Core:\033[0m \033[31mNot installed\033[0m"
fi
if [[ -f "$CERT_FILE" ]]; then
local cert_days
cert_days=$(cert_days_remaining "$CERT_FILE")
if (( cert_days > 30 )); then
echo -e "\033[36mTLS Certificate:\033[0m \033[32mvalid for ${cert_days} more days\033[0m"
elif (( cert_days > 0 )); then
echo -e "\033[36mTLS Certificate:\033[0m \033[33mexpires in ${cert_days} days (renewal changes Hysteria/TUIC peer trust)\033[0m"
else
echo -e "\033[36mTLS Certificate:\033[0m \033[31mexpired (peer trust must be updated after renewal)\033[0m"
fi
fi
echo -e "\e[93m═══════════════════════════════════════════\e[0m"
}
check_config_backup() {
missing_services=()
for config in "${config_dir}"/iran*.toml "${config_dir}"/kharej*.toml; do
[ -e "$config" ] || continue
fname=$(basename "$config")
if [[ "$fname" =~ ^(iran|kharej)([0-9]+)\.toml$ ]]; then
location="${BASH_REMATCH[1]}"
tunnel_port="${BASH_REMATCH[2]}"
service_file="${service_dir}/backhaul-${location}${tunnel_port}.service"
if [[ ! -f "$service_file" ]]; then
missing_services+=("$service_file:$location:$tunnel_port")
fi
fi
done
[[ ${#missing_services[@]} -eq 0 ]] && return 0
echo
colorize red "Missing service files:" bold
for entry in "${missing_services[@]}"; do
service_file="${entry%%:*}"
location="${entry#*:}"; location="${location%%:*}"
tunnel_port="${entry##*:}"
echo "- $service_file (type: $location, port: $tunnel_port)"
done
echo
read -r -p "Do you want to create missing service files? (y/n): " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
for entry in "${missing_services[@]}"; do
service_file="${entry%%:*}"
location="${entry#*:}"; location="${location%%:*}"
tunnel_port="${entry##*:}"
config_file="${config_dir}/${location}${tunnel_port}.toml"
desc_loc="$(tr '[:lower:]' '[:upper:]' <<< "${location:0:1}")${location:1}"
cat > "$service_file" <<EOF
[Unit]
Description=Backhaul $desc_loc Port $tunnel_port
After=network.target
[Service]
Type=simple
User=root
ExecStart=${config_dir}/backhaul_premium -c $config_file
Restart=always
RestartSec=3
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity
IPAccounting=yes
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now "$(basename "$service_file")"
echo "Created and started $(basename "$service_file")"
done
fi
sleep 2
}
core_backhaul_status() {
if ! ls "$config_dir"/*.toml 1> /dev/null 2>&1; then
colorize red "No config files found." bold
press_key
return 1
fi
clear
colorize yellow "Checking all services status..." bold
sleep 1
echo
for config_path in "$config_dir"/{iran,kharej}*.toml; do
[ -f "$config_path" ] || continue
config_name=$(basename "$config_path")
config_name="${config_name%.toml}"
service_name="backhaul-${config_name}.service"
if [[ "$config_name" =~ ^iran([0-9]+)$ ]]; then
port="${BASH_REMATCH[1]}"
if systemctl is-active --quiet "$service_name"; then
colorize green "Iran service (port $port) is running"
else
colorize red "Iran service (port $port) is not running"
fi
elif [[ "$config_name" =~ ^kharej([0-9]+)$ ]]; then
port="${BASH_REMATCH[1]}"
if systemctl is-active --quiet "$service_name"; then
colorize green "Kharej service (port $port) is running"
else
colorize red "Kharej service (port $port) is not running"
fi
fi
done
echo
press_key
}
core_backhaul_manage() {
if ! ls "$config_dir"/*.toml 1> /dev/null 2>&1; then
colorize red "No config files found." bold
press_key
return 1
fi
clear
colorize cyan "Existing services:" bold
echo
local index=1
declare -a configs
for config_path in "$config_dir"/{iran,kharej}*.toml; do
[ -f "$config_path" ] || continue
config_name=$(basename "$config_path")
if [[ "$config_name" =~ ^iran([0-9]+)\.toml$ ]]; then
port="${BASH_REMATCH[1]}"
configs+=("$config_path")
echo -e "\033[35m${index}\033[0m) \033[32mIran\033[0m (port: \033[33m$port\033[0m)"
((index++))
elif [[ "$config_name" =~ ^kharej([0-9]+)\.toml$ ]]; then
port="${BASH_REMATCH[1]}"
configs+=("$config_path")
echo -e "\033[35m${index}\033[0m) \033[32mKharej\033[0m (port: \033[33m$port\033[0m)"
((index++))
fi
done
echo
colorize yellow "R) Restart all tunnels"
echo
echo -ne "Enter your choice (0 to return): "
read -r choice
[[ "$choice" == "0" ]] && return
if [[ "$choice" =~ ^[Rr]$ ]]; then
restart_all_tunnels
return
fi
while ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#configs[@]} )); do
colorize red "Invalid choice."
echo -ne "Enter your choice (0 to return): "
read -r choice
[[ "$choice" == "0" ]] && return
[[ "$choice" =~ ^[Rr]$ ]] && { restart_all_tunnels; return; }
done
selected_config="${configs[$((choice - 1))]}"
tunnel_detail_page "$selected_config"
}
restart_all_tunnels() {
local config_path config_name service_name
clear
colorize yellow "Restarting all tunnels..." bold
echo ""
for config_path in "${config_dir}"/{iran,kharej}*.toml; do
[[ -f "$config_path" ]] || continue
config_name=$(basename "${config_path%.toml}")
service_name="backhaul-${config_name}.service"
systemctl restart "$service_name" 2>/dev/null
sleep 1
if systemctl is-active --quiet "$service_name"; then
colorize green "✔ ${service_name} restarted"
else
colorize red "✘ ${service_name} failed to restart"
fi
done
echo ""
press_key
}
load_toml_ports_mapping() {
awk '
/^mapping = \[/ { inarr=1; next }
inarr && /^\]/ { inarr=0 }
inarr {
line=$0
gsub(/^[ \t]+|[ \t]*,?[ \t]*$/, "", line)
gsub(/^"|"$/, "", line)
if (length(line) > 0) printf "%s,", line
}
' "$1" 2>/dev/null | sed 's/,$//'
}
load_toml_into_config() {
local file="$1"
local config_name="${2:-}"
reset_config
CONFIG[bind_addr]=$(toml_get "$file" "listener" "bind_addr")
CONFIG[remote_addr]=$(toml_get "$file" "dialer" "remote_addr")
CONFIG[edge_ip]=$(toml_get "$file" "dialer" "edge_ip")
CONFIG[transport_type]=$(toml_get "$file" "transport" "type")
CONFIG[accept_udp]=$(toml_get "$file" "transport" "accept_udp")
CONFIG[proxy_protocol]=$(toml_get "$file" "transport" "proxy_protocol")
CONFIG[connection_pool]=$(toml_get "$file" "transport" "connection_pool")
CONFIG[tun_encapsulation]=$(toml_get "$file" "tun" "encapsulation")
CONFIG[tun_name]=$(toml_get "$file" "tun" "name")
CONFIG[tun_local_addr]=$(toml_get "$file" "tun" "local_addr")
CONFIG[tun_remote_addr]=$(toml_get "$file" "tun" "remote_addr")
CONFIG[tun_health_port]=$(toml_get "$file" "tun" "health_port")
CONFIG[tun_mtu]=$(toml_get "$file" "tun" "mtu")
CONFIG[ipx_mode]=$(toml_get "$file" "ipx" "mode")
CONFIG[ipx_profile]=$(toml_get "$file" "ipx" "profile")
CONFIG[ipx_listen_ip]=$(toml_get "$file" "ipx" "listen_ip")
CONFIG[ipx_dst_ip]=$(toml_get "$file" "ipx" "dst_ip")
CONFIG[ipx_interface]=$(toml_get "$file" "ipx" "interface")
CONFIG[ipx_icmp_type]=$(toml_get "$file" "ipx" "icmp_type")
CONFIG[ipx_icmp_code]=$(toml_get "$file" "ipx" "icmp_code")
CONFIG[mux_version]=$(toml_get "$file" "mux" "mux_version")
CONFIG[mux_concurrency]=$(toml_get "$file" "mux" "mux_concurrency")
CONFIG[enable_encryption]=$(toml_get "$file" "security" "enable_encryption")
CONFIG[algorithm]=$(toml_get "$file" "security" "algorithm")
CONFIG[psk]=$(toml_get "$file" "security" "psk")
CONFIG[kdf_iterations]=$(toml_get "$file" "security" "kdf_iterations")
CONFIG[token]=$(toml_get "$file" "security" "token")
CONFIG[tls_sni]=$(toml_get "$file" "tls" "sni")
CONFIG[tls_cert]=$(toml_get "$file" "tls" "tls_cert")
CONFIG[tls_key]=$(toml_get "$file" "tls" "tls_key")
CONFIG[auto_tuning]=$(toml_get "$file" "tuning" "auto_tuning")
CONFIG[tuning_profile]=$(toml_get "$file" "tuning" "tuning_profile")
CONFIG[workers]=$(toml_get "$file" "tuning" "workers")
CONFIG[log_level]=$(toml_get "$file" "logging" "log_level")
CONFIG[forwarder]=$(toml_get "$file" "ports" "forwarder")
CONFIG[ports_mapping]=$(load_toml_ports_mapping "$file")
[[ -n "$config_name" ]] || config_name=$(basename "${file%.toml}")
CONFIG[peer_ip]=$(tunnel_peer_ip "$file" "$config_name")
CONFIG[peer_ssh_port]=$(tunnel_peer_ssh_port "$config_name")
if tunnel_is_ipx "$file"; then
automtu_load_settings_into_config "$config_name" 2>/dev/null || true
fi
}
toggle_tunnel_enabled() {
local service_name="$1"
if systemctl is-active --quiet "$service_name"; then
systemctl disable --now "$service_name" >/dev/null 2>&1
colorize yellow "Tunnel disabled."
else
systemctl enable --now "$service_name" >/dev/null 2>&1
sleep 1
if systemctl is-active --quiet "$service_name"; then
colorize green "Tunnel enabled."
else
colorize red "Failed to enable. Check logs: journalctl -eu ${service_name}"
fi
fi
press_key
}
apply_ports_mapping() {
local config_path="$1" service_name="$2" new_mapping="$3" service_path config_name backup_dir
if ! validate_port_mapping_csv "$new_mapping" true; then
colorize red "Invalid port mapping. Use ports/ranges from 1 to 65535."
press_key
return 1
fi
service_path="${service_dir}/${service_name}"
config_name=$(basename "${config_path%.toml}")
backup_dir=$(backup_tunnel "$config_path" "$service_path" "$config_name")

local is_tun="false" forwarder old_mapping tun_remote_addr tun_name old_accept_udp
tunnel_is_tun "$config_path" && is_tun="true"
forwarder=$(toml_get "$config_path" "ports" "forwarder")
old_mapping=$(load_toml_ports_mapping "$config_path")
old_accept_udp=$(toml_get "$config_path" "transport" "accept_udp")
tun_remote_addr=$(toml_get "$config_path" "tun" "remote_addr")
tun_name=$(toml_tun_name "$config_path")
if [[ "$is_tun" == "true" && -n "$forwarder" && "$forwarder" != "backhaul" ]]; then
remove_tun_port_forwarding "$old_mapping" "$forwarder" "$tun_remote_addr" "$config_name"
fi

local apply_ok="true"
awk -v newmap="$new_mapping" '
BEGIN { n = split(newmap, arr, ",") }
/^mapping = \[/ {
print
for (i=1;i<=n;i++) { if (length(arr[i])>0) printf "    \"%s\",\n", arr[i] }
inarr=1; next
}
inarr && /^\]/ { print; inarr=0; next }
inarr { next }
{ print }
' "$config_path" > "${config_path}.new" && mv "${config_path}.new" "$config_path" || apply_ok="false"

if [[ "$apply_ok" == "true" ]]; then
if [[ "$is_tun" == "true" ]]; then
apply_tun_port_forwarding "$new_mapping" "$forwarder" "$tun_remote_addr" "$tun_name" "$config_name" || apply_ok="false"
else
allow_forwarded_ports_firewall "backhaul:${config_name}" "$new_mapping" "$old_accept_udp" || apply_ok="false"
fi
fi
if [[ "$apply_ok" == "true" ]]; then
if declare -F core_optimize_sync_for_tunnel >/dev/null; then
core_optimize_sync_for_tunnel before "$service_name" || true
fi
systemctl restart "$service_name" || apply_ok="false"
sleep 2
fi
if [[ "$apply_ok" == "true" ]] && systemctl is-active --quiet "$service_name"; then
colorize green "✔ Ports updated and service restarted."
if declare -F core_optimize_sync_for_tunnel >/dev/null; then
core_optimize_sync_for_tunnel after "$service_name" || true
fi
rm -rf "$backup_dir"
else
colorize red "✘ Service failed to come back up; rolling back..."
rm -f "${config_path}.new"
if [[ "$is_tun" == "true" && -n "$forwarder" && "$forwarder" != "backhaul" ]]; then
remove_tun_port_forwarding "$new_mapping" "$forwarder" "$tun_remote_addr" "$config_name"
fi
restore_tunnel_backup "$backup_dir" "$config_path" "$service_path" "$service_name"
if [[ "$is_tun" == "true" ]]; then
apply_tun_port_forwarding "$old_mapping" "$forwarder" "$tun_remote_addr" "$tun_name" "$config_name"
else
allow_forwarded_ports_firewall "backhaul:${config_name}" "$old_mapping" "$old_accept_udp"
fi
if systemctl is-active --quiet "$service_name"; then
colorize green "✔ Rollback succeeded."
else
colorize red "✘ Rollback also failed! Check logs manually: journalctl -eu ${service_name}"
fi
fi
press_key
}
edit_tunnel_ports() {
local config_path="$1" mode="$2" config_name service_name
if [[ "$mode" != "server" ]]; then
colorize red "This section is only available for the IRAN (server) side."
press_key
return
fi
config_name=$(basename "${config_path%.toml}")
service_name="backhaul-${config_name}.service"
while true; do
clear
colorize cyan "Forwarded Ports — ${config_name}" bold
echo ""
local current
current=$(load_toml_ports_mapping "$config_path")
local -a ports_arr=()
IFS=',' read -r -a ports_arr <<< "$current"
local i=1 p
for p in "${ports_arr[@]}"; do
[[ -n "$p" ]] && echo "  $i) $p" && ((i++))
done
[[ "$i" == "1" ]] && colorize yellow "  (no ports configured)"
echo ""
colorize green "a) Add a new port"
colorize red "d) Remove a port"
colorize yellow "e) Edit a port"
echo "0) Back"
read -r -p "Choice: " choice
case "$choice" in
a)
echo -ne "New port (e.g. 443 or 443=5000): "
read -r new_port
if [[ -n "$new_port" ]]; then
current="${current:+$current,}${new_port}"
apply_ports_mapping "$config_path" "$service_name" "$current"
fi
;;
d)
read -r -p "Row number to remove: " idx
if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx < i )); then
unset 'ports_arr[idx-1]'
current=$(IFS=,; echo "${ports_arr[*]}")
apply_ports_mapping "$config_path" "$service_name" "$current"
else
colorize red "Invalid choice"; sleep 1
fi
;;
e)
read -r -p "Row number to edit: " idx
if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx < i )); then
echo -ne "New value: "
read -r new_val
ports_arr[idx-1]="$new_val"
current=$(IFS=,; echo "${ports_arr[*]}")
apply_ports_mapping "$config_path" "$service_name" "$current"
else
colorize red "Invalid choice"; sleep 1
fi
;;
0) return ;;
*) colorize red "Invalid choice"; sleep 1 ;;
esac
done
}
edit_tunnel_full() {
local config_path="$1" mode="$2"
local config_name service_name service_path
config_name=$(basename "${config_path%.toml}")
service_name="backhaul-${config_name}.service"
service_path="${service_dir}/${service_name}"
local backup_dir
backup_dir=$(backup_tunnel "$config_path" "$service_path" "$config_name")
colorize green "Current config backed up: $backup_dir"
load_toml_into_config "${backup_dir}/config.toml" "$config_name"
local old_forwarder="${CONFIG[forwarder]}" old_mapping="${CONFIG[ports_mapping]}" old_tun_remote_addr="${CONFIG[tun_remote_addr]}"
local old_accept_udp="${CONFIG[accept_udp]}" old_ipx_profile="${CONFIG[ipx_profile]}"
clear
colorize cyan "Edit Tunnel: ${config_name}" bold
echo ""
prompt_transport_section "$mode"
local is_tun="false" is_ipx="false"
[[ "${CONFIG[transport_type]}" == "tun" ]] && is_tun="true"
[[ "${CONFIG[tun_encapsulation]}" == "ipx" ]] && is_ipx="true"
prompt_tun_section "${CONFIG[transport_type]}" "$mode" "$is_ipx" "$config_path"
prompt_ipx_section "$is_ipx" "$mode"
if [[ "$is_ipx" != "true" ]]; then
prompt_connection_section "$mode"
fi
prompt_security_section "$is_ipx"
prompt_accept_udp_section "${CONFIG[accept_udp]}"
prompt_mux_section "${CONFIG[transport_type]}"
prompt_tls_section "$mode" "${CONFIG[transport_type]}"
prompt_tuning_section "$is_ipx" "$is_tun"
prompt_logging_section
prompt_ports_section "$mode" "$is_tun"
if [[ "$mode" == "server" ]] && ! validate_port_mapping_csv "${CONFIG[ports_mapping]}" true; then
colorize red "Invalid port mapping."
press_key
return 1
fi
local new_port
if [[ "$mode" == "server" ]]; then
new_port=$(echo "${CONFIG[bind_addr]}" | grep -oP ':\K[0-9]+$')
else
new_port=$(echo "${CONFIG[remote_addr]}" | grep -oP ':\K[0-9]+$')
fi
[[ -z "$new_port" ]] && new_port="${CONFIG[tun_health_port]}"
validate_port_number "$new_port" || { colorize red "Invalid tunnel/control port."; press_key; return 1; }
local prefix new_config_name new_config_path new_service_name
[[ "$mode" == "server" ]] && prefix="iran" || prefix="kharej"
new_config_name="${prefix}${new_port}"
new_config_path="${config_dir}/${new_config_name}.toml"
new_service_name="backhaul-${new_config_name}.service"
generate_toml_config "$mode" "$new_config_path" "$is_tun" "$is_ipx"
save_config_last_used "$mode"
local apply_ok="true"
if [[ "$new_config_name" != "$config_name" ]]; then
colorize yellow "Port changed; removing the old service and creating a new one..."
systemctl disable --now "$service_name" >/dev/null 2>&1
rm -f "$service_path"
systemctl daemon-reload
tm_firewall_close_owner "backhaul:${config_name}"
tm_firewall_close_owner "backhaul:${config_name}:control"
fi
if [[ "$is_tun" == "true" ]]; then
prepare_tun_ipx_kernel "$is_ipx" "${CONFIG[ipx_profile]}" "${CONFIG[tun_name]}"
fi
if [[ "$is_ipx" == "true" ]]; then
allow_ipx_protocol_firewall "${CONFIG[ipx_profile]}"
fi
if [[ -n "$old_forwarder" && "$old_forwarder" != "backhaul" ]]; then
remove_tun_port_forwarding "$old_mapping" "$old_forwarder" "$old_tun_remote_addr" "$config_name"
fi
if [[ "$mode" == "server" ]]; then
tm_firewall_close_owner "backhaul:${new_config_name}:control"
if [[ "$is_ipx" != "true" ]]; then
tm_firewall_open_port "backhaul:${new_config_name}:control" "$new_port" tcp || apply_ok="false"
elif [[ "${CONFIG[ipx_profile]}" == "tcp" || "${CONFIG[ipx_profile]}" == "udp" ]]; then
tm_firewall_open_port "backhaul:${new_config_name}:control" "$new_port" "${CONFIG[ipx_profile]}" || apply_ok="false"
fi
if [[ "$apply_ok" == "true" ]]; then
if [[ "$is_tun" == "true" ]]; then
apply_tun_port_forwarding "${CONFIG[ports_mapping]}" "${CONFIG[forwarder]}" "${CONFIG[tun_remote_addr]}" "${CONFIG[tun_name]}" "$new_config_name" || apply_ok="false"
else
allow_forwarded_ports_firewall "backhaul:${new_config_name}" "${CONFIG[ports_mapping]}" "${CONFIG[accept_udp]}" || apply_ok="false"
fi
fi
fi
local peer_ip_for_meta="${CONFIG[peer_ip]}"
[[ -z "$peer_ip_for_meta" && "$is_ipx" == "true" ]] && peer_ip_for_meta="${CONFIG[ipx_dst_ip]}"
if [[ "$apply_ok" == "true" ]]; then
write_tunnel_meta "$new_config_name" "$peer_ip_for_meta" "${CONFIG[peer_ssh_port]}"
create_systemd_service "$prefix" "$new_port" "$new_config_path" || apply_ok="false"
fi
if [[ "$apply_ok" == "true" ]] && systemctl is-active --quiet "$new_service_name"; then
if [[ "$new_config_name" == "$config_name" ]]; then
tunnel_health_invalidate "$new_config_name" 2>/dev/null || true
else
tunnel_health_delete "$new_config_name" 2>/dev/null || true
fi
if [[ "$is_ipx" == "true" ]]; then
automtu_save_settings "$new_config_name" "${CONFIG[smart_auto_mtu]:-false}" "${CONFIG[smart_mtu_min]:-$AUTOMTU_DEFAULT_MIN}" "${CONFIG[smart_mtu_max]:-$AUTOMTU_DEFAULT_MAX}" "${CONFIG[smart_mtu_step]:-$AUTOMTU_DEFAULT_STEP}"
automtu_reset_learning "$new_config_name"
else
automtu_delete_state "$new_config_name" 2>/dev/null || true
fi
if [[ "$new_config_name" != "$config_name" ]]; then
automtu_delete_state "$config_name" 2>/dev/null || true
tunnel_health_delete "$config_name" 2>/dev/null || true
fi
colorize green "✔ Changes applied successfully; service is healthy."
rm -rf "$backup_dir"
else
colorize red "✘ Service failed to come back up! Rolling back..."
systemctl disable --now "$new_service_name" >/dev/null 2>&1
rm -f "$new_config_path" "${service_dir}/${new_service_name}" "$(tunnel_meta_file "$new_config_name")"
systemctl daemon-reload
restore_tunnel_backup "$backup_dir" "$config_path" "$service_path" "$service_name"
tm_firewall_close_owner "backhaul:${new_config_name}"
tm_firewall_close_owner "backhaul:${new_config_name}:control"
if [[ "$mode" == "server" ]]; then
local old_port="${config_name#iran}"
if [[ "$old_ipx_profile" == "tcp" || "$old_ipx_profile" == "udp" ]]; then
tm_firewall_open_port "backhaul:${config_name}:control" "$old_port" "$old_ipx_profile"
else
tm_firewall_open_port "backhaul:${config_name}:control" "$old_port" tcp
fi
allow_forwarded_ports_firewall "backhaul:${config_name}" "$old_mapping" "$old_accept_udp"
fi
if systemctl is-active --quiet "$service_name"; then
colorize green "✔ Rollback succeeded, tunnel restored to its previous state."
else
colorize red "✘ Rollback also failed! Check logs manually: journalctl -eu ${service_name}"
fi
press_key
return 1
fi
echo ""
run_tunnel_diagnostics "$new_config_path"
}
edit_tunnel() {
local config_path="$1" config_name service_name role mode
config_name=$(basename "${config_path%.toml}")
service_name="backhaul-${config_name}.service"
role=$(tunnel_role "$config_path")
[[ "$role" == "server" ]] && mode="server" || mode="client"
clear
colorize cyan "Edit Tunnel: ${config_name}" bold
echo ""
colorize yellow "1) Full reconfiguration (IP/port/tunnel type/...)"
[[ "$role" == "server" ]] && colorize yellow "2) Manage forwarded ports"
colorize yellow "3) Enable/disable tunnel"
echo "0) Back"
read -r -p "Choice: " choice
case "$choice" in
1) edit_tunnel_full "$config_path" "$mode" ;;
2) [[ "$role" == "server" ]] && edit_tunnel_ports "$config_path" "$mode" ;;
3) toggle_tunnel_enabled "$service_name" ;;
0) return ;;
*) colorize red "Invalid choice"; sleep 1 ;;
esac
}
benchmark_tunnel_protocols() {
local config_path="$1" config_name peer_ip port
config_name=$(basename "${config_path%.toml}")
peer_ip=$(tunnel_peer_ip "$config_path" "$config_name")
if [[ -z "$peer_ip" ]]; then
colorize red "Peer IP is not set — set it from the Edit menu first."
press_key
return 1
fi
local port_source="tunnel"
port=$(tunnel_port_number "$config_path" "$(tunnel_role "$config_path")")
if [[ -z "$port" ]]; then
port=$(tunnel_peer_ssh_port "$config_name")
port_source="SSH"
fi

clear
colorize cyan "Protocol Benchmark — target: ${peer_ip}" bold
colorize yellow "Note: real throughput needs iperf3 running on the peer (iperf3 -s), otherwise it shows N/A. The GRE/IPIP test only checks whether the protocol passes through firewalls on the path (needs hping3) — it is not a live tunnel benchmark, since that needs matching config on both sides at once."
if [[ "$port_source" == "SSH" ]]; then
colorize yellow "No tunnel port on record for this config; the TCP test will probe the SSH port (${port}) instead, which may have its own separate access restrictions."
fi
echo ""

local -A RESULTS
colorize yellow "Testing TCP (port ${port})..."
RESULTS[tcp]=$(benchmark_tcp_probe "$peer_ip" "$port")
colorize yellow "Testing ICMP..."
RESULTS[icmp]=$(benchmark_icmp_probe "$peer_ip")
colorize yellow "Testing GRE (protocol reachability)..."
RESULTS[gre]=$(benchmark_raw_protocol_probe "$peer_ip" 47)
colorize yellow "Testing IPIP (protocol reachability)..."
RESULTS[ipip]=$(benchmark_raw_protocol_probe "$peer_ip" 4)

echo ""
colorize cyan "Test results:" bold
echo ""
local best_key="" best_score=999999999 i=1 key label lat loss thr status score
for key in tcp icmp; do
IFS=' ' read -r lat loss thr <<< "${RESULTS[$key]}"
[[ "$key" == "tcp" ]] && label="TCP Tunnel (port ${port})" || label="ICMP Tunnel"
status=$(status_label "$lat" "$loss")
score=$(score_result "$lat" "$loss")
echo "$i. $label"
if [[ "$lat" == "NA" ]]; then
echo "   Not reachable"
else
echo "   Latency: ${lat}ms"
echo "   Loss: ${loss}%"
if [[ "$thr" != "NA" ]]; then
echo "   Speed: ${thr}Mbps"
else
echo "   Speed: N/A (iperf3 not available on the peer)"
fi
fi
echo "   Status: $status"
echo ""
if (( score < best_score )); then best_score=$score; best_key="$label"; fi
((i++))
done
for key in gre ipip; do
[[ "$key" == "gre" ]] && label="GRE Tunnel (IPX)" || label="IPIP Tunnel (IPX)"
echo "$i. $label"
case "${RESULTS[$key]}" in
OK) echo "   Status: protocol passes through the network path (real throughput/latency needs a live tunnel)" ;;
BLOCKED) echo "   Status: this protocol is blocked/filtered on one of the two sides" ;;
UNSUPPORTED) echo "   Status: hping3 is not installed, cannot test this protocol" ;;
esac
echo ""
((i++))
done

if [[ -n "$best_key" ]]; then
colorize green "Recommendation: ${best_key} is the best choice."
else
colorize yellow "Recommendation: none of the tested protocols were reliably reachable."
fi
write_tunnel_last_test "$config_name" "benchmark:${best_key:-none}"
echo ""
press_key
}
smart_auto_mtu_menu() {
local config_path="$1" config_name state_file current enabled min_mtu max_mtu step choice new_enabled
config_name=$(basename "${config_path%.toml}")
if ! tunnel_is_tun "$config_path" || ! tunnel_is_ipx "$config_path"; then
colorize red "Smart Auto-MTU is available only for Backhaul TUN/IPX tunnels."
press_key
return 1
fi
state_file=$(automtu_state_file "$config_name") || return 1
while true; do
current=$(toml_get "$config_path" tun mtu)
enabled=$(automtu_state_get "$state_file" enabled "false")
min_mtu=$(automtu_state_get "$state_file" min_mtu "$AUTOMTU_DEFAULT_MIN")
max_mtu=$(automtu_state_get "$state_file" max_mtu "$AUTOMTU_DEFAULT_MAX")
step=$(automtu_state_get "$state_file" step "$AUTOMTU_DEFAULT_STEP")
clear
colorize cyan "Smart Auto-MTU: ${config_name}" bold
echo ""
echo "Status:       ${enabled}"
echo "Current MTU:  ${current}"
echo "Allowed:      ${min_mtu}-${max_mtu} (step ${step})"
echo "Last result:  $(automtu_state_get "$state_file" last_result "never-run")"
echo "Last skip:    $(automtu_state_get "$state_file" last_skip "none")"
echo "Last sample:  $(automtu_state_get "$state_file" last_baseline "none")"
echo ""
colorize cyan "1) Run one safe A/B evaluation now"
colorize yellow "2) Enable/disable automatic checks"
echo "3) Change bounds and step"
echo "4) Reset learned history"
echo "0) Back"
echo ""
read -r -p "Choice: " choice
case "$choice" in
1)
automtu_run "$config_path" manual
press_key
;;
2)
[[ "$enabled" == "true" ]] && new_enabled="false" || new_enabled="true"
automtu_save_settings "$config_name" "$new_enabled" "$min_mtu" "$max_mtu" "$step"
colorize green "Smart Auto-MTU set to ${new_enabled}."
sleep 1
;;
3)
while true; do
prompt_with_default "Minimum MTU" "$min_mtu" min_mtu
prompt_with_default "Maximum MTU" "$max_mtu" max_mtu
prompt_with_default "Step" "$step" step
if automtu_validate_settings "$min_mtu" "$max_mtu" "$step" && (( current >= min_mtu && current <= max_mtu )); then
automtu_save_settings "$config_name" "$enabled" "$min_mtu" "$max_mtu" "$step"
automtu_reset_learning "$config_name"
break
fi
colorize red "Invalid range/step, or current MTU is outside the selected range."
done
;;
4)
automtu_reset_learning "$config_name"
colorize green "Learned Auto-MTU history reset; settings were preserved."
sleep 1
;;
0) return ;;
*) colorize red "Invalid choice"; sleep 1 ;;
esac
done
}

tunnel_health_menu() {
local config_path="$1" config_name choice result health_class health_confidence health_reason
config_name=$(basename "${config_path%.toml}")
if ! tunnel_is_tun "$config_path" || ! tunnel_is_ipx "$config_path"; then
colorize red "Tunnel Health classification is available only for Backhaul TUN/IPX tunnels."
press_key
return 1
fi
while true; do
clear
colorize cyan "Tunnel Health: ${config_name}" bold
echo ""
echo "Summary: $(tunnel_health_summary "$config_name")"
echo ""
tunnel_health_show_latest "$config_name" || true
echo ""
colorize cyan "1) Collect a fresh health sample"
echo "2) View recent history"
echo "0) Back"
echo ""
read -r -p "Choice: " choice
case "$choice" in
1)
colorize yellow "Collecting control-path and system telemetry..."
result=$(tunnel_health_run "$config_path" manual)
IFS='|' read -r health_class health_confidence health_reason <<< "$result"
if [[ -n "$health_class" ]]; then
colorize green "Classification: ${health_class} (${health_confidence}%) — ${health_reason}"
else
colorize red "Health collection failed."
fi
press_key
;;
2)
clear
colorize cyan "Recent Tunnel Health history: ${config_name}" bold
echo ""
tunnel_health_show_history "$config_name" 24
echo ""
press_key
;;
0) return ;;
*) colorize red "Invalid choice"; sleep 1 ;;
esac
done
}

tunnel_detail_page() {
local config_path="$1"
local config_name service_name role transport ipx_profile peer_ip last_test last_time ports_count
config_name=$(basename "${config_path%.toml}")
service_name="backhaul-${config_name}.service"
while true; do
[[ -f "$config_path" ]] || return
role=$(tunnel_role "$config_path")
transport=$(toml_get "$config_path" "transport" "type")
ipx_profile=$(toml_get "$config_path" "ipx" "profile")
peer_ip=$(tunnel_peer_ip "$config_path" "$config_name")
clear
colorize cyan "Tunnel: ${config_name}" bold
echo ""
if systemctl is-active --quiet "$service_name"; then
colorize green "Status: Active"
else
colorize red "Status: Inactive"
fi
IFS='|' read -r last_test last_time <<< "$(read_tunnel_last_test "$config_name")"
echo "Last test: ${last_test} (${last_time})"
echo "Tunnel type: ${transport}${ipx_profile:+ / ipx:$ipx_profile}"
if [[ -n "$ipx_profile" ]]; then
echo "Tunnel Health: $(tunnel_health_summary "$config_name")"
echo "Smart Auto-MTU: $(automtu_status_text "$config_name" "$(toml_get "$config_path" tun mtu)")"
fi
echo "Role: $([[ "$role" == "server" ]] && echo "IRAN (Server)" || echo "KHAREJ (Client)")"
if [[ -n "$peer_ip" ]]; then echo "Peer IP: ${peer_ip}"; else echo "Peer IP: not set"; fi
if [[ "$role" == "server" ]]; then
ports_count=$(load_toml_ports_mapping "$config_path" | tr ',' '\n' | grep -c .)
echo "Forwarded ports: ${ports_count:-0}"
fi
local traffic
traffic=$(tunnel_traffic_stats "$service_name")
if [[ -n "$traffic" ]]; then
echo "Traffic: ${traffic}"
else
echo "Traffic: N/A (re-save via Edit to enable tracking on this tunnel)"
fi
echo ""
colorize green "1) Edit tunnel"
colorize cyan "2) Retest (Diagnostics)"
colorize magenta "3) Benchmark protocols"
echo "4) View service logs"
echo "5) View service status"
colorize yellow "6) Restart service"
colorize red "7) Remove this tunnel"
colorize cyan "8) Smart Auto-MTU"
colorize cyan "9) Tunnel Health"
echo "0) Back"
echo ""
read -r -p "Choice: " choice
case "$choice" in
1) edit_tunnel "$config_path" ;;
2) run_tunnel_diagnostics "$config_path" ;;
3) benchmark_tunnel_protocols "$config_path" ;;
4) view_service_logs "$service_name" ;;
5) view_service_status "$service_name" ;;
6) restart_service "$service_name" ;;
7) destroy_tunnel "$config_path"; return ;;
8) smart_auto_mtu_menu "$config_path" ;;
9) tunnel_health_menu "$config_path" ;;
0) return ;;
*) colorize red "Invalid choice"; sleep 1 ;;
esac
done
}
destroy_tunnel() {
config_path="$1"
local silent="${2:-}"
config_name=$(basename "${config_path%.toml}")
service_name="backhaul-${config_name}.service"
service_path="$service_dir/$service_name"
local removed_tun_name removed_profile removed_forwarder removed_mapping removed_tun_remote_addr
removed_tun_name=$(toml_tun_name "$config_path")
removed_profile=$(toml_ipx_profile "$config_path")
removed_forwarder=$(toml_get "$config_path" "ports" "forwarder")
removed_mapping=$(load_toml_ports_mapping "$config_path")
removed_tun_remote_addr=$(toml_get "$config_path" "tun" "remote_addr")
automtu_delete_state "$config_name" 2>/dev/null || true
tunnel_health_delete "$config_name" 2>/dev/null || true
rm -f -- "$(backhaul_watchdog_state_file "$config_name" failures)" "$(backhaul_watchdog_state_file "$config_name" health)"
tm_firewall_close_owner "backhaul:${config_name}"
tm_firewall_close_owner "backhaul:${config_name}:control"
if [[ -n "$removed_forwarder" && "$removed_forwarder" != "backhaul" ]]; then
remove_tun_port_forwarding "$removed_mapping" "$removed_forwarder" "$removed_tun_remote_addr" "$config_name"
fi
[ -f "$config_path" ] && rm -f "$config_path"
if [[ -f "$service_path" ]]; then
systemctl is-active --quiet "$service_name" && systemctl disable --now "$service_name" >/dev/null 2>&1
rm -f "$service_path"
fi
systemctl daemon-reload
if [[ -n "$removed_tun_name" ]] && command -v iptables &> /dev/null; then
iptables -D FORWARD -i "$removed_tun_name" -j ACCEPT 2>/dev/null
iptables -D FORWARD -o "$removed_tun_name" -j ACCEPT 2>/dev/null
iptables -t nat -D POSTROUTING -o "$removed_tun_name" -j MASQUERADE 2>/dev/null
persist_iptables_rules
fi
if [[ -n "$removed_profile" ]] && ! profile_still_in_use "$removed_profile"; then
local proto="" mod=""
case "$removed_profile" in
gre) proto="47"; mod="ip_gre" ;;
ipip) proto="4"; mod="ipip" ;;
icmp) proto="icmp" ;;
esac
if [[ -n "$proto" ]] && command -v iptables &> /dev/null; then
iptables -D INPUT -p "$proto" -j ACCEPT 2>/dev/null
persist_iptables_rules
fi
if [[ "$removed_profile" == "gre" ]] && command -v ufw &> /dev/null; then
ufw delete allow proto gre from any to any comment "backhaul-ipx-gre" >/dev/null 2>&1
fi
if [[ -n "$mod" ]]; then
sed -i "/^${mod}\$/d" "/etc/modules-load.d/backhaul-tunnel.conf" 2>/dev/null
fi
fi
if [[ "$silent" != "--silent" ]]; then
if ! has_any_tun_config; then
colorize yellow "Note: no TUN tunnels remain on this server, but the ip_forward/rp_filter kernel settings applied earlier are system-wide and were left in place. Revert them manually via /etc/sysctl.d/99-backhaul-tunnel.conf if nothing else on this box needs them."
fi
echo
colorize green "Tunnel destroyed successfully!" bold
echo
press_key
else
colorize green "✔ Removed ${config_name}"
fi
}
remove_core() {
# Scoped to backhaul_premium only, the exact inverse of "Update Backhaul
# Core" (download_and_extract_backhaul) above — config_dir is now a shared
# root for every core's configs/certs/binaries (rathole/, gost/, hysteria2/,
# frp/, tuic/ all live under it), so removing the whole directory here would
# silently wipe every other engine's tunnels too, not just Backhaul's.
if find "$config_dir" -maxdepth 1 -type f \( -name "iran*.toml" -o -name "kharej*.toml" \) | grep -q .; then
colorize red "Delete all Backhaul services first."
sleep 3
return 1
fi
colorize yellow "Remove Backhaul-Core (backhaul_premium binary only)? (y/n)"
read -r confirm
if [[ $confirm == [yY] ]]; then
rm -f "${config_dir}/backhaul_premium"
colorize green "Backhaul-Core removed." bold
fi
press_key
}
core_backhaul_destroy_all() {
local config_path
for config_path in "${config_dir}"/{iran,kharej}*.toml; do
[[ -f "$config_path" ]] || continue
destroy_tunnel "$config_path" --silent
done
}
core_backhaul_ensure_ready() {
install_jq
download_and_extract_backhaul "install"
check_config_backup
if [[ "${SCRIPT_MODE:-}" != "--watchdog" ]] && {
compgen -G "${config_dir}/iran*.toml" >/dev/null ||
compgen -G "${config_dir}/kharej*.toml" >/dev/null
}; then
ensure_watchdog_installed
fi
}
core_backhaul_configure() {
[[ ! -d "$config_dir" ]] && {
colorize red "Install Backhaul-Core first."
press_key
return 1
}
clear
echo ""
colorize green "1) Configure IRAN (Server)" bold
colorize magenta "2) Configure KHAREJ (Client)" bold
echo ""
read -r -p "Enter your choice: " configure_choice
case "$configure_choice" in
1) configure_server "server" ;;
2) configure_server "client" ;;
*) colorize red "Invalid option!" && sleep 1 ;;
esac
}
