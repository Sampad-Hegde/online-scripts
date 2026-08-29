#!/bin/sh
# shellcheck shell=sh disable=SC2086,SC2012,SC3043
#@name        nvidia-gpu
#@title       NVIDIA GPU stress test
#@description NVIDIA only: full nvidia-smi telemetry, throttle-reason accounting, ECC / retired pages, XID scan
#@root        recommended
#@params      duration,interval,baseline,gpu,instances
#@include _lib.sh

os_init "nvidia-gpu"

DURATION=${DURATION:-120}
INTERVAL=${INTERVAL:-1}
BASELINE=${BASELINE:-10}
GPU=${GPU:-0}
INSTANCES=${INSTANCES:-2}
LOAD_CMD=${LOAD_CMD:-}          # env only: your own burn command, e.g. "gpu_burn 600"

while [ $# -gt 0 ]; do
    case "$1" in
        --duration|-d)  DURATION="$2"; shift 2 ;;
        --interval|-i)  INTERVAL="$2"; shift 2 ;;
        --baseline|-b)  BASELINE="$2"; shift 2 ;;
        --gpu|-g)       GPU="$2"; shift 2 ;;
        --instances|-n) INSTANCES="$2"; shift 2 ;;
        *) shift ;;
    esac
done
case "$DURATION"  in ''|*[!0-9]*) DURATION=120 ;; esac
case "$INSTANCES" in ''|*[!0-9]*) INSTANCES=2 ;; esac
case "$GPU"       in ''|*[!0-9]*) GPU=0 ;; esac
[ "$DURATION" -gt 7200 ] && DURATION=7200
[ "$DURATION" -lt 5 ] && DURATION=5
[ "$INSTANCES" -gt 8 ] && INSTANCES=8
[ "$INSTANCES" -lt 1 ] && INSTANCES=1

PCI_ROOT="$OS_SYSFS/bus/pci/devices"

LOGD="$OS_TMP/log"; mkdir -p "$LOGD"
BLOGD="$OS_TMP/base"; mkdir -p "$BLOGD"
for f in temp mtemp util clk mclk pwr fan mem pstate; do
    : > "$LOGD/$f"; : > "$BLOGD/$f"
done
THR_LOG="$LOGD/throttle"; : > "$THR_LOG"
BTHR_LOG="$BLOGD/throttle"; : > "$BTHR_LOG"

# ======================================================================
#  1. is there an NVIDIA card, and can we talk to it?
# ======================================================================
os_lspci_cache
: > "$OS_TMP/nvcards"
for p in "$PCI_ROOT"/*; do
    [ -d "$p" ] || continue
    [ "$(rd "$p/vendor")" = "0x10de" ] || continue
    case "$(rd "$p/class")" in 0x0300*|0x0302*|0x0380*) ;; *) continue ;; esac
    bdf=${p##*/}
    drv='none'
    [ -L "$p/driver" ] && { drv=$(readlink -f "$p/driver"); drv=${drv##*/}; }
    printf '%s\t%s\n' "$bdf" "$drv" >> "$OS_TMP/nvcards"
done

if [ ! -s "$OS_TMP/nvcards" ]; then
    err "no NVIDIA display adapter found on the PCI bus"
    note "for AMD or Intel graphics use:  curl -fsSL $(os_url /gpu-load.sh) | sudo sh"
    os_footer
    exit 1
fi

hdr "NVIDIA CARDS ON THE BUS"
t_head "PCI DEVICES" "BDF" "DEVICE" "KERNEL DRIVER"
while IFS="$TAB" read -r bdf drv; do
    t_row "$bdf" "$(pci_name "$bdf")" "$drv"
done < "$OS_TMP/nvcards"
t_end

KDRV=$(head -1 "$OS_TMP/nvcards" | cut -f2)

HAS_NVSMI=0
if have nvidia-smi; then
    HAS_NVSMI=1
elif [ -r /proc/driver/nvidia/version ]; then
    # module is loaded but the CLI is missing - install just the userspace tools
    nvmaj=$(awk '{ for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+\.[0-9]+/) { split($i, a, "."); print a[1]; exit } }' \
                /proc/driver/nvidia/version 2>/dev/null)
    if [ -n "$nvmaj" ] && ensure_cmd nvidia-smi "nvidia-utils-$nvmaj"; then
        HAS_NVSMI=1
    fi
fi

if [ "$HAS_NVSMI" != "1" ]; then
    err "nvidia-smi is not available, so none of the NVIDIA telemetry can be read"
    t_open "WHAT TO DO"
    t_row "Kernel driver in use" "$KDRV"
    case "$KDRV" in
        nouveau|none)
            t_row "Why"    "the open nouveau driver has no nvidia-smi and reports almost no telemetry"
            t_row "Best"   "reboot the live USB and enable third-party/proprietary drivers"
            t_row "Or"     "sudo apt-get install -y nvidia-driver-535 && sudo modprobe -r nouveau && sudo modprobe nvidia"
            t_row "Note"   "that download is ~500 MB into the USB session's RAM overlay and may need a reboot"
            ;;
        nvidia)
            t_row "Why"    "the proprietary module is loaded but the CLI package is missing"
            t_row "Fix"    "sudo apt-get install -y nvidia-utils-\$(nvidia-driver-major-version)"
            ;;
    esac
    t_row "Meanwhile" "gpu-load.sh still reads what nouveau exposes (temperature, clocks)"
    t_end
    note "curl -fsSL $(os_url /gpu-load.sh) | sudo sh"
    os_footer
    exit 1
