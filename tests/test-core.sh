#!/usr/bin/env bash
# shellcheck disable=SC2034 # Several globals are consumed by sourced modules.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

config_dir="${TEST_ROOT}/config"
service_dir="${TEST_ROOT}/systemd"
CERT_FILE="${TEST_ROOT}/cert.pem"
KEY_FILE="${TEST_ROOT}/key.pem"
mkdir -p "$config_dir" "$service_dir"

# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=../lib/tunnel_health.sh
source "${ROOT_DIR}/lib/tunnel_health.sh"
# shellcheck source=../lib/auto_mtu.sh
source "${ROOT_DIR}/lib/auto_mtu.sh"
# shellcheck source=../core/backhaul/core.sh
source "${ROOT_DIR}/core/backhaul/core.sh"
# shellcheck source=../core/hysteria2/core.sh
source "${ROOT_DIR}/core/hysteria2/core.sh"
# shellcheck source=../core/tuic/core.sh
source "${ROOT_DIR}/core/tuic/core.sh"
# shellcheck source=../lib/network_tune.sh
source "${ROOT_DIR}/lib/network_tune.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$2], got [$1]"; }
assert_file_contains() { grep -qF "$2" "$1" || fail "$1 does not contain: $2"; }

test_safe_assignment() {
local output="" injected="clean" payload='"; injected=pwned; #'
prompt_with_default "value" "default" output <<< "$payload" >/dev/null
assert_eq "$output" "$payload"
assert_eq "$injected" "clean"

declare -A CONFIG=()
prompt_with_default "token" "default" 'CONFIG[token]' <<< 'safe-token' >/dev/null
assert_eq "${CONFIG[token]}" "safe-token"
}

test_validation_and_quoting() {
validate_port_mapping_csv '443,8080=9090' false || fail "valid mapping rejected"
validate_port_mapping_csv '1000-1010=2000-2010' true || fail "valid range rejected"
! validate_port_mapping_csv '0,70000' false || fail "invalid ports accepted"
! validate_port_mapping_csv '443=$(id)' false || fail "injection-like mapping accepted"
validate_host_port 'example.com:443' || fail "valid host:port rejected"
validate_host_port '[2001:db8::1]:443' || fail "valid IPv6 host:port rejected"
! validate_host_port 'example.com:70000' || fail "invalid host port accepted"
validate_safe_secret 'Password-123' || fail "safe password rejected"
! validate_safe_secret 'bad password' || fail "unsafe password accepted"

local quoted
quoted=$(yaml_quote "it's-safe")
assert_eq "$quoted" "'it''s-safe'"
assert_eq "$(yaml_unquote "$quoted")" "it's-safe"
assert_eq "$(toml_quote 'bad"; injected=true; #')" '"bad\"; injected=true; #"'
}

test_route_source_ip_selection() {
ip() {
if [[ " $* " == *" route get "* ]]; then
printf '1.1.1.1 via 192.0.2.1 dev eth0 src 192.0.2.10 uid 0\n'
elif [[ " $* " == *" addr show dev eth0 "* ]]; then
printf '2: eth0    inet 192.0.2.10/24 scope global eth0\n'
fi
}
assert_eq "$(detect_route_source_ipv4 eth0)" '192.0.2.10'
ipv4_is_local_on_interface 192.0.2.10 eth0 || fail "route-source IPv4 was not recognized as local"
! ipv4_is_local_on_interface 198.51.100.9 eth0 || fail "non-local IPv4 was accepted for IPX listen"
unset -f ip
}

test_verified_reverse_configs() {
local hys="${TEST_ROOT}/hysteria-client.yaml" tuic="${TEST_ROOT}/tuic-client.toml"
local pin='AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99'
core_hysteria2_generate_client_config "$hys" '1.2.3.4:443' 'Password123' 'ObfsPass123' 'backhaul.com' '8080=80' "$pin"
assert_eq "$(core_hysteria2_role "$hys")" "client"
assert_file_contains "$hys" "pinSHA256: '$pin'"
assert_file_contains "$hys" 'listen: 0.0.0.0:8080'

core_tuic_generate_client_config "$tuic" '1.2.3.4:443' '12345678-1234-1234-1234-123456789012' 'Password123' 'backhaul.com' '8080=80' "${TEST_ROOT}/kharej-cert.pem"
assert_eq "$(core_tuic_role "$tuic")" "client"
assert_file_contains "$tuic" 'skip_cert_verify = false'
assert_file_contains "$tuic" "certificates = [\"${TEST_ROOT}/kharej-cert.pem\"]"
assert_file_contains "$tuic" 'listen = "0.0.0.0:8080"'
! grep -qF 'skip_cert_verify = true' "$tuic" || fail "TUIC verification was disabled"
}

