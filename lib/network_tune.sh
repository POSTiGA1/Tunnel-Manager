#!/usr/bin/env bash
# shellcheck disable=SC2154 # config_dir is provided by tunnel-manager.sh before sourcing.
# Conservative, reversible network tuning for tunnel-manager.
# This file is sourced by tunnel-manager.sh after lib/common.sh.

NETTUNE_SYSCTL_CONF="/etc/sysctl.d/99-tunnel-vm.conf"
NETTUNE_BBR_MODULE_CONF="/etc/modules-load.d/tunnel-vm-bbr.conf"
NETTUNE_SYSTEMD_LIMIT_CONF="/etc/systemd/system.conf.d/99-tunnel-vm-nofile.conf"
NETTUNE_QDISC_UNIT="/etc/systemd/system/tunnel-manager-qdisc.service"
NETTUNE_LIMITS_CONF="/etc/security/limits.conf"
NETTUNE_MEMINFO="/proc/meminfo"
NETTUNE_CONNTRACK_PATH="/proc/sys/net/netfilter/nf_conntrack_max"
NETTUNE_LIMITS_TAG="tunnel-manager-network-tune"
NETTUNE_STATE_DIR="${config_dir}/.network-tune-state"
NETTUNE_VALUES_FILE="${NETTUNE_STATE_DIR}/sysctl-values.tsv"
NETTUNE_LAST_BACKUP_FILE="${config_dir}/.network-tune-last-backup"
NETTUNE_LOCK_FILE="${config_dir}/.network-tune.lock"
NETTUNE_QDISC_VALUES_FILE="${NETTUNE_STATE_DIR}/fq-qdisc-values.tsv"
NETTUNE_LAST_ERROR=""

core_optimize_is_applied() {
[[ -f "$NETTUNE_SYSCTL_CONF" ]]
}

nettune_snapshot_file() {
local path="$1" name="$2"
if [[ -e "$path" ]]; then
printf '1\n' > "${NETTUNE_STATE_DIR}/${name}.exists"
cp -a -- "$path" "${NETTUNE_STATE_DIR}/${name}.backup"
else
printf '0\n' > "${NETTUNE_STATE_DIR}/${name}.exists"
fi
}

nettune_restore_file() {
local path="$1" name="$2" existed
existed=$(cat "${NETTUNE_STATE_DIR}/${name}.exists" 2>/dev/null || printf '0')
if [[ "$existed" == "1" && -e "${NETTUNE_STATE_DIR}/${name}.backup" ]]; then
mkdir -p "$(dirname "$path")"
cp -a -- "${NETTUNE_STATE_DIR}/${name}.backup" "$path"
else
rm -f -- "$path"
fi
}

nettune_file_signature() {
local path="$1" digest
if [[ ! -e "$path" ]]; then
printf '0\n'
return 0
fi
digest=$(sha256_file "$path" 2>/dev/null) || return 1
printf '1\t%s\n' "$digest"
}

# Rollback must not overwrite an administrator's edits made after Optimize.
# The no-signature path keeps compatibility with snapshots from older builds.
nettune_record_applied_file() {
local path="$1" name="$2"
nettune_file_signature "$path" > "${NETTUNE_STATE_DIR}/${name}.applied"
}

nettune_restore_file_if_unchanged() {
local path="$1" name="$2" expected current
if [[ ! -f "${NETTUNE_STATE_DIR}/${name}.applied" ]]; then
nettune_restore_file "$path" "$name"
return $?
fi
expected=$(<"${NETTUNE_STATE_DIR}/${name}.applied")
current=$(nettune_file_signature "$path") || return 1
if [[ "$current" != "$expected" ]]; then
colorize yellow "Skipped changed file during rollback: $path"
return 2
fi
nettune_restore_file "$path" "$name"
}

nettune_keys() {
cat <<'EOF'
net.core.rmem_max
net.core.wmem_max
net.core.rmem_default
net.core.wmem_default
net.ipv4.tcp_rmem
net.ipv4.tcp_wmem
net.core.netdev_max_backlog
net.core.somaxconn
net.ipv4.tcp_max_syn_backlog
net.ipv4.ip_local_port_range
net.ipv4.ip_local_reserved_ports
net.ipv4.tcp_fin_timeout
net.ipv4.tcp_slow_start_after_idle
net.ipv4.tcp_mtu_probing
net.ipv4.tcp_keepalive_time
net.ipv4.tcp_keepalive_intvl
net.ipv4.tcp_keepalive_probes
net.netfilter.nf_conntrack_max
net.core.default_qdisc
net.ipv4.tcp_congestion_control
EOF
}