fi

# ======================================================================
#  2. nvidia-smi helpers
# ======================================================================
nv_csv() { # <field list> -> one csv line, empty if the driver rejects a field
    nvidia-smi --query-gpu="$1" --format=csv,noheader,nounits -i "$G_IDX" 2>/dev/null
}
nv_f() { # <csv line> <column> -> trimmed field
    printf '%s' "$1" | awk -F', *' -v n="$2" '{ v = $n; gsub(/^[ \t]+|[ \t]+$/, "", v); print v }'
}
nvn() { # normalise nvidia-smi's "not supported" spellings
    case "$1" in
        ''|'[N/A]'|'[Not Supported]'|'[Unknown Error]'|'[Insufficient Permissions]'|'N/A')
            printf '%s' "${2--}" ;;
        *) printf '%s' "$1" ;;
    esac
}
nvq_val() { # <label from "nvidia-smi -q"> -> value
    awk -v k="$1" '
        { line = $0; sub(/^[ \t]+/, "", line)
          p = index(line, ":"); if (p < 1) next
          key = substr(line, 1, p-1); sub(/[ \t]+$/, "", key)
          if (key == k) { v = substr(line, p+1); gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit } }' \
        "$OS_TMP/nvq" 2>/dev/null
}
num_only() { printf '%s' "$1" | tr -cd '0-9'; }
# nvidia-smi reports watts as "220.00" - round instead of stripping the dot
nvint() { awk -v v="$1" 'BEGIN{ if (v ~ /^[0-9]+(\.[0-9]+)?$/ && v + 0 > 0) printf "%.0f", v + 0 }'; }

# pick the target GPU
G_IDX="$GPU"
if ! nvidia-smi -i "$G_IDX" -L >/dev/null 2>&1; then
    warn "GPU index $G_IDX not visible to nvidia-smi, falling back to 0"
    G_IDX=0
fi
NGPU=$(nvidia-smi -L 2>/dev/null | wc -l | tr -d ' ')

nvidia-smi -q -d TEMPERATURE,POWER,PERFORMANCE,CLOCK -i "$G_IDX" > "$OS_TMP/nvq" 2>/dev/null || : > "$OS_TMP/nvq"

# ---- static inventory, in small groups so one bad field cannot kill it all
S1=$(nv_csv "index,name,uuid,serial,vbios_version,driver_version,pci.bus_id,memory.total")
S2=$(nv_csv "pcie.link.gen.max,pcie.link.width.max,pcie.link.gen.current,pcie.link.width.current")
S3=$(nv_csv "power.limit,enforced.power.limit,power.min_limit,power.max_limit")
S4=$(nv_csv "clocks.max.sm,clocks.max.memory,compute_mode,persistence_mode,display_active,ecc.mode.current")

GNAME=$(nvn "$(nv_f "$S1" 2)")
PWR_LIMIT=$(nvint "$(nv_f "$S3" 2)")
[ -z "$PWR_LIMIT" ] && PWR_LIMIT=$(nvint "$(nv_f "$S3" 1)")
MAXSM=$(num_only "$(nv_f "$S4" 1)")
LINK_GEN_MAX=$(nvn "$(nv_f "$S2" 1)")
LINK_W_MAX=$(nvn "$(nv_f "$S2" 2)")

hdr "GPU $G_IDX"
t_open "IDENTITY"
t_row "Name"            "$GNAME"
t_row "GPUs present"    "$NGPU"
t_row "Bus id"          "$(nvn "$(nv_f "$S1" 7)")"
t_row "UUID"            "$(nvn "$(nv_f "$S1" 3)")"
t_row "Serial"          "$(nvn "$(nv_f "$S1" 4)" 'not exposed (consumer board)')"
t_row "VBIOS"           "$(nvn "$(nv_f "$S1" 5)")"
t_row "Driver"          "$(nvn "$(nv_f "$S1" 6)")  $CD(kernel module: $KDRV)$CR"
t_row "VRAM"            "$(nvn "$(nv_f "$S1" 8)") MiB"
t_row "Max clocks"      "SM $(nvn "$MAXSM") MHz / memory $(nvn "$(nv_f "$S4" 2)") MHz"
t_row "Power limit"     "$(nvn "$(nv_f "$S3" 2)") W enforced $CD(default $(nvn "$(nv_f "$S3" 1)") W, range $(nvn "$(nv_f "$S3" 3)")-$(nvn "$(nv_f "$S3" 4)") W)$CR"
t_row "PCIe link"       "Gen$(nvn "$(nv_f "$S2" 3)") x$(nvn "$(nv_f "$S2" 4)")  (card supports Gen$LINK_GEN_MAX x$LINK_W_MAX)"
t_row "Compute mode"    "$(nvn "$(nv_f "$S4" 3)")"
t_row "Persistence"     "$(nvn "$(nv_f "$S4" 4)")"
t_row "Display attached" "$(nvn "$(nv_f "$S4" 5)")"
t_row "ECC"             "$(nvn "$(nv_f "$S4" 6)" 'not supported')"
t_end