declare -A SYSVALS=(
['net.core.rmem_max']='212992'
['net.core.wmem_max']='212992'
['net.core.rmem_default']='212992'
['net.core.wmem_default']='212992'
['net.ipv4.tcp_rmem']='4096 131072 6291456'
['net.ipv4.tcp_wmem']='4096 16384 4194304'
['net.core.netdev_max_backlog']='1000'
['net.core.somaxconn']='4096'
['net.ipv4.tcp_max_syn_backlog']='4096'
['net.ipv4.ip_local_port_range']='32768 60999'
['net.ipv4.ip_local_reserved_ports']='9000'
['net.ipv4.tcp_fin_timeout']='60'
['net.ipv4.tcp_slow_start_after_idle']='1'
['net.ipv4.tcp_mtu_probing']='0'
['net.ipv4.tcp_keepalive_time']='7200'
['net.ipv4.tcp_keepalive_intvl']='75'
['net.ipv4.tcp_keepalive_probes']='9'
['net.netfilter.nf_conntrack_max']='65536'
['net.core.default_qdisc']='pfifo_fast'
['net.ipv4.tcp_congestion_control']='cubic'
['net.ipv4.tcp_available_congestion_control']='reno cubic bbr'
)
SERVICE_ENABLED="false"
SERVICE_ACTIVE="false"
RESTART_COUNT=0
OPTIMIZE_SYNC_COUNT=0

sysctl() {
local action="${1:-}"
case "$action" in
-n)
[[ ${SYSVALS[$2]+present} ]] || return 1
printf '%s\n' "${SYSVALS[$2]}"
;;
-w)
local pair="$2" key value
key="${pair%%=*}"; value="${pair#*=}"
SYSVALS["$key"]="$value"
printf '%s = %s\n' "$key" "$value"
;;
-e)
[[ "${2:-}" == "-p" ]] || return 1
local line key value
while IFS= read -r line; do
[[ "$line" == *=* && "$line" != \#* ]] || continue
key="${line%%=*}"; value="${line#*=}"
key="${key//[[:space:]]/}"
value="${value#${value%%[![:space:]]*}}"; value="${value%${value##*[![:space:]]}}"
SYSVALS["$key"]="$value"
done < "$3"
;;
--system) return 0 ;;
*) return 1 ;;
esac
}
systemctl() {
case "${1:-}" in
is-enabled) [[ "$SERVICE_ENABLED" == "true" ]] ;;
is-active) [[ "$SERVICE_ACTIVE" == "true" ]] ;;
restart) RESTART_COUNT=$((RESTART_COUNT + 1)); SERVICE_ACTIVE="true" ;;
list-units) printf 'backhaul-test.service loaded active running test\n' ;;
show)
if [[ " $* " == *" MainPID "* ]]; then printf '4242\n'; else return 0; fi
;;
*) return 0 ;;
esac
}
logger() { :; }
modprobe() { :; }
detect_default_interface() { printf 'eth0\n'; }
TC_LIMIT=10000
TC_FLOW_LIMIT=100
TC_BUCKETS=1024
TC_QUANTUM=3028
TC_INITIAL_QUANTUM=15140
TC_SCOPE_MODE=root
tc() {
if [[ " $* " == *" qdisc show dev eth0 "* ]]; then
if [[ "$TC_SCOPE_MODE" == "multi" ]]; then
printf 'qdisc mq 0: root\n'
printf 'qdisc fq 0: parent :1 limit %sp flow_limit %sp buckets %s quantum %sb initial_quantum %sb\n' \
"$TC_LIMIT" "$TC_FLOW_LIMIT" "$TC_BUCKETS" "$TC_QUANTUM" "$TC_INITIAL_QUANTUM"
printf 'qdisc fq 0: parent :2 limit %sp flow_limit %sp buckets %s quantum %sb initial_quantum %sb\n' \
"$TC_LIMIT" "$TC_FLOW_LIMIT" "$TC_BUCKETS" "$TC_QUANTUM" "$TC_INITIAL_QUANTUM"
else
printf 'qdisc fq 0: root refcnt 2 limit %sp flow_limit %sp buckets %s quantum %sb initial_quantum %sb\n' \
"$TC_LIMIT" "$TC_FLOW_LIMIT" "$TC_BUCKETS" "$TC_QUANTUM" "$TC_INITIAL_QUANTUM"
fi
return 0
fi
if [[ " $* " == *" qdisc change dev eth0 "* ]]; then
local -a args=("$@")
local i
for ((i=0; i<${#args[@]}; i++)); do
case "${args[$i]}" in
limit) TC_LIMIT="${args[$((i+1))]}" ;;
flow_limit) TC_FLOW_LIMIT="${args[$((i+1))]}" ;;
buckets) TC_BUCKETS="${args[$((i+1))]}" ;;
quantum) TC_QUANTUM="${args[$((i+1))]}" ;;
initial_quantum) TC_INITIAL_QUANTUM="${args[$((i+1))]}" ;;
esac
done
return 0
fi
return 1
}
LISTEN_PORT=8443
ss() {
printf 'LISTEN 0 128 0.0.0.0:%s 0.0.0.0:* users:(("backhaul",pid=4242,fd=3))\n' "$LISTEN_PORT"
printf 'LISTEN 0 128 0.0.0.0:7443 0.0.0.0:* users:(("external",pid=9999,fd=4))\n'
}
core_optimize_sync_for_tunnel() { OPTIMIZE_SYNC_COUNT=$((OPTIMIZE_SYNC_COUNT + 1)); }