nettune_fq_rows() {
local interface="$1"
tc qdisc show dev "$interface" 2>/dev/null | awk '
$1 == "qdisc" && $2 == "fq" {
scope=""
limit=flow_limit=buckets=quantum=initial_quantum=""
for (i=3; i<=NF; i++) {
if ($i == "root") scope="root"
else if ($i == "parent") scope=$(i+1)
else if ($i == "limit") limit=$(i+1)
else if ($i == "flow_limit") flow_limit=$(i+1)
else if ($i == "buckets") buckets=$(i+1)
else if ($i == "quantum") quantum=$(i+1)
else if ($i == "initial_quantum") initial_quantum=$(i+1)
}
gsub(/[^0-9]/, "", limit); gsub(/[^0-9]/, "", flow_limit)
gsub(/[^0-9]/, "", buckets); gsub(/[^0-9]/, "", quantum)
gsub(/[^0-9]/, "", initial_quantum)
if (scope != "" && limit != "" && flow_limit != "" && buckets != "" && quantum != "" && initial_quantum != "")
printf "%s\t%s\t%s\t%s\t%s\t%s\n", scope, limit, flow_limit, buckets, quantum, initial_quantum
}
'
}

nettune_capture_fq_baseline() {
local interface
mkdir -p "$NETTUNE_STATE_DIR" || return 1
: > "$NETTUNE_QDISC_VALUES_FILE"
command -v tc >/dev/null 2>&1 || return 0
interface=$(detect_default_interface)
[[ -n "$interface" ]] || return 0
while IFS=$'\t' read -r scope limit flow_limit buckets quantum initial_quantum; do
[[ -n "$scope" ]] || continue
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$interface" "$scope" "$limit" "$flow_limit" "$buckets" "$quantum" "$initial_quantum" >> "$NETTUNE_QDISC_VALUES_FILE"
done < <(nettune_fq_rows "$interface")
}

nettune_change_fq() {
local interface="$1" scope="$2" limit="$3" flow_limit="$4" buckets="$5" quantum="$6" initial_quantum="$7"
local -a location=(root)
[[ "$scope" != "root" ]] && location=(parent "$scope")
tc qdisc change dev "$interface" "${location[@]}" fq limit "$limit" flow_limit "$flow_limit" \
buckets "$buckets" quantum "$quantum" initial_quantum "$initial_quantum"
}

nettune_apply_fq_profile() {
[[ -s "$NETTUNE_QDISC_VALUES_FILE" ]] || return 0
command -v tc >/dev/null 2>&1 || return 0
local interface scope old_limit old_flow old_buckets old_quantum old_initial
local target_limit target_flow target_buckets mtu quantum initial_quantum
while IFS=$'\t' read -r interface scope old_limit old_flow old_buckets old_quantum old_initial; do
[[ -n "$interface" && -n "$scope" ]] || continue
: "$old_limit" "$old_flow" "$old_buckets" "$old_quantum" "$old_initial"
mtu=$(cat "/sys/class/net/${interface}/mtu" 2>/dev/null || printf '1500')
[[ "$mtu" =~ ^[0-9]+$ ]] || mtu=1500
quantum=$(( (mtu + 14) * 2 ))
initial_quantum=$(( (mtu + 14) * 10 ))
if [[ "$scope" == "root" ]]; then
target_limit=262144; target_flow=65536; target_buckets=16384
else
target_limit=32768; target_flow=2048; target_buckets=8192
fi
nettune_change_fq "$interface" "$scope" "$target_limit" "$target_flow" "$target_buckets" "$quantum" "$initial_quantum" || return 1
done < "$NETTUNE_QDISC_VALUES_FILE"
}

nettune_restore_fq_profile() {
[[ -s "$NETTUNE_QDISC_VALUES_FILE" ]] || return 0
command -v tc >/dev/null 2>&1 || return 1
local interface scope limit flow_limit buckets quantum initial_quantum failed=0
while IFS=$'\t' read -r interface scope limit flow_limit buckets quantum initial_quantum; do
[[ -n "$interface" && -n "$scope" ]] || continue
nettune_change_fq "$interface" "$scope" "$limit" "$flow_limit" "$buckets" "$quantum" "$initial_quantum" || failed=1
done < "$NETTUNE_QDISC_VALUES_FILE"
(( failed == 0 ))
}