# ---- thermal limits straight from the card, used by the verdict later
T_SHUTDOWN=$(num_only "$(nvq_val 'GPU Shutdown Temp')")
T_SLOWDOWN=$(num_only "$(nvq_val 'GPU Slowdown Temp')")
T_MAXOP=$(num_only "$(nvq_val 'GPU Max Operating Temp')")
T_TARGET=$(num_only "$(nvq_val 'GPU Target Temperature')")

t_open "LIMITS REPORTED BY THE CARD"
t_row "Target temperature"  "$(dv "$T_TARGET" '-')${T_TARGET:+ C}   $CD(where the fan curve aims)$CR"
t_row "Slowdown threshold"  "$(dv "$T_SLOWDOWN" '-')${T_SLOWDOWN:+ C}   $CD(clocks get cut here)$CR"
t_row "Max operating"       "$(dv "$T_MAXOP" '-')${T_MAXOP:+ C}"
t_row "Shutdown"            "$(dv "$T_SHUTDOWN" '-')${T_SHUTDOWN:+ C}"
t_note "these come from the VBIOS, so the verdict below is judged against this card's own limits"
t_end

# ======================================================================
#  3. history: ECC, retired pages, remapped rows, past XIDs
# ======================================================================
hdr "CARD HISTORY (what the previous owner did to it)"

E1=$(nv_csv "ecc.errors.corrected.aggregate.total,ecc.errors.uncorrected.aggregate.total,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total")
R1=$(nv_csv "retired_pages.single_bit_ecc.count,retired_pages.double_bit.count,retired_pages.pending")
RR=$(nvidia-smi --query-remapped-rows=remapped_rows.correctable,remapped_rows.uncorrectable,remapped_rows.pending,remapped_rows.failure \
        --format=csv,noheader,nounits -i "$G_IDX" 2>/dev/null)

: > "$OS_TMP/xid_before"
if have dmesg; then
    $SUDO dmesg 2>/dev/null | grep -iE 'NVRM.*[Xx]id' > "$OS_TMP/xid_before"
elif have journalctl; then
    $SUDO journalctl -k --no-pager 2>/dev/null | grep -iE 'NVRM.*[Xx]id' > "$OS_TMP/xid_before"
fi
XID_BEFORE=$(wc -l < "$OS_TMP/xid_before" | tr -d ' ')

t_open "RELIABILITY COUNTERS"
t_row "ECC corrected (lifetime)"   "$(nvn "$(nv_f "$E1" 1)" 'n/a - no ECC on this board')"
t_row "ECC uncorrected (lifetime)" "$(nvn "$(nv_f "$E1" 2)" 'n/a')"
t_row "Retired pages (single bit)" "$(nvn "$(nv_f "$R1" 1)" 'n/a')"
t_row "Retired pages (double bit)" "$(nvn "$(nv_f "$R1" 2)" 'n/a')"
t_row "Retirement pending"         "$(nvn "$(nv_f "$R1" 3)" 'n/a')"
if [ -n "$RR" ]; then
    t_row "Remapped rows (corr/unc)" "$(nvn "$(nv_f "$RR" 1)") / $(nvn "$(nv_f "$RR" 2)")"
    t_row "Remapped pending/failure" "$(nvn "$(nv_f "$RR" 3)") / $(nvn "$(nv_f "$RR" 4)")"
fi
t_row "XID errors already in the kernel log" "$XID_BEFORE"
t_note "retired pages, remapped rows or uncorrected ECC on a used card mean failing VRAM"
t_note "XID lines are NVIDIA hardware/driver faults - a healthy card logs none"
t_end

if [ "$XID_BEFORE" -gt 0 ]; then
    t_head "XID ERRORS FOUND BEFORE THE TEST" "KERNEL LOG"
    head -5 "$OS_TMP/xid_before" | while IFS= read -r l; do t_row "$(trim "$l")"; done
    t_end
fi

# ======================================================================
#  4. sampling
# ======================================================================
# One nvidia-smi call per sample. Throttle reasons come from the same call
# when the driver supports the CSV fields, otherwise from "-q -d PERFORMANCE".
Q_RUN="temperature.gpu,utilization.gpu,clocks.current.sm,clocks.current.memory,power.draw,fan.speed,pstate,memory.used,temperature.memory"
Q_THR="clocks_throttle_reasons.sw_power_cap,clocks_throttle_reasons.hw_slowdown,clocks_throttle_reasons.hw_thermal_slowdown,clocks_throttle_reasons.hw_power_brake_slowdown,clocks_throttle_reasons.sw_thermal_slowdown"

THR_MODE=none
if [ -n "$(nv_csv "$Q_THR")" ]; then
    THR_MODE=csv