test_watchdog_respects_disable() {
SERVICE_ENABLED="false"; SERVICE_ACTIVE="false"; RESTART_COUNT=0
watchdog_restart_if_enabled 'example.service' 'test'
assert_eq "$RESTART_COUNT" '0'
SERVICE_ENABLED="true"
watchdog_restart_if_enabled 'example.service' 'test'
assert_eq "$RESTART_COUNT" '1'
}

test_ipx_watchdog_requires_three_full_failures() {
local config_path="${config_dir}/iran4321.toml"
cat > "$config_path" <<'EOF'
[tun]
name = "watch0"
remote_addr = "10.20.30.2/24"
mtu = 1320
EOF
PING_OK="false"
ping() { [[ "$PING_OK" == "true" ]]; }
RESTART_COUNT=0
backhaul_watchdog_check_path "$config_path" iran4321 backhaul-iran4321.service watch0 || true
backhaul_watchdog_check_path "$config_path" iran4321 backhaul-iran4321.service watch0 || true
assert_eq "$RESTART_COUNT" '0'
backhaul_watchdog_check_path "$config_path" iran4321 backhaul-iran4321.service watch0 || true
assert_eq "$RESTART_COUNT" '1'
[[ ! -f "$(backhaul_watchdog_state_file iran4321 failures)" ]] || fail "watchdog failure state was not reset"
PING_OK="true"
backhaul_watchdog_check_path "$config_path" iran4321 backhaul-iran4321.service watch0
assert_eq "$RESTART_COUNT" '1'
unset -f ping
rm -f "$config_path"
}

test_gigabit_backhaul_defaults() {
grep -qF 'CONFIG[heartbeat_timeout]="604800"' "${ROOT_DIR}/core/backhaul/core.sh" ||
fail "IPX heartbeat timeout is not protected from false reconnect loops"
grep -qF '[[ "$is_tun" == "true" ]] && default_tuning_profile="fast"' "${ROOT_DIR}/core/backhaul/core.sh" ||
fail "TUN tunnels do not default to the fast tuning profile"
grep -qF 'prompt_with_default "Batch Size" "${CONFIG[batch_size]:-2048}"' "${ROOT_DIR}/core/backhaul/core.sh" ||
fail "IPX batch size is not optimized by default"
}

test_multiqueue_fq_profile() {
TC_SCOPE_MODE=multi
TC_LIMIT=10000; TC_FLOW_LIMIT=100; TC_BUCKETS=1024
rm -f "$NETTUNE_QDISC_VALUES_FILE"
nettune_capture_fq_baseline
assert_eq "$(wc -l < "$NETTUNE_QDISC_VALUES_FILE" | tr -d '[:space:]')" '2'
nettune_apply_fq_profile
assert_eq "$TC_LIMIT" '32768'
assert_eq "$TC_FLOW_LIMIT" '2048'
assert_eq "$TC_BUCKETS" '8192'
nettune_restore_fq_profile
assert_eq "$TC_LIMIT" '10000'
assert_eq "$TC_FLOW_LIMIT" '100'
TC_SCOPE_MODE=root
rm -f "$NETTUNE_QDISC_VALUES_FILE"
}