nettune_install_qdisc_unit() {
if [[ ! -s "$NETTUNE_QDISC_VALUES_FILE" ]]; then
rm -f -- "$NETTUNE_QDISC_UNIT"
return 0
fi
mkdir -p "$(dirname "$NETTUNE_QDISC_UNIT")"
cat > "$NETTUNE_QDISC_UNIT" <<EOF
[Unit]
Description=Tunnel Manager 1 Gbps fq queue profile
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${PANEL_PATH:-/usr/local/bin/backhaul} --qdisc-tune
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "$NETTUNE_QDISC_UNIT"
systemctl daemon-reload >/dev/null 2>&1 || return 1
systemctl enable tunnel-manager-qdisc.service >/dev/null 2>&1 || return 1
}

# Capture the baseline only once. Re-applying optimization must never replace
# the values needed for a real rollback with already-tuned values.
nettune_capture_baseline() {
if [[ -f "$NETTUNE_VALUES_FILE" ]]; then
if [[ ! -f "$NETTUNE_QDISC_VALUES_FILE" ]]; then
nettune_capture_fq_baseline || return 1
fi
if [[ ! -f "${NETTUNE_STATE_DIR}/qdisc-unit.exists" ]]; then
nettune_snapshot_file "$NETTUNE_QDISC_UNIT" qdisc-unit || return 1
fi
return 0
fi

mkdir -p "$NETTUNE_STATE_DIR"
chmod 700 "$NETTUNE_STATE_DIR"
nettune_snapshot_file "$NETTUNE_SYSCTL_CONF" sysctl-conf || return 1
nettune_snapshot_file "$NETTUNE_BBR_MODULE_CONF" bbr-module || return 1
nettune_snapshot_file "$NETTUNE_SYSTEMD_LIMIT_CONF" systemd-limit || return 1
nettune_snapshot_file "$NETTUNE_QDISC_UNIT" qdisc-unit || return 1
nettune_snapshot_file "$NETTUNE_LIMITS_CONF" limits-conf || return 1
nettune_capture_fq_baseline || return 1

: > "$NETTUNE_VALUES_FILE"
local key value
while IFS= read -r key; do
[[ -n "$key" ]] || continue
if value=$(sysctl -n "$key" 2>/dev/null); then
printf '%s\t%s\n' "$key" "$value" >> "$NETTUNE_VALUES_FILE"
fi
done < <(nettune_keys)
chmod 600 "$NETTUNE_VALUES_FILE"
printf '%s\n' "$NETTUNE_STATE_DIR" > "$NETTUNE_LAST_BACKUP_FILE"
}

nettune_max_value() {
local key="$1" proposed="$2" current
current=$(sysctl -n "$key" 2>/dev/null || printf '0')
if [[ "$current" =~ ^[0-9]+$ ]] && (( current > proposed )); then
printf '%s' "$current"
else
printf '%s' "$proposed"
fi
}

nettune_baseline_value() {
local key="$1"
awk -F '\t' -v wanted="$key" '
$1 == wanted { found=1; print substr($0, index($0, "\t") + 1); exit }
END { if (!found) exit 1 }
' "$NETTUNE_VALUES_FILE" 2>/dev/null
}

nettune_merge_reserved_ports() {
local current listening
# Always rebuild from the pre-Optimize baseline. Using the current runtime
# value would make ports from deleted tunnels accumulate on every re-apply.
if ! current=$(nettune_baseline_value net.ipv4.ip_local_reserved_ports); then
current=$(sysctl -n net.ipv4.ip_local_reserved_ports 2>/dev/null || true)
fi
listening=$(nettune_managed_listener_ports | paste -sd, -)

printf '%s\n%s\n' "$current" "$listening" |
tr ',' '\n' | awk 'NF && $0 ~ /^[0-9]+(-[0-9]+)?$/ { if (!seen[$0]++) print $0 }' |
sort -V | paste -sd, -
}

# Only reserve sockets owned by this panel's tunnel services. Reserving every
# listener on a busy proxy can consume most of the ephemeral range and makes
# verification unstable while unrelated applications open and close sockets.
nettune_managed_listener_ports() {
local unit pid pids="" pid_pattern
command -v systemctl >/dev/null && command -v ss >/dev/null || return 0
while IFS= read -r unit; do
[[ "$unit" =~ ^(backhaul|gost|rathole|frp|hysteria|hysteria2|tuic)- ]] || continue
pid=$(systemctl show "$unit" -p MainPID --value 2>/dev/null || true)
[[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 0 )) && pids+="${pid}"$'\n'
done < <(systemctl list-units --type=service --all --no-legend --no-pager 2>/dev/null | awk '{print $1}')
pids=$(printf '%s' "$pids" | sort -un | paste -sd'|' -)
[[ -n "$pids" ]] || return 0
pid_pattern="pid=(${pids}),"
{ ss -Htlnp 2>/dev/null; ss -Hulnp 2>/dev/null; } |
awk -v pid_pattern="$pid_pattern" '
$0 ~ pid_pattern && match($4, /:[0-9]+$/) { print substr($4, RSTART + 1) }
' | sort -un
}

nettune_normalize_ports() {
tr ',' '\n' | awk -F- '
/^[0-9]+$/ { if ($1 >= 1 && $1 <= 65535) ports[$1]=1; next }
/^[0-9]+-[0-9]+$/ {
if ($1 < 1 || $2 > 65535 || $1 > $2) next
for (port=$1; port<=$2; port++) ports[port]=1
}
END {
separator=""
for (port=1; port<=65535; port++) if (ports[port]) {
printf "%s%d", separator, port
separator=","
}
print ""
}
'
}

nettune_values_match() {
local key="$1" expected="$2" actual="$3"
if [[ "$key" == "net.ipv4.ip_local_reserved_ports" ]]; then
expected=$(nettune_normalize_ports <<< "$expected")
actual=$(nettune_normalize_ports <<< "$actual")
fi
[[ "$actual" == "$expected" ]]
}

