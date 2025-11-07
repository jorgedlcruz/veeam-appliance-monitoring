#!/usr/bin/env bash
# Emits Prometheus-like node_exporter metrics and POSTs to InfluxDB v2 using curl.
# No sudo. No extra packages.

set -euo pipefail
set -a
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.veeam_influx.env"

if [ -f "$ENV_FILE" ]; then
  . "$ENV_FILE"
  [ "${DEBUG:-true}" = "true" ] && echo "[INFO] Loaded env from $ENV_FILE"
else
  echo "[ERROR] Env file not found at $ENV_FILE" >&2
  exit 1
fi
set +a

# Influx v2 target
INFLUX_PROTO="${INFLUX_PROTO:-https}"             # http or https
INFLUX_HOST="${INFLUX_HOST:-your-influx-host}"    # FQDN or IP
INFLUX_PORT="${INFLUX_PORT:-8086}"
INFLUX_ORG="${INFLUX_ORG:-YOUR_ORG}"
INFLUX_BUCKET="${INFLUX_BUCKET:-YOUR_BUCKET}"
INFLUX_TOKEN="${INFLUX_TOKEN:-YOUR_TOKEN}"
CURL_INSECURE="${CURL_INSECURE:-false}"           # true if self-signed
DEBUG="${DEBUG:-true}"
DRY_RUN="${DRY_RUN:-false}"

# Identity tags
INSTANCE="${INSTANCE:-$(hostname -f 2>/dev/null || hostname -s)}"
SERVER_NAME="${veeamBackupServer:-$(hostname -s)}"
# Version
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/veeam/transport"

VEAEMTRANSPORT_BIN="${VEAEMTRANSPORT_BIN:-/opt/veeam/transport/veeamtransport}"

get_version() {
  if [ -n "${version:-}" ]; then
    printf "%s" "$version"
    return
  fi

  for cand in "$VEAEMTRANSPORT_BIN" "$(command -v veeamtransport 2>/dev/null)"; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then
      v="$("$cand" -v 2>/dev/null | head -n1 | tr -d '\r')"
      [ -n "$v" ] && { printf "%s" "$v"; return; }
    fi
  done

  uname -r
}

VERSION="$(get_version)"

########################################
# Helpers
########################################
log() { [ "$DEBUG" = "true" ] && echo "[INFO] $*"; }
warn(){ echo "[WARN] $*" >&2; }
err() { echo "[ERROR] $*" >&2; }
escape() { echo "$1" | sed -e 's/\\/\\\\/g' -e 's/,/\\,/g' -e 's/ /\\ /g' -e 's/=/\\=/g'; }
ts_ns() { date +%s%N; }

tag_inst="instance=$(escape "$INSTANCE")"
tag_srv="serverName=$(escape "$SERVER_NAME")"
tag_ver="version=$(escape "$VERSION")"

CLK_TCK="$(getconf CLK_TCK 2>/dev/null || echo 100)"

CURL_COMMON=(-sS --max-time 10 --retry 2 --retry-delay 1)
[ "$CURL_INSECURE" = "true" ] && CURL_COMMON+=(-k)

WRITE_URL="${INFLUX_PROTO}://${INFLUX_HOST}:${INFLUX_PORT}/api/v2/write?org=$(printf %s "$INFLUX_ORG" | sed 's/ /%20/g')&bucket=$(printf %s "$INFLUX_BUCKET" | sed 's/ /%20/g')&precision=ns"
HEALTH_URL="${INFLUX_PROTO}://${INFLUX_HOST}:${INFLUX_PORT}/health"

post_block() {
  local name="$1"
  local payload="$2"
  local lines
  lines=$(printf "%s" "$payload" | sed '/^$/d' | wc -l | awk '{print $1}')
  if [ "$lines" -eq 0 ]; then
    log "$name: nothing to send"
    return 0
  fi

  if [ "$DEBUG" = "true" ]; then
    log "$name: preparing to send $lines line(s)"
    printf "%s" "$payload" | head -n 1 | sed 's/^/[SAMPLE] /'
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log "$name: DRY_RUN enabled, skipping POST"
    return 0
  fi

  local http_code
  http_code=$(printf "%s" "$payload" \
    | curl "${CURL_COMMON[@]}" -w "%{http_code}" -o /dev/null \
        -X POST "$WRITE_URL" \
        -H "Authorization: Token ${INFLUX_TOKEN}" \
        -H "Content-Type: text/plain; charset=utf-8" \
        --data-binary @-)

  if [ "$http_code" = "204" ]; then
    log "$name: write OK (HTTP 204)"
  else
    err "$name: write failed (HTTP $http_code)"
    printf "%s" "$payload" | head -n 5 | sed 's/^/[PAYLOAD_HEAD] /' >&2
    return 1
  fi
}

check_influx() {
  log "Checking InfluxDB health at $HEALTH_URL"
  local code
  code=$(curl "${CURL_COMMON[@]}" -o /dev/null -w "%{http_code}" "$HEALTH_URL" || true)
  if [ "$code" = "200" ]; then
    log "InfluxDB health OK"
  else
    warn "InfluxDB health check returned HTTP $code (continuing)"
  fi
}