test_edit_restarts_active_service() {
SERVICE_ENABLED="true"; SERVICE_ACTIVE="true"; RESTART_COUNT=0; OPTIMIZE_SYNC_COUNT=0
enable_service_checked 'example.service' 0 || fail "active service was not restarted cleanly"
assert_eq "$RESTART_COUNT" '1'
assert_eq "$OPTIMIZE_SYNC_COUNT" '2'
}

test_edit_cancel_keeps_live_config() {
! grep -q '\.editing' "${ROOT_DIR}/core/backhaul/core.sh" ||
fail "Backhaul edit still moves the live config before the user finishes editing"
}

test_edit_load_uses_live_identity_and_mtu() {
local config_path="${TEST_ROOT}/config.toml" meta_path
cat > "$config_path" <<'EOF'
[transport]
type = "tun"

[tun]
encapsulation = "ipx"
name = "test0"
local_addr = "10.10.10.1/24"
remote_addr = "10.10.10.2/24"
mtu = 1320

[ipx]
mode = "server"
profile = "tcp"
EOF
meta_path=$(tunnel_meta_file 'iran1234')
mkdir -p "$(dirname "$meta_path")"
printf 'peer_ip=192.0.2.44\npeer_ssh_port=2222\n' > "$meta_path"
automtu_save_settings iran1234 true 1200 1420 20
load_toml_into_config "$config_path" iran1234
assert_eq "${CONFIG[tun_mtu]}" '1320'
assert_eq "${CONFIG[peer_ip]}" '192.0.2.44'
assert_eq "${CONFIG[peer_ssh_port]}" '2222'
assert_eq "${CONFIG[smart_auto_mtu]}" 'true'
grep -qF 'prompt_boolean "Enable Smart Auto-MTU" "${CONFIG[smart_auto_mtu]:-false}" CONFIG[smart_auto_mtu]' "${ROOT_DIR}/core/backhaul/core.sh" ||
fail "new TUN/IPX tunnels do not default Smart Auto-MTU to false"
}

test_edit_tun_conflicts_exclude_current_config() {
local current_config="${config_dir}/iran1234.toml"
local other_config="${config_dir}/iran5678.toml"
cat > "$current_config" <<'EOF'
[tun]
name = "backhaul"
local_addr = "10.10.10.1/24"
remote_addr = "10.10.10.2/24"
EOF
cat > "$other_config" <<'EOF'
[tun]
name = "backhaul2"
local_addr = "10.10.20.1/24"
remote_addr = "10.10.20.2/24"
EOF

is_tun_name_in_use 'backhaul' || fail "current TUN name was not detected without an exclusion"
! is_tun_name_in_use 'backhaul' "$current_config" || fail "edit treated the current TUN name as a conflict"
is_tun_name_in_use 'backhaul2' "$current_config" || fail "edit missed another tunnel's TUN name"

is_tun_subnet_in_use '10.10.10.99/24' || fail "current TUN subnet was not detected without an exclusion"
! is_tun_subnet_in_use '10.10.10.99/24' "$current_config" || fail "edit treated the current TUN subnet as a conflict"
is_tun_subnet_in_use '10.10.20.99/24' "$current_config" || fail "edit missed another tunnel's TUN subnet"

is_tunnel_port_in_use server 1234 || fail "current health port was not detected without an exclusion"
! is_tunnel_port_in_use server 1234 "$current_config" || fail "edit treated the current health port as a conflict"
is_tunnel_port_in_use server 5678 "$current_config" || fail "edit missed another tunnel's health port"

grep -qF 'prompt_tun_section "${CONFIG[transport_type]}" "$mode" "$is_ipx" "$config_path"' "${ROOT_DIR}/core/backhaul/core.sh" ||
fail "full edit does not pass the current config to TUN conflict validation"
rm -f "$current_config" "$other_config"
}

test_backup_restores_metadata() {
local config_path="${TEST_ROOT}/edit.toml" service_path="${TEST_ROOT}/edit.service"
local meta_path backup_dir
meta_path=$(tunnel_meta_file 'edit-test')
mkdir -p "$(dirname "$meta_path")"
printf 'old-config\n' > "$config_path"
printf 'old-service\n' > "$service_path"
printf 'peer_ip=192.0.2.1\n' > "$meta_path"
backup_dir=$(backup_tunnel "$config_path" "$service_path" 'edit-test')
printf 'new-config\n' > "$config_path"
printf 'peer_ip=198.51.100.2\n' > "$meta_path"
restore_tunnel_backup "$backup_dir" "$config_path" "$service_path" 'example.service'
assert_eq "$(<"$config_path")" 'old-config'
assert_eq "$(<"$meta_path")" 'peer_ip=192.0.2.1'
}