nettune_verify_config() {
local conf="$1" line key expected actual
NETTUNE_LAST_ERROR=""
while IFS= read -r line; do
[[ "$line" == *=* && "$line" != \#* ]] || continue
key="${line%%=*}"
expected="${line#*=}"
key="${key//[[:space:]]/}"
expected=$(awk '{$1=$1; print}' <<< "$expected")
if ! actual=$(sysctl -n "$key" 2>/dev/null); then
NETTUNE_LAST_ERROR="sysctl-unavailable:${key}"
return 1
fi
actual=$(awk '{$1=$1; print}' <<< "$actual")
if ! nettune_values_match "$key" "$expected" "$actual"; then
NETTUNE_LAST_ERROR="sysctl-mismatch:${key}"
return 1
fi
done < "$conf"
}

nettune_remove_legacy_global_limits() {
# Older releases changed limits for every login and every systemd service.
# Panel units already carry their own LimitNOFILE, so these global mutations
# are unnecessary and are removed while their exact old files remain saved.
if grep -q "^# ${NETTUNE_LIMITS_TAG}$" "$NETTUNE_LIMITS_CONF" 2>/dev/null; then
sed -i "/^# ${NETTUNE_LIMITS_TAG}$/,+4d" "$NETTUNE_LIMITS_CONF"
fi
if [[ -f "$NETTUNE_SYSTEMD_LIMIT_CONF" ]]; then
rm -f -- "$NETTUNE_SYSTEMD_LIMIT_CONF"
systemctl daemon-reexec 2>/dev/null || true
fi
}

core_optimize_apply() {
colorize cyan "--- Optimize Network (safe and reversible) ---" bold
echo ""
NETTUNE_LAST_ERROR=""

local bbr_ok=0 conntrack_ok=0
if ! nettune_capture_baseline; then
colorize red "Could not save the pre-optimization state. Nothing was changed."
return 1
fi
# Loading BBR is itself a runtime change, so it must happen after the baseline
# is safely stored.
if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
modprobe tcp_bbr 2>/dev/null || true
fi
if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
bbr_ok=1
fi
[[ -e "$NETTUNE_CONNTRACK_PATH" ]] && conntrack_ok=1
nettune_remove_legacy_global_limits

local memory_kb buffer_max tcp_buffer conntrack_max backlog
memory_kb=$(awk '/^MemTotal:/ {print $2; exit}' "$NETTUNE_MEMINFO" 2>/dev/null)
memory_kb=${memory_kb:-2097152}
if (( memory_kb < 2097152 )); then
buffer_max=33554432; tcp_buffer=16777216; conntrack_max=131072; backlog=16384
elif (( memory_kb < 8388608 )); then
buffer_max=67108864; tcp_buffer=33554432; conntrack_max=262144; backlog=32768
else
buffer_max=134217728; tcp_buffer=67108864; conntrack_max=524288; backlog=65536
fi

# Do not reduce a deliberately higher value already chosen by the admin.
buffer_max=$(nettune_max_value net.core.rmem_max "$buffer_max")
local wmem_max rmem_default wmem_default somaxconn syn_backlog
wmem_max=$(nettune_max_value net.core.wmem_max "$buffer_max")
rmem_default=$(nettune_max_value net.core.rmem_default 1048576)
wmem_default=$(nettune_max_value net.core.wmem_default 1048576)
backlog=$(nettune_max_value net.core.netdev_max_backlog "$backlog")
somaxconn=$(nettune_max_value net.core.somaxconn 65535)
syn_backlog=$(nettune_max_value net.ipv4.tcp_max_syn_backlog 8192)
if [[ "$conntrack_ok" == "1" ]]; then
conntrack_max=$(nettune_max_value net.netfilter.nf_conntrack_max "$conntrack_max")
fi

local current_tcp current_tcp_min current_tcp_default current_tcp_max
local tcp_rmem_min=4096 tcp_rmem_default=87380 tcp_rmem_max="$tcp_buffer"
local tcp_wmem_min=4096 tcp_wmem_default=65536 tcp_wmem_max="$tcp_buffer"
current_tcp=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || true)
read -r current_tcp_min current_tcp_default current_tcp_max <<< "$current_tcp"
[[ "$current_tcp_min" =~ ^[0-9]+$ ]] && (( current_tcp_min > tcp_rmem_min )) && tcp_rmem_min="$current_tcp_min"
[[ "$current_tcp_default" =~ ^[0-9]+$ ]] && (( current_tcp_default > tcp_rmem_default )) && tcp_rmem_default="$current_tcp_default"
[[ "$current_tcp_max" =~ ^[0-9]+$ ]] && (( current_tcp_max > tcp_rmem_max )) && tcp_rmem_max="$current_tcp_max"
current_tcp=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || true)
read -r current_tcp_min current_tcp_default current_tcp_max <<< "$current_tcp"
[[ "$current_tcp_min" =~ ^[0-9]+$ ]] && (( current_tcp_min > tcp_wmem_min )) && tcp_wmem_min="$current_tcp_min"
[[ "$current_tcp_default" =~ ^[0-9]+$ ]] && (( current_tcp_default > tcp_wmem_default )) && tcp_wmem_default="$current_tcp_default"
[[ "$current_tcp_max" =~ ^[0-9]+$ ]] && (( current_tcp_max > tcp_wmem_max )) && tcp_wmem_max="$current_tcp_max"

local current_range range_low=10000 range_high=65535 current_low current_high
current_range=$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || true)
read -r current_low current_high <<< "$current_range"
[[ "$current_low" =~ ^[0-9]+$ ]] && (( current_low >= 1024 && current_low < range_low )) && range_low="$current_low"
[[ "$current_high" =~ ^[0-9]+$ ]] && (( current_high > range_high && current_high <= 65535 )) && range_high="$current_high"

local reserved_ports temp_conf
reserved_ports=$(nettune_merge_reserved_ports)
mkdir -p "$(dirname "$NETTUNE_SYSCTL_CONF")"
if ! temp_conf=$(mktemp "${NETTUNE_SYSCTL_CONF}.XXXXXX"); then
colorize red "Could not create the temporary tuning file; restoring the saved state."
core_optimize_rollback
return 1
fi
cat > "$temp_conf" <<EOF
# Managed by tunnel-manager. Remove through Optimize > Rollback.
# Values are sized from installed RAM and never reduce larger admin settings.
net.core.rmem_max = ${buffer_max}
net.core.wmem_max = ${wmem_max}
net.core.rmem_default = ${rmem_default}
net.core.wmem_default = ${wmem_default}
net.ipv4.tcp_rmem = ${tcp_rmem_min} ${tcp_rmem_default} ${tcp_rmem_max}
net.ipv4.tcp_wmem = ${tcp_wmem_min} ${tcp_wmem_default} ${tcp_wmem_max}
net.core.netdev_max_backlog = ${backlog}
net.core.somaxconn = ${somaxconn}
net.ipv4.tcp_max_syn_backlog = ${syn_backlog}
net.ipv4.ip_local_port_range = ${range_low} ${range_high}
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
EOF
[[ -n "$reserved_ports" ]] && printf 'net.ipv4.ip_local_reserved_ports = %s\n' "$reserved_ports" >> "$temp_conf"
[[ "$conntrack_ok" == "1" ]] && printf 'net.netfilter.nf_conntrack_max = %s\n' "$conntrack_max" >> "$temp_conf"
if [[ "$bbr_ok" == "1" ]]; then
printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' >> "$temp_conf"
mkdir -p "$(dirname "$NETTUNE_BBR_MODULE_CONF")"
printf 'tcp_bbr\n' > "$NETTUNE_BBR_MODULE_CONF"
else
rm -f -- "$NETTUNE_BBR_MODULE_CONF"
fi
chmod 644 "$temp_conf"
if ! mv -f -- "$temp_conf" "$NETTUNE_SYSCTL_CONF"; then
rm -f -- "$temp_conf"
colorize red "Could not activate the tuning file; restoring the saved state."
core_optimize_rollback
return 1
fi
if ! nettune_install_qdisc_unit || ! nettune_apply_fq_profile; then
NETTUNE_LAST_ERROR="fq-qdisc-apply-failed"
colorize red "Could not apply the 1 Gbps fq queue profile; restoring the saved state."
core_optimize_rollback
return 1
fi
# Fingerprint the files as written. Rollback uses these signatures to avoid
# clobbering later administrator changes.
if ! nettune_record_applied_file "$NETTUNE_SYSCTL_CONF" sysctl-conf ||
! nettune_record_applied_file "$NETTUNE_BBR_MODULE_CONF" bbr-module ||
! nettune_record_applied_file "$NETTUNE_SYSTEMD_LIMIT_CONF" systemd-limit ||
! nettune_record_applied_file "$NETTUNE_QDISC_UNIT" qdisc-unit; then
colorize red "Could not record the applied file state; restoring the saved state."
core_optimize_rollback
return 1
fi

if ! sysctl -e -p "$NETTUNE_SYSCTL_CONF" >/dev/null; then
NETTUNE_LAST_ERROR="sysctl-apply-failed"
colorize red "Kernel rejected one or more tuning values; restoring the saved state."
core_optimize_rollback
return 1
fi
if ! nettune_verify_config "$NETTUNE_SYSCTL_CONF"; then
colorize red "Kernel rejected one or more tuning values; restoring the saved state."
[[ -n "$NETTUNE_LAST_ERROR" ]] && colorize yellow "Verification detail: ${NETTUNE_LAST_ERROR}"
core_optimize_rollback
return 1
fi
colorize green "Network tuning applied. Original values are saved in: $NETTUNE_STATE_DIR"
echo "RAM profile:          $((memory_kb / 1024)) MB"
echo "Congestion control:  $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo n/a)"
echo "Default qdisc:       $(sysctl -n net.core.default_qdisc 2>/dev/null || echo n/a)"
[[ -s "$NETTUNE_QDISC_VALUES_FILE" ]] && echo "Active fq profile:   1 Gbps (persisted across boot)"
echo "Socket buffers:      rmem=${buffer_max}, wmem=${wmem_max}"
echo "somaxconn:           $(sysctl -n net.core.somaxconn 2>/dev/null || echo n/a)"
[[ "$conntrack_ok" == "1" ]] && echo "conntrack max:       $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo n/a)"
[[ -n "$reserved_ports" ]] && echo "Reserved ports:      $reserved_ports"
echo ""
colorize yellow "Tunnel listeners sync automatically; re-run Optimize after adding external listeners."
colorize yellow "Custom/non-fq qdiscs, global PAM limits, and global systemd limits are left untouched."
}

# Tunnel setup calls this before and after restarting a service: the first pass
# makes new sockets inherit BBR, while the second captures the new listener in
# ip_local_reserved_ports. Optimization remains secondary to tunnel health.
core_optimize_sync_for_tunnel() {
local phase="${1:-after}" subject="${2:-tunnel}" lock_fd result
mkdir -p "$config_dir" || return 1
if command -v flock >/dev/null; then
exec {lock_fd}>"$NETTUNE_LOCK_FILE"
if ! flock -w 15 "$lock_fd"; then
exec {lock_fd}>&-
return 1
fi
fi
if core_optimize_apply >/dev/null 2>&1; then result=0; else result=$?; fi
if [[ -n "${lock_fd:-}" ]]; then
flock -u "$lock_fd" 2>/dev/null || true
exec {lock_fd}>&-
fi
if (( result == 0 )); then
logger -t tunnel-manager "network optimization synced (${phase}): ${subject}" 2>/dev/null || true
return 0
fi
logger -t tunnel-manager "network optimization sync failed (${phase}): ${subject}; ${NETTUNE_LAST_ERROR:-unknown-error}" 2>/dev/null || true
[[ "$phase" == "after" ]] && colorize yellow "Tunnel is active, but automatic network optimization failed; use option 11 to inspect or retry."
return 1
}

core_optimize_rollback() {
if [[ ! -f "$NETTUNE_VALUES_FILE" ]]; then
# Compatibility cleanup for installations optimized by an older release.
if core_optimize_is_applied || [[ -f "$NETTUNE_BBR_MODULE_CONF" || -f "$NETTUNE_SYSTEMD_LIMIT_CONF" || -f "$NETTUNE_QDISC_UNIT" ]]; then
systemctl disable --now tunnel-manager-qdisc.service >/dev/null 2>&1 || true
rm -f -- "$NETTUNE_SYSCTL_CONF" "$NETTUNE_BBR_MODULE_CONF" "$NETTUNE_SYSTEMD_LIMIT_CONF" "$NETTUNE_QDISC_UNIT"
sed -i "/^# ${NETTUNE_LIMITS_TAG}$/,+4d" "$NETTUNE_LIMITS_CONF" 2>/dev/null || true
sysctl --system >/dev/null 2>&1 || true
systemctl daemon-reexec 2>/dev/null || true
colorize yellow "Legacy optimization files were removed. An exact old runtime snapshot was not available."
else
colorize yellow "Nothing to roll back -- optimization was never applied."
fi
return 0
fi

local restore_failed=0 restore_status restore_spec
systemctl disable --now tunnel-manager-qdisc.service >/dev/null 2>&1 || true
for restore_spec in \
"$NETTUNE_SYSCTL_CONF|sysctl-conf" \
"$NETTUNE_BBR_MODULE_CONF|bbr-module" \
"$NETTUNE_SYSTEMD_LIMIT_CONF|systemd-limit" \
"$NETTUNE_QDISC_UNIT|qdisc-unit"; do
if nettune_restore_file_if_unchanged "${restore_spec%%|*}" "${restore_spec#*|}"; then
restore_status=0
else
restore_status=$?
fi
(( restore_status == 0 )) || restore_failed=1
done
if ! nettune_restore_fq_profile; then
restore_failed=1
colorize yellow "Could not restore one or more fq queue values."
fi
# limits.conf is a shared administrator-owned file. Older releases may have
# placed one tagged block there, but rollback never replaces the whole file.
sysctl --system >/dev/null 2>&1 || true

local key value
while IFS=$'\t' read -r key value; do
[[ -n "$key" ]] || continue
if ! sysctl -w "${key}=${value}" >/dev/null 2>&1; then
restore_failed=1
colorize yellow "Could not restore runtime value: $key"
fi
done < "$NETTUNE_VALUES_FILE"
systemctl daemon-reexec 2>/dev/null || true

local archive_dir
archive_dir="${config_dir}/.backups/network-tune.rollback.$(date +%Y%m%d%H%M%S)"
mkdir -p "$(dirname "$archive_dir")"
if [[ "$restore_failed" == "0" ]]; then
mv -- "$NETTUNE_STATE_DIR" "$archive_dir"
printf '%s\n' "$archive_dir" > "$NETTUNE_LAST_BACKUP_FILE"
colorize green "Optimization rolled back to the exact saved values. Snapshot archived at: $archive_dir"
else
colorize yellow "Rollback was partial. State was kept at $NETTUNE_STATE_DIR so it can be retried."
return 1
fi
}