########################################
# Build and send sections
########################################
TS=$(ts_ns)

check_influx

# 1) node_time_seconds and node_boot_time_seconds
now_s=$(date +%s)
uptime_s=$(awk '{print int($1)}' /proc/uptime)
boot_s=$((now_s - uptime_s))
LP_TIME=""
LP_TIME+="node_time_seconds,${tag_inst},${tag_srv},${tag_ver} value=${now_s} ${TS}"$'\n'
LP_TIME+="node_boot_time_seconds,${tag_inst},${tag_srv},${tag_ver} value=${boot_s} ${TS}"$'\n'
post_block "time" "$LP_TIME"

# 2) CPU seconds per CPU and total
LP_CPU=""
while read -r cpu user nice system idle iowait irq softirq steal guest gnice _; do
  [[ "$cpu" =~ ^cpu[0-9]+$ ]] || continue
  cpu_tag="cpu=$(escape "$cpu")"
  conv() { awk -v v="$1" -v hz="$CLK_TCK" 'BEGIN{printf "%.6f", v/hz}'; }
  declare -A m=(
    [user]="$user" [nice]="$nice" [system]="$system" [idle]="$idle"
    [iowait]="$iowait" [irq]="$irq" [softirq]="$softirq" [steal]="$steal"
    [guest]="$guest" [guest_nice]="$gnice"
  )
  for mode in "${!m[@]}"; do
    val="$(conv "${m[$mode]}")"
    LP_CPU+="node_cpu_seconds_total,${tag_inst},${tag_srv},${tag_ver},${cpu_tag},mode=${mode} value=${val} ${TS}"$'\n'
  done
done < <(grep -E '^cpu[0-9]+' /proc/stat)

read -r _ u n s i o irq sirq st g gn _ < <(grep -E '^cpu ' /proc/stat)
declare -A mt=([user]="$u" [nice]="$n" [system]="$s" [idle]="$i" [iowait]="$o" [irq]="$irq" [softirq]="$sirq" [steal]="$st" [guest]="$g" [guest_nice]="$gn")
for mode in "${!mt[@]}"; do
  val=$(awk -v v="${mt[$mode]}" -v hz="$CLK_TCK" 'BEGIN{printf "%.6f", v/hz}')
  LP_CPU+="node_cpu_seconds_total,${tag_inst},${tag_srv},${tag_ver},cpu=all,mode=${mode} value=${val} ${TS}"$'\n'
done
post_block "cpu" "$LP_CPU"

# 3) Load averages
read -r load1 load5 load15 _ < /proc/loadavg
LP_LOAD=""
LP_LOAD+="node_load1,${tag_inst},${tag_srv},${tag_ver} value=${load1} ${TS}"$'\n'
LP_LOAD+="node_load5,${tag_inst},${tag_srv},${tag_ver} value=${load5} ${TS}"$'\n'
LP_LOAD+="node_load15,${tag_inst},${tag_srv},${tag_ver} value=${load15} ${TS}"$'\n'
post_block "load" "$LP_LOAD"

# 4) Memory gauges
mem() { awk -v k="$1" '$1==k":"{print $2*1024}' /proc/meminfo; }
declare -A memv=(
  [MemTotal]="$(mem MemTotal)"
  [MemFree]="$(mem MemFree)"
  [MemAvailable]="$(mem MemAvailable)"
  [Buffers]="$(mem Buffers)"
  [Cached]="$(mem Cached)"
  [SReclaimable]="$(mem SReclaimable)"
  [SwapTotal]="$(mem SwapTotal)"
  [SwapFree]="$(mem SwapFree)"
)
LP_MEM=""
for k in "${!memv[@]}"; do
  LP_MEM+="node_memory_${k}_bytes,${tag_inst},${tag_srv},${tag_ver} value=${memv[$k]} ${TS}"$'\n'
done
post_block "memory" "$LP_MEM"

# 5) Filesystems
LP_FS=""
while read -r fs fstype total used avail pcent mount; do
  case "$fstype" in tmpfs|devtmpfs|overlay) continue ;; esac
  total_b=$((total*1024)); free_b=$(( (total-used)*1024 )); avail_b=$((avail*1024))
  tdev="device=$(escape "$fs")"
  ttype="fstype=$(escape "$fstype")"
  tmount="mountpoint=$(escape "$mount")"
  tags="${tag_inst},${tag_srv},${tag_ver},${tdev},${ttype},${tmount}"
  LP_FS+="node_filesystem_size_bytes,${tags} value=${total_b} ${TS}"$'\n'
  LP_FS+="node_filesystem_free_bytes,${tags} value=${free_b} ${TS}"$'\n'
  LP_FS+="node_filesystem_avail_bytes,${tags} value=${avail_b} ${TS}"$'\n'
done < <(df -kPT | awk 'NR>1 {print $1" "$2" "$3" "$4" "$5" "$6" "$7}')
post_block "filesystems" "$LP_FS"