test_optimize_exact_rollback() {
NETTUNE_SYSCTL_CONF="${TEST_ROOT}/etc/sysctl.d/99-tunnel-vm.conf"
NETTUNE_BBR_MODULE_CONF="${TEST_ROOT}/etc/modules-load.d/tunnel-vm-bbr.conf"
NETTUNE_SYSTEMD_LIMIT_CONF="${TEST_ROOT}/etc/systemd/system.conf.d/99-tunnel-vm-nofile.conf"
NETTUNE_QDISC_UNIT="${TEST_ROOT}/etc/systemd/system/tunnel-manager-qdisc.service"
NETTUNE_LIMITS_CONF="${TEST_ROOT}/etc/security/limits.conf"
NETTUNE_MEMINFO="${TEST_ROOT}/meminfo"
NETTUNE_CONNTRACK_PATH="${TEST_ROOT}/nf_conntrack_max"
mkdir -p "$(dirname "$NETTUNE_LIMITS_CONF")"
printf 'admin soft nofile 4096\n' > "$NETTUNE_LIMITS_CONF"
printf 'MemTotal:        1048576 kB\n' > "$NETTUNE_MEMINFO"
: > "$NETTUNE_CONNTRACK_PATH"

local old_rmem="${SYSVALS[net.core.rmem_max]}" old_cc="${SYSVALS[net.ipv4.tcp_congestion_control]}"
nettune_values_match net.ipv4.ip_local_reserved_ports '1000,1001,1002,2000' '1000-1002,2000' ||
fail "equivalent reserved-port ranges did not verify"
core_optimize_apply >/dev/null
[[ -f "$NETTUNE_SYSCTL_CONF" ]] || fail "optimization config was not created"
assert_file_contains "$NETTUNE_SYSCTL_CONF" 'net.ipv4.ip_local_reserved_ports = 8443,9000'
! grep -qF '7443' "$NETTUNE_SYSCTL_CONF" || fail "unmanaged listener was reserved"
assert_file_contains "$NETTUNE_SYSCTL_CONF" 'net.core.rmem_max = 33554432'
assert_file_contains "$NETTUNE_SYSCTL_CONF" 'net.ipv4.tcp_rmem = 4096 131072 16777216'
assert_eq "${SYSVALS[net.ipv4.tcp_congestion_control]}" 'bbr'
assert_eq "$TC_LIMIT" '262144'
assert_eq "$TC_FLOW_LIMIT" '65536'
assert_eq "$(cat "$NETTUNE_LIMITS_CONF")" 'admin soft nofile 4096'
[[ ! -f "$NETTUNE_SYSTEMD_LIMIT_CONF" ]] || fail "global systemd limit was created"

LISTEN_PORT=9443
core_optimize_apply >/dev/null
assert_file_contains "$NETTUNE_SYSCTL_CONF" 'net.ipv4.ip_local_reserved_ports = 9000,9443'
! grep -qF '8443' "$NETTUNE_SYSCTL_CONF" || fail "stale listener remained reserved after re-apply"

printf 'admin soft nofile 4096\noperator hard nofile 8192\n' > "$NETTUNE_LIMITS_CONF"

core_optimize_rollback >/dev/null
assert_eq "${SYSVALS[net.core.rmem_max]}" "$old_rmem"
assert_eq "${SYSVALS[net.ipv4.tcp_congestion_control]}" "$old_cc"
assert_eq "$TC_LIMIT" '10000'
assert_eq "$TC_FLOW_LIMIT" '100'
assert_eq "$(tail -1 "$NETTUNE_LIMITS_CONF")" 'operator hard nofile 8192'
[[ ! -d "$NETTUNE_STATE_DIR" ]] || fail "rollback state was not archived"
}

test_safe_assignment
test_validation_and_quoting
test_route_source_ip_selection
test_verified_reverse_configs
test_watchdog_respects_disable
test_ipx_watchdog_requires_three_full_failures
test_gigabit_backhaul_defaults
test_multiqueue_fq_profile
test_edit_restarts_active_service
test_edit_cancel_keeps_live_config
test_edit_load_uses_live_identity_and_mtu
test_edit_tun_conflicts_exclude_current_config
test_backup_restores_metadata
test_optimize_exact_rollback
printf 'All tunnel-manager core tests passed.\n'