elif nvidia-smi -q -d PERFORMANCE -i "$G_IDX" 2>/dev/null | grep -qiE 'Clocks (Throttle|Event) Reasons'; then
    THR_MODE=text
fi

thr_text() { # -> "swpwr hwsd hwtherm hwbrake swtherm"
    nvidia-smi -q -d PERFORMANCE -i "$G_IDX" 2>/dev/null | awk '
        function act(s) { return (s ~ /Not Active/) ? 0 : ((s ~ /Active/) ? 1 : 0) }
        /SW Power Cap/            { a = act($0) }
        /HW Thermal Slowdown/     { c = act($0); next }
        /HW Power Brake Slowdown/ { d = act($0); next }
        /HW Slowdown/             { b = act($0) }
        /SW Thermal Slowdown/     { e = act($0) }
        END { printf "%d %d %d %d %d\n", a+0, b+0, c+0, d+0, e+0 }'
}

nv_sample() { # $1 = log dir, $2 = throttle log
    if [ "$THR_MODE" = "csv" ]; then
        nvidia-smi --query-gpu="$Q_RUN,$Q_THR" --format=csv,noheader,nounits -i "$G_IDX" \
            2>/dev/null > "$OS_TMP/s"
    else
        nvidia-smi --query-gpu="$Q_RUN" --format=csv,noheader,nounits -i "$G_IDX" \
            2>/dev/null > "$OS_TMP/s"
    fi
    [ -s "$OS_TMP/s" ] || return 1
    awk -F', *' -v d="$1" 'NR == 1 {
        if ($1 ~ /^[0-9]/) printf "%d\n", $1 * 1000 >> (d "/temp")
        if ($2 ~ /^[0-9]/) printf "%d\n", $2         >> (d "/util")
        if ($3 ~ /^[0-9]/) printf "%d\n", $3         >> (d "/clk")
        if ($4 ~ /^[0-9]/) printf "%d\n", $4         >> (d "/mclk")
        if ($5 ~ /^[0-9.]+$/) printf "%d\n", $5 * 1000 >> (d "/pwr")
        if ($6 ~ /^[0-9]/) printf "%d\n", $6         >> (d "/fan")
        if ($7 != "")      printf "%s\n", $7         >> (d "/pstate")
        if ($8 ~ /^[0-9]/) printf "%d\n", $8         >> (d "/mem")
        if ($9 ~ /^[0-9]/) printf "%d\n", $9 * 1000  >> (d "/mtemp")
    }' "$OS_TMP/s"
    case "$THR_MODE" in
        csv)
            awk -F', *' 'NR == 1 {
                printf "%d %d %d %d %d\n",
                    ($10 ~ /^Active/), ($11 ~ /^Active/), ($12 ~ /^Active/),
                    ($13 ~ /^Active/), ($14 ~ /^Active/)
            }' "$OS_TMP/s" >> "$2" ;;
        text) thr_text >> "$2" ;;
    esac
}

# ======================================================================
#  5. load engine
# ======================================================================
smoke() {
    ( "$@" ) >/dev/null 2>&1 &
    _p=$!
    sleep 3
    if kill -0 "$_p" 2>/dev/null; then kill "$_p" 2>/dev/null; wait "$_p" 2>/dev/null; return 0; fi
    wait "$_p" 2>/dev/null
    return $?
}

[ -z "${DISPLAY:-}" ] && [ -e /tmp/.X11-unix/X0 ] && DISPLAY=:0 && export DISPLAY
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    for wd in /run/user/*/wayland-0; do
        [ -e "$wd" ] && { WAYLAND_DISPLAY=wayland-0; XDG_RUNTIME_DIR=${wd%/wayland-0}
                          export WAYLAND_DISPLAY XDG_RUNTIME_DIR; break; }
    done
fi

ENGINE=''; ENGINE_DESC=''; ENGINE_KIND=''
pick_engine() {
    if [ -n "$LOAD_CMD" ]; then
        ENGINE="$LOAD_CMD"; ENGINE_KIND=compute
        ENGINE_DESC="your LOAD_CMD: $LOAD_CMD"; return 0
    fi
    for b in gpu_burn gpu-burn; do
        if have "$b"; then
            ENGINE="$b $DURATION"; ENGINE_KIND=compute
            ENGINE_DESC="$b (CUDA burn - the heaviest load there is)"; return 0
        fi
    done
    if have clpeak && smoke clpeak; then
        ENGINE='clpeak'; ENGINE_KIND=compute
        ENGINE_DESC="clpeak (OpenCL compute, x$INSTANCES)"; return 0
    fi
    if ensure_cmd stress-ng && smoke stress-ng --gpu 1 --timeout 2s; then
        ENGINE="stress-ng --gpu $INSTANCES --timeout ${DURATION}s"; ENGINE_KIND=graphics
        ENGINE_DESC="stress-ng --gpu (EGL/GBM)"; return 0
    fi
    for g in glmark2-es2-drm glmark2-drm; do
        if have "$g" || ensure_cmd "$g"; then
            if smoke "$g" --off-screen -b build; then
                ENGINE="$g --off-screen --size 1920x1080 -b build -b texture -b shading -b bump -b refract"
                ENGINE_KIND=graphics
                ENGINE_DESC="$g at 1920x1080 (DRM, works on a bare console, x$INSTANCES)"; return 0
            fi
        fi
    done
    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        if ensure_cmd vkmark && smoke vkmark -b vertex; then
            ENGINE='vkmark -b vertex:device-local=true -b texture -b shading'
            ENGINE_KIND=graphics
            ENGINE_DESC="vkmark (Vulkan, x$INSTANCES)"; return 0
        fi
        for g in glmark2-es2-wayland glmark2-wayland glmark2-es2 glmark2; do
            if have "$g" || ensure_cmd "$g" glmark2; then
                if smoke "$g" -b build; then
                    ENGINE="$g --size 1920x1080 -b build -b texture -b shading -b bump -b refract"
                    ENGINE_KIND=graphics
                    ENGINE_DESC="$g at 1920x1080 on the desktop session (x$INSTANCES)"; return 0
                fi
            fi
        done
    fi
    if ensure_cmd clpeak && smoke clpeak; then
        ENGINE='clpeak'; ENGINE_KIND=compute
        ENGINE_DESC="clpeak (OpenCL compute, x$INSTANCES)"; return 0
    fi
    return 1
}

step "looking for a GPU load generator"
pick_engine || { ENGINE=''; ENGINE_DESC='none available - MONITOR ONLY'; }

LOAD_PIDS=''
stop_all() {
    touch "$OS_TMP/stop" 2>/dev/null
    [ -n "$LOAD_PIDS" ] && kill $LOAD_PIDS 2>/dev/null
    have pkill && pkill -P $$ 2>/dev/null
}
trap 'stop_all; os_cleanup; exit 130' INT
trap 'stop_all; os_cleanup; exit 143' TERM
trap 'stop_all; os_cleanup' EXIT

start_load() {
    [ -z "$ENGINE" ] && return 1
    _end="$1"
    _n=1
    case "$ENGINE" in
        gpu_burn*|gpu-burn*|"$LOAD_CMD") _copies=1 ;;   # these saturate on their own
        stress-ng*) _copies=1 ;;                        # --gpu already takes a count
        *) _copies="$INSTANCES" ;;
    esac
    while [ "$_n" -le "$_copies" ]; do
        ( while [ ! -f "$OS_TMP/stop" ]; do
              [ "$(date +%s)" -ge "$_end" ] && break
              # shellcheck disable=SC2086
              $ENGINE >> "$OS_TMP/engine.out" 2>&1 || break
          done ) &
        LOAD_PIDS="$LOAD_PIDS $!"
        _n=$((_n + 1))
    done
    return 0
}

t_open "TEST PLAN"
t_row "GPU"             "#$G_IDX  $GNAME"
t_row "Duration"        "${DURATION}s  (+${BASELINE}s idle baseline)"
t_row "Sample interval" "${INTERVAL}s"
t_row "Load engine"     "$ENGINE_DESC"
t_row "Throttle source" "$(case $THR_MODE in csv) echo 'nvidia-smi query fields' ;; text) echo 'nvidia-smi -q -d PERFORMANCE' ;; *) echo 'not supported by this driver' ;; esac)"
t_end

if [ -z "$ENGINE" ]; then
    warn "no load generator could be started - this run will only monitor."
    note "start your own load (a game, a benchmark, ollama, blender) and re-run, or:"
    note "  apt-get install -y glmark2-drm stress-ng clpeak"
    note "  LOAD_CMD='gpu_burn 600' curl ... | sudo sh   # if you have gpu-burn built"
fi

# ======================================================================
#  6. idle baseline
# ======================================================================
hdr "IDLE BASELINE (${BASELINE}s)"
b_end=$(( $(date +%s) + BASELINE ))
while [ "$(date +%s)" -lt "$b_end" ]; do
    nv_sample "$BLOGD" "$BTHR_LOG"
    sleep "$INTERVAL"
done

t_head "IDLE" "METRIC" "MIN" "MAX" "AVG" "MEDIAN" "SAMPLES"
stats_row "Temperature"  "$BLOGD/temp" 1000 "C" 1
stats_row "Utilisation"  "$BLOGD/util" 1 "%" 0
stats_row "SM clock"     "$BLOGD/clk" 1 "MHz" 0
stats_row "Power"        "$BLOGD/pwr" 1000 "W" 1
stats_row "Fan"          "$BLOGD/fan" 1 "%" 0
t_end
idle_temp=$(stats_calc "$BLOGD/temp" 1000 1 | awk '{print $3}')
idle_pwr=$(stats_calc "$BLOGD/pwr" 1000 1 | awk '{print $3}')
idle_fan=$(stats_calc "$BLOGD/fan" 1 0 | awk '{print $3}')

# ======================================================================
#  7. load run
# ======================================================================
hdr "LOAD RUN (${DURATION}s)"
l_end=$(( $(date +%s) + DURATION ))
start_load "$l_end" || true

n=0
while [ ! -f "$OS_TMP/stop" ]; do
    [ "$(date +%s)" -ge "$l_end" ] && break
    nv_sample "$LOGD" "$THR_LOG"
    n=$((n + 1))
    if [ $((n % 5)) = 0 ]; then
        tc=$(tail -1 "$LOGD/temp" 2>/dev/null); uc=$(tail -1 "$LOGD/util" 2>/dev/null)
        cc=$(tail -1 "$LOGD/clk" 2>/dev/null);  wc=$(tail -1 "$LOGD/pwr" 2>/dev/null)
        fc=$(tail -1 "$LOGD/fan" 2>/dev/null)
        flags=''
        if [ -s "$THR_LOG" ]; then
            flags=$(tail -1 "$THR_LOG" | awk '{
                s = ""
                if ($1) s = s " PWRCAP"
                if ($3 || $5) s = s " THERMAL"
                if ($4) s = s " PWRBRAKE"
                if ($2 && !$3 && !$4) s = s " HWSLOW"
                print s }')
        fi
        printf '%s  [%4ds/%ds]  %s C  util %s%%  %s MHz  %s W  fan %s%%%s%s\n' \
            "$CD" "$((n * INTERVAL))" "$DURATION" \
            "$(awk -v v="${tc:-0}" 'BEGIN{printf "%.0f", v/1000}')" "${uc:--}" \
            "${cc:--}" "$(awk -v v="${wc:-0}" 'BEGIN{printf "%.0f", v/1000}')" "${fc:--}" \
            "$CY$flags" "$CR"
    fi
    sleep "$INTERVAL"
done
touch "$OS_TMP/stop"
[ -n "$LOAD_PIDS" ] && kill $LOAD_PIDS 2>/dev/null
wait 2>/dev/null
rm -f "$OS_TMP/stop"

printf '\n'
t_head "UNDER LOAD" "METRIC" "MIN" "MAX" "AVG" "MEDIAN" "SAMPLES"
stats_row "Core temperature" "$LOGD/temp" 1000 "C" 1
[ -s "$LOGD/mtemp" ] && stats_row "Memory temperature" "$LOGD/mtemp" 1000 "C" 1
stats_row "Utilisation"      "$LOGD/util" 1 "%" 0
stats_row "SM clock"         "$LOGD/clk" 1 "MHz" 0
stats_row "Memory clock"     "$LOGD/mclk" 1 "MHz" 0
stats_row "Power draw"       "$LOGD/pwr" 1000 "W" 1
stats_row "Fan speed"        "$LOGD/fan" 1 "%" 0
stats_row "VRAM used"        "$LOGD/mem" 1 "MiB" 0
t_end

peak_temp=$(stats_calc "$LOGD/temp" 1000 0 | awk '{print $2}')
avg_temp=$(stats_calc "$LOGD/temp" 1000 1 | awk '{print $3}')
peak_pwr=$(stats_calc "$LOGD/pwr" 1000 0 | awk '{print $2}')
avg_util=$(stats_calc "$LOGD/util" 1 0 | awk '{print $3}')
peak_fan=$(stats_calc "$LOGD/fan" 1 0 | awk '{print $2}')
avg_clk=$(stats_calc "$LOGD/clk" 1 0 | awk '{print $3}')
max_clk_seen=$(stats_calc "$LOGD/clk" 1 0 | awk '{print $2}')
min_clk=$(stats_calc "$LOGD/clk" 1 0 | awk '{print $1}')
nsamp=$(stats_calc "$LOGD/temp" 1000 0 | awk '{print $5}')

# ======================================================================
#  8. throttle accounting  - the reason this script exists
# ======================================================================
hdr "THROTTLE REASONS"
if [ "$THR_MODE" = "none" ] || [ ! -s "$THR_LOG" ]; then
    warn "this driver does not report clock throttle reasons"
else
    total=$(wc -l < "$THR_LOG" | tr -d ' ')
    thr_row() { # column label meaning
        set -- "$1" "$2" "$3"
        _c=$1; _l=$2; _m=$3
        _res=$(awk -v c="$_c" '{ if ($c + 0 == 1) n++ } END { printf "%d %d\n", n+0, (NR ? (n+0)*100/NR : 0) }' "$THR_LOG")
        _n=$(printf '%s' "$_res" | cut -d' ' -f1)
        _p=$(printf '%s' "$_res" | cut -d' ' -f2)
        _col=""
        [ "$_n" -gt 0 ] && _col="$CY"
        case "$_c" in
            3|4|5) [ "$_n" -gt 0 ] && _col="$CE" ;;
        esac
        t_row "${_col}${_l}${CR}" "$_n of $total" "$(pct_bar "$_p" 12)" "$_m"
    }
    t_head "SHARE OF SAMPLES WITH EACH REASON ACTIVE" "REASON" "SAMPLES" "SHARE" "WHAT IT MEANS"
    thr_row 1 "SW power cap"        "hitting the power limit - normal, the card is working as designed"
    thr_row 2 "HW slowdown"         "generic hardware slowdown, see the two rows below"
    thr_row 3 "HW thermal slowdown" "core too hot: dried paste, blocked fins or a dead fan"
    thr_row 4 "HW power brake"      "external power brake: PSU or connector problem"
    thr_row 5 "SW thermal slowdown" "driver cut clocks on temperature"
    t_note "a card that only shows 'SW power cap' is healthy; any thermal row is a cooling fault"
    t_end
fi

t_open "BEHAVIOUR"
t_row "Idle -> load temperature" "$(dv "$idle_temp") C  ->  $avg_temp C  (peak $peak_temp C)"
t_row "Rise over idle"  "$(awk -v a="$idle_temp" -v b="$peak_temp" 'BEGIN{ if (a=="-"||b=="-") print "-"; else printf "%+.1f C", b-a }')"
t_row "Idle -> load power" "$(dv "$idle_pwr") W  ->  peak $peak_pwr W$([ -n "$PWR_LIMIT" ] && printf ' of %s W limit (%s)' "$PWR_LIMIT" "$(awk -v p="$peak_pwr" -v l="$PWR_LIMIT" 'BEGIN{ if (l+0>0) printf "%.0f%%", p*100/l; else printf "-" }')")"
t_row "Idle -> load fan"   "$(dv "$idle_fan") %  ->  peak $peak_fan %"
t_row "SM clock"        "min $min_clk / avg $avg_clk / max $max_clk_seen MHz$([ -n "$MAXSM" ] && printf ' (card max %s MHz)' "$MAXSM")"
t_row "Performance states seen" "$(sort -u "$LOGD/pstate" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
cs=$(nv_csv "pcie.link.gen.current,pcie.link.width.current")
t_row "PCIe link at the end" "Gen$(nvn "$(nv_f "$cs" 1)") x$(nvn "$(nv_f "$cs" 2)")  (max Gen$LINK_GEN_MAX x$LINK_W_MAX)"
t_end

if [ -s "$LOGD/temp" ]; then
    hdr "TIMELINES"
    printf '  %stemperature%s  %s\n' "$CB" "$CR" "$(sparkline "$LOGD/temp" $((OS_COLS - 20)))"
    printf '  %s%s C .. %s C%s\n\n' "$CD" "$(stats_calc "$LOGD/temp" 1000 0 | awk '{print $1}')" "$peak_temp" "$CR"
    printf '  %sSM clock%s     %s\n' "$CB" "$CR" "$(sparkline "$LOGD/clk" $((OS_COLS - 20)))"
    printf '  %s%s MHz .. %s MHz%s\n\n' "$CD" "$min_clk" "$max_clk_seen" "$CR"
    printf '  %spower%s        %s\n' "$CB" "$CR" "$(sparkline "$LOGD/pwr" $((OS_COLS - 20)))"
    printf '  %s%s W .. %s W%s\n\n' "$CD" "$(stats_calc "$LOGD/pwr" 1000 0 | awk '{print $1}')" "$peak_pwr" "$CR"
fi

# ======================================================================
#  9. faults logged during the run
# ======================================================================
: > "$OS_TMP/xid_after"
if have dmesg; then
    $SUDO dmesg 2>/dev/null | grep -iE 'NVRM.*[Xx]id' > "$OS_TMP/xid_after"
elif have journalctl; then
    $SUDO journalctl -k --no-pager 2>/dev/null | grep -iE 'NVRM.*[Xx]id' > "$OS_TMP/xid_after"
fi
XID_AFTER=$(wc -l < "$OS_TMP/xid_after" | tr -d ' ')
XID_NEW=$((XID_AFTER - XID_BEFORE))
[ "$XID_NEW" -lt 0 ] && XID_NEW=0

if [ "$XID_NEW" -gt 0 ]; then
    hdr "NEW XID ERRORS DURING THE TEST"
    t_head "KERNEL LOG" "LINE"
    tail -n "$XID_NEW" "$OS_TMP/xid_after" | while IFS= read -r l; do t_row "$(trim "$l")"; done
    t_note "an XID during a stress test means the card faulted under load - walk away"
    t_end
fi

# ======================================================================
#  10. verdict
# ======================================================================
hdr "VERDICT"
t_open "ASSESSMENT"

# --- cooling, judged against the card's own thresholds
if [ "$peak_temp" = "-" ]; then
    t_row "Cooling" "${CY}no temperature samples${CR}"
elif [ -n "$T_SLOWDOWN" ] && [ "$peak_temp" -ge "$T_SLOWDOWN" ] 2>/dev/null; then
    t_row "Cooling" "${CE}peak ${peak_temp} C reached this card's ${T_SLOWDOWN} C slowdown point${CR}"
elif [ -n "$T_MAXOP" ] && [ "$peak_temp" -ge "$T_MAXOP" ] 2>/dev/null; then
    t_row "Cooling" "${CE}peak ${peak_temp} C is at the ${T_MAXOP} C max operating temperature${CR}"
elif [ -n "$T_TARGET" ] && [ "$peak_temp" -gt "$T_TARGET" ] 2>/dev/null; then
    t_row "Cooling" "${CY}peak ${peak_temp} C is above the ${T_TARGET} C target - repaste/clean would help${CR}"
elif [ "$peak_temp" -ge 85 ] 2>/dev/null; then
    t_row "Cooling" "${CY}peak ${peak_temp} C - hot${CR}"
else
    t_row "Cooling" "${CG}peak ${peak_temp} C - healthy${CR}"
fi

# --- fan
if [ "$peak_fan" = "-" ]; then
    t_row "Fan" "${CD}no fan sensor (passive or datacenter board)${CR}"
elif [ "$peak_fan" = "0" ] && [ "$peak_temp" != "-" ] && [ "$peak_temp" -ge 55 ] 2>/dev/null; then
    t_row "Fan" "${CE}fan never spun up while the core hit ${peak_temp} C - dead fan or unplugged${CR}"
elif [ "$peak_fan" -ge 95 ] 2>/dev/null && [ "$peak_temp" -ge 80 ] 2>/dev/null; then
    t_row "Fan" "${CY}fan at ${peak_fan}% and still ${peak_temp} C - cooler is past its best${CR}"
else
    t_row "Fan" "${CG}ramped to ${peak_fan}%${CR}"
fi

# --- throttling
if [ "$THR_MODE" = "none" ] || [ ! -s "$THR_LOG" ]; then
    t_row "Throttling" "${CD}not reported by this driver${CR}"
else
    th=$(awk '{ if ($3 + $5 > 0) t++ ; if ($4 > 0) b++ ; if ($1 > 0) p++ } END { printf "%d %d %d\n", t+0, b+0, p+0 }' "$THR_LOG")
    t_therm=$(printf '%s' "$th" | cut -d' ' -f1)
    t_brake=$(printf '%s' "$th" | cut -d' ' -f2)
    t_pcap=$(printf '%s' "$th" | cut -d' ' -f3)
    if [ "$t_therm" -gt 0 ]; then
        t_row "Throttling" "${CE}thermal slowdown in $t_therm sample(s) - the cooler cannot keep up${CR}"
    elif [ "$t_brake" -gt 0 ]; then
        t_row "Throttling" "${CE}power brake in $t_brake sample(s) - check the PSU and the 12V connectors${CR}"
    elif [ "$t_pcap" -gt 0 ]; then
        t_row "Throttling" "${CG}power limited in $t_pcap sample(s), no thermal throttling - normal${CR}"
    else
        t_row "Throttling" "${CG}none${CR}"
    fi
fi

# --- was the load real?
if [ -z "$ENGINE" ]; then
    t_row "Load quality" "${CY}monitor only - no load ran, the thermal result proves nothing${CR}"
elif [ "$avg_util" != "-" ] && [ "$avg_util" -lt 50 ] 2>/dev/null; then
    t_row "Load quality" "${CY}average utilisation only ${avg_util}% - the engine barely touched the GPU${CR}"
elif [ -n "$PWR_LIMIT" ] && [ "$peak_pwr" != "-" ] && \
     [ "$(awk -v p="$peak_pwr" -v l="$PWR_LIMIT" 'BEGIN{ print (l+0>0 && p*100/l < 60) ? 1 : 0 }')" = "1" ]; then
    t_row "Load quality" "${CY}${avg_util}% busy but only ${peak_pwr} W of ${PWR_LIMIT} W - a graphics test; gpu-burn/clpeak would push harder${CR}"
else
    t_row "Load quality" "${CG}${avg_util}% busy, peak ${peak_pwr} W$([ -n "$PWR_LIMIT" ] && printf ' of %s W' "$PWR_LIMIT")${CR}"
fi

# --- memory / reliability
mem_bad=0
for v in "$(nv_f "$E1" 2)" "$(nv_f "$R1" 2)" "$(nv_f "$R1" 3)"; do
    case "$v" in ''|'[N/A]'|'[Not Supported]'|0) ;; *) mem_bad=1 ;; esac
done
if [ "$mem_bad" = "1" ]; then
    t_row "VRAM health" "${CE}the card reports retired pages or uncorrected ECC errors - failing memory${CR}"
else
    t_row "VRAM health" "${CG}no retired pages or uncorrected ECC errors reported${CR}"
fi

if [ "$XID_NEW" -gt 0 ]; then
    t_row "Stability" "${CE}$XID_NEW new XID error(s) logged during the run${CR}"
elif [ "$XID_BEFORE" -gt 0 ]; then
    t_row "Stability" "${CY}clean during this run, but $XID_BEFORE older XID error(s) are in the log${CR}"
else
    t_row "Stability" "${CG}${nsamp} samples over ${DURATION}s, no XID errors${CR}"
fi

# --- PCIe
cw=$(num_only "$(nv_f "$cs" 2)"); mw=$(num_only "$LINK_W_MAX")
if [ -n "$cw" ] && [ -n "$mw" ] && [ "$cw" -lt "$mw" ] 2>/dev/null; then
    t_row "PCIe" "${CY}linked at x$cw of x$mw - reseat the card or check the slot${CR}"
else
    t_row "PCIe" "${CG}full width (x${cw:-?})${CR}"
fi
t_end

note "longer soak:  curl -fsSL $(os_url /nvidia-gpu.sh) | sudo DURATION=1800 sh"
note "heaviest load: build gpu-burn, then  LOAD_CMD='gpu_burn 1800' ... | sudo sh"

os_footer