# 6) Disks
LP_DISK=""
while read -r major minor dev rd_c rd_m rd_sec rd_ms wr_c wr_m wr_sec wr_ms io_now io_ms wio_ms rest; do
  [[ "$dev" =~ ^(loop|ram) ]] && continue
  [[ "$dev" =~ ^(sd|vd|nvme|dm-) ]] || continue
  tdev="device=$(escape "$dev")"
  tags="${tag_inst},${tag_srv},${tag_ver},${tdev}"
  rb=$((rd_sec*512))
  wb=$((wr_sec*512))
  LP_DISK+="node_disk_reads_completed_total,${tags} value=${rd_c} ${TS}"$'\n'
  LP_DISK+="node_disk_writes_completed_total,${tags} value=${wr_c} ${TS}"$'\n'
  LP_DISK+="node_disk_read_bytes_total,${tags} value=${rb} ${TS}"$'\n'
  LP_DISK+="node_disk_written_bytes_total,${tags} value=${wb} ${TS}"$'\n'
  LP_DISK+="node_disk_read_time_seconds_total,${tags} value=$(awk -v ms="$rd_ms" 'BEGIN{printf "%.3f", ms/1000.0}') ${TS}"$'\n'
  LP_DISK+="node_disk_write_time_seconds_total,${tags} value=$(awk -v ms="$wr_ms" 'BEGIN{printf "%.3f", ms/1000.0}') ${TS}"$'\n'
  LP_DISK+="node_disk_io_time_seconds_total,${tags} value=$(awk -v ms="$io_ms" 'BEGIN{printf "%.3f", ms/1000.0}') ${TS}"$'\n'
  LP_DISK+="node_disk_io_time_weighted_seconds_total,${tags} value=$(awk -v ms="$wio_ms" 'BEGIN{printf "%.3f", ms/1000.0}') ${TS}"$'\n'
done < /proc/diskstats
post_block "disks" "$LP_DISK"

# 7) Network
LP_NET=""
for d in /sys/class/net/*; do
  iface="$(basename "$d")"
  [ "$iface" = "lo" ] && continue
  [ -d "$d/statistics" ] || continue
  [ -f "$d/operstate" ] && state=$(cat "$d/operstate") || state=up
  [ "$state" != "up" ] && continue
  rx_b=$(cat "$d/statistics/rx_bytes" 2>/dev/null || echo 0)
  rx_p=$(cat "$d/statistics/rx_packets" 2>/dev/null || echo 0)
  rx_e=$(cat "$d/statistics/rx_errors" 2>/dev/null || echo 0)
  rx_d=$(cat "$d/statistics/rx_dropped" 2>/dev/null || echo 0)
  tx_b=$(cat "$d/statistics/tx_bytes" 2>/dev/null || echo 0)
  tx_p=$(cat "$d/statistics/tx_packets" 2>/dev/null || echo 0)
  tx_e=$(cat "$d/statistics/tx_errors" 2>/dev/null || echo 0)
  tx_d=$(cat "$d/statistics/tx_dropped" 2>/dev/null || echo 0)
  tif="interface=$(escape "$iface")"
  tags="${tag_inst},${tag_srv},${tag_ver},${tif}"
  LP_NET+="node_network_receive_bytes_total,${tags} value=${rx_b} ${TS}"$'\n'
  LP_NET+="node_network_transmit_bytes_total,${tags} value=${tx_b} ${TS}"$'\n'
  LP_NET+="node_network_receive_packets_total,${tags} value=${rx_p} ${TS}"$'\n'
  LP_NET+="node_network_transmit_packets_total,${tags} value=${tx_p} ${TS}"$'\n'
  LP_NET+="node_network_receive_errs_total,${tags} value=${rx_e} ${TS}"$'\n'
  LP_NET+="node_network_transmit_errs_total,${tags} value=${tx_e} ${TS}"$'\n'
  LP_NET+="node_network_receive_drop_total,${tags} value=${rx_d} ${TS}"$'\n'
  LP_NET+="node_network_transmit_drop_total,${tags} value=${tx_d} ${TS}"$'\n'
done
post_block "network" "$LP_NET"

# 8) Temperatures
LP_TEMP=""
for tz in /sys/class/thermal/thermal_zone*; do
  [ -d "$tz" ] || continue
  type=$(cat "$tz/type" 2>/dev/null || echo thermal)
  temp=$(cat "$tz/temp" 2>/dev/null || echo "")
  [ -z "$temp" ] && continue
  if [ "$temp" -gt 1000 ] 2>/dev/null; then
    val=$(awk -v v="$temp" 'BEGIN{printf "%.3f", v/1000.0}')
  else
    val=$(awk -v v="$temp" 'BEGIN{printf "%.3f", v+0.0}')
  fi
  tsens="sensor=$(escape "$type")"
  LP_TEMP+="node_thermal_zone_temp_celsius,${tag_inst},${tag_srv},${tag_ver},${tsens} value=${val} ${TS}"$'\n'
done
post_block "temperatures" "$LP_TEMP"

log "Done."