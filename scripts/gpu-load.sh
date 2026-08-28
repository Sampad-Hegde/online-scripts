#!/bin/sh
# shellcheck shell=sh disable=SC2086,SC2012,SC3043
#@name        gpu-load
#@title       GPU load + thermal test
#@description Loads the GPU, samples temperature / utilisation / clock / power, min-max-avg-median
#@root        recommended
#@params      duration,interval,baseline,gpu
#@include _lib.sh

os_init "gpu-load"

DURATION=${DURATION:-60}
INTERVAL=${INTERVAL:-1}
BASELINE=${BASELINE:-8}
GPU=${GPU:-0}

while [ $# -gt 0 ]; do
    case "$1" in
        --duration|-d) DURATION="$2"; shift 2 ;;
        --interval|-i) INTERVAL="$2"; shift 2 ;;
        --baseline|-b) BASELINE="$2"; shift 2 ;;
        --gpu|-g)      GPU="$2"; shift 2 ;;
        *) shift ;;
    esac
done
case "$DURATION" in ''|*[!0-9]*) DURATION=60 ;; esac
[ "$DURATION" -gt 3600 ] && DURATION=3600
[ "$DURATION" -lt 5 ] && DURATION=5

# roots are variables so the test suite can point them at a fake tree
PCI_ROOT="$OS_SYSFS/bus/pci/devices"
DRM_ROOT="$OS_SYSFS/class/drm"

T_LOG="$OS_TMP/gtemp.log"; U_LOG="$OS_TMP/gutil.log"; H_LOG="$OS_TMP/ghot.log"
C_LOG="$OS_TMP/gclk.log";  P_LOG="$OS_TMP/gpwr.log"
BT_LOG="$OS_TMP/bgtemp.log"; BU_LOG="$OS_TMP/bgutil.log"; BH_LOG="$OS_TMP/bghot.log"
BC_LOG="$OS_TMP/bgclk.log";  BP_LOG="$OS_TMP/bgpwr.log"
for f in "$T_LOG" "$U_LOG" "$C_LOG" "$P_LOG" "$H_LOG" \
         "$BT_LOG" "$BU_LOG" "$BC_LOG" "$BP_LOG" "$BH_LOG"; do : > "$f"; done

# ======================================================================
#  1. inventory
# ======================================================================
hdr "GPUs FOUND"
os_lspci_cache
: > "$OS_TMP/gpus"
idx=0
for p in "$PCI_ROOT"/*; do
    [ -d "$p" ] || continue
    cls=$(rd "$p/class")
    case "$cls" in 0x0300*|0x0302*|0x0380*) ;; *) continue ;; esac
    bdf=${p##*/}
    ven=$(rd "$p/vendor")
    case "$ven" in
        0x10de) vname="nvidia" ;; 0x1002|0x1022) vname="amd" ;;
        0x8086) vname="intel" ;; *) vname="other" ;;
    esac
    card=''
    for c in "$p"/drm/card*; do
        case "$c" in *-*) continue ;; esac
        [ -d "$c" ] && { card=${c##*/}; break; }
    done
    drv='-'
    [ -L "$p/driver" ] && { drv=$(readlink -f "$p/driver"); drv=${drv##*/}; }
    printf '%s\t%s\t%s\t%s\t%s\n' "$idx" "$bdf" "$vname" "${card:--}" "$drv" >> "$OS_TMP/gpus"
    idx=$((idx + 1))
done

t_head "GPU LIST" "#" "BDF" "VENDOR" "DEVICE" "DRIVER" "CARD" "VRAM" "PCIe LINK"
while IFS="$TAB" read -r i bdf vname card drv; do
    p="$PCI_ROOT/$bdf"
    vram='-'
    for vf in "$p/mem_info_vram_total" "$p/drm/$card/device/mem_info_vram_total"; do
        [ -r "$vf" ] && { vram=$(size_s "$(rd "$vf")"); break; }
    done
    if [ "$vram" = "-" ] && [ "$vname" = "nvidia" ] && have nvidia-smi; then
        vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader -i "$i" 2>/dev/null)
        [ -z "$vram" ] && vram='-'
    fi
    cs=$(rd "$p/current_link_speed"); cw=$(rd "$p/current_link_width")
    ms=$(rd "$p/max_link_speed");     mw=$(rd "$p/max_link_width")
    link='-'
    [ -n "$cs" ] && link="$(pcie_gen "$cs") x${cw:-?} / max $(pcie_gen "$ms") x${mw:-?}"
    t_row "$i" "$bdf" "$vname" "$(pci_name "$bdf")" "$drv" "$card" "$vram" "$link"
done < "$OS_TMP/gpus"
t_end

if [ ! -s "$OS_TMP/gpus" ]; then
    err "no GPU found on the PCI bus"
    os_footer
    exit 1
fi

# ---------------------------------------------------------- pick target
SEL=$(awk -F'\t' -v i="$GPU" '$1 == i { print; exit }' "$OS_TMP/gpus")
[ -z "$SEL" ] && SEL=$(head -1 "$OS_TMP/gpus")
G_IDX=$(printf '%s' "$SEL" | cut -f1)
G_BDF=$(printf '%s' "$SEL" | cut -f2)
G_VEN=$(printf '%s' "$SEL" | cut -f3)
G_CARD=$(printf '%s' "$SEL" | cut -f4)
G_DRV=$(printf '%s' "$SEL" | cut -f5)
G_DEV="$PCI_ROOT/$G_BDF"

# vendor specific sensor paths
G_TEMP=''; G_TEMP_LBL=''; G_PWR=''; G_BUSY=''; G_CLK=''; G_HOT=''
for h in "$G_DEV"/hwmon/hwmon*; do
    [ -d "$h" ] || continue
    for l in "$h"/temp*_label; do
        [ -r "$l" ] || continue
        lv=$(rd "$l")
        case "$lv" in
            edge|temp|junction|mem)
                [ -z "$G_TEMP" ] && { G_TEMP="${l%_label}_input"; G_TEMP_LBL="$lv"; }
                [ "$lv" = junction ] && G_HOT="${l%_label}_input" ;;
        esac
    done
    [ -z "$G_TEMP" ] && [ -r "$h/temp1_input" ] && { G_TEMP="$h/temp1_input"; G_TEMP_LBL="temp1"; }
    for pw in power1_average power1_input; do
        [ -r "$h/$pw" ] && { G_PWR="$h/$pw"; break; }
    done
done
[ -r "$G_DEV/gpu_busy_percent" ] && G_BUSY="$G_DEV/gpu_busy_percent"
for cf in "$G_DEV/pp_dpm_sclk" "$DRM_ROOT/$G_CARD/gt_cur_freq_mhz" \
          "$DRM_ROOT/$G_CARD/gt/gt0/rps_cur_freq_mhz"; do
    [ -r "$cf" ] && { G_CLK="$cf"; break; }
done

HAS_NVSMI=0
[ "$G_VEN" = "nvidia" ] && have nvidia-smi && HAS_NVSMI=1
if [ "$G_VEN" = "nvidia" ] && [ "$HAS_NVSMI" = "0" ]; then
    warn "nvidia-smi not found - install the NVIDIA driver for temp/util/power on this card"
fi
# iGPU: fall back to the CPU package sensor
if [ -z "$G_TEMP" ] && [ "$HAS_NVSMI" = "0" ]; then
    os_find_cpu_temp && { G_TEMP="$CPU_TEMP_PATH"; G_TEMP_LBL="CPU package (iGPU shares the die)"; }
fi

# ---------------------------------------------------------- sampling
gpu_sample() { # $1 temp  $2 util  $3 clk  $4 pwr  $5 hotspot  (sysfs sources)
    [ -n "$G_TEMP" ] && { v=$(rd "$G_TEMP"); [ -n "$v" ] && printf '%s\n' "$v" >> "$1"; }
    [ -n "$G_BUSY" ] && { v=$(rd "$G_BUSY"); [ -n "$v" ] && printf '%s\n' "$v" >> "$2"; }
    [ -n "$G_HOT" ] && [ -n "$5" ] && { v=$(rd "$G_HOT"); [ -n "$v" ] && printf '%s\n' "$v" >> "$5"; }
    if [ -n "$G_CLK" ]; then
        case "$G_CLK" in
            *pp_dpm_sclk)
                v=$(awk '/\*/ { gsub(/[^0-9]/, "", $2); print $2; exit }' "$G_CLK" 2>/dev/null) ;;
            *) v=$(rd "$G_CLK") ;;
        esac
        [ -n "$v" ] && printf '%s\n' "$v" >> "$3"
    fi
    if [ -n "$G_PWR" ]; then
        v=$(rd "$G_PWR")   # microwatts
        [ -n "$v" ] && awk -v u="$v" 'BEGIN{ printf "%d\n", u/1000 }' >> "$4"
    fi
}

monitor_gpu() { # endtime  temp  util  clk  pwr  hotspot  progress
    n=0
    while [ ! -f "$OS_TMP/stop" ]; do
        [ "$(date +%s)" -ge "$1" ] && break
        if [ "$HAS_NVSMI" = "1" ]; then
            nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,clocks.current.sm,power.draw \
                       --format=csv,noheader,nounits -i "$G_IDX" 2>/dev/null > "$OS_TMP/nv"
            awk -F', *' 'NR==1{ if ($1+0 > 0) printf "%d\n", $1*1000 }' "$OS_TMP/nv" >> "$2"
            awk -F', *' 'NR==1{ if ($2 ~ /^[0-9]/) printf "%d\n", $2 }' "$OS_TMP/nv" >> "$3"
            awk -F', *' 'NR==1{ if ($3 ~ /^[0-9]/) printf "%d\n", $3 }' "$OS_TMP/nv" >> "$4"
            awk -F', *' 'NR==1{ if ($4 ~ /^[0-9.]+$/) printf "%d\n", $4*1000 }' "$OS_TMP/nv" >> "$5"
        else
            gpu_sample "$2" "$3" "$4" "$5" "$6"
        fi
        n=$((n + 1))
        if [ "$7" = "1" ] && [ $((n % 5)) = 0 ]; then
            tc='-'; uc='-'; cc='-'; wc='-'
            v=$(tail -1 "$2" 2>/dev/null); [ -n "$v" ] && tc=$(awk -v x="$v" 'BEGIN{printf "%.1f C", x/1000}')
            v=$(tail -1 "$3" 2>/dev/null); [ -n "$v" ] && uc="$v%"
            v=$(tail -1 "$4" 2>/dev/null); [ -n "$v" ] && cc="$v MHz"
            v=$(tail -1 "$5" 2>/dev/null); [ -n "$v" ] && wc=$(awk -v x="$v" 'BEGIN{printf "%.1f W", x/1000}')
            printf '%s  [%3ds/%ds]  temp %-9s util %-6s clock %-10s power %s%s\n' \
                "$CD" "$((n * INTERVAL))" "$DURATION" "$tc" "$uc" "$cc" "$wc" "$CR"
        fi
        sleep "$INTERVAL"
    done
}

# ---------------------------------------------------------- load engine
[ -z "${DISPLAY:-}" ] && [ -e /tmp/.X11-unix/X0 ] && DISPLAY=:0 && export DISPLAY
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    for wd in /run/user/*/wayland-0; do
        [ -e "$wd" ] && { WAYLAND_DISPLAY=wayland-0; XDG_RUNTIME_DIR=${wd%/wayland-0}; export WAYLAND_DISPLAY XDG_RUNTIME_DIR; break; }
    done
fi

smoke() { # returns 0 if the command looks like it renders
    ( "$@" ) >/dev/null 2>&1 &
    _p=$!
    sleep 3
    if kill -0 "$_p" 2>/dev/null; then kill "$_p" 2>/dev/null; wait "$_p" 2>/dev/null; return 0; fi
    wait "$_p" 2>/dev/null
    return $?
}

ENGINE=''; ENGINE_DESC=''
try_engines() {
    if ensure_cmd stress-ng && smoke stress-ng --gpu 1 --timeout 2s; then
        ENGINE='stress-ng --gpu 1'; ENGINE_DESC='stress-ng --gpu (EGL/GBM)'; return 0
    fi
    for g in glmark2-es2-drm glmark2-drm; do
        if have "$g" || ensure_cmd "$g"; then
            if smoke "$g" --off-screen -b build; then
                ENGINE="$g --off-screen -b build:duration=10 -b texture:duration=10 -b shading:duration=10"
                ENGINE_DESC="$g (DRM, works on a bare console)"; return 0
            fi
        fi
    done
    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        for g in glmark2-es2-wayland glmark2-wayland glmark2-es2 glmark2; do
            if have "$g" || ensure_cmd "$g" glmark2; then
                if smoke "$g" -b build; then
                    ENGINE="$g -b build:duration=10 -b texture:duration=10 -b shading:duration=10"
                    ENGINE_DESC="$g (on the running desktop session)"; return 0
                fi
            fi
        done
        if ensure_cmd vkmark && smoke vkmark -b vertex; then
            ENGINE='vkmark -b vertex:device-local=true'; ENGINE_DESC='vkmark (Vulkan)'; return 0
        fi
    fi
    if ensure_cmd clpeak && smoke clpeak; then
        ENGINE='clpeak'; ENGINE_DESC='clpeak (OpenCL compute)'; return 0
    fi
    return 1
}

step "looking for a usable GPU load generator (this can take a moment)"
if ! try_engines; then
    ENGINE=''
    ENGINE_DESC='none available - MONITOR ONLY'
fi

LOAD_PIDS=''
stop_all() {
    touch "$OS_TMP/stop" 2>/dev/null
    [ -n "$LOAD_PIDS" ] && kill $LOAD_PIDS 2>/dev/null
    have pkill && pkill -P $$ 2>/dev/null
}
trap 'stop_all; os_cleanup; exit 130' INT
trap 'stop_all; os_cleanup; exit 143' TERM
trap 'stop_all; os_cleanup' EXIT

start_gpu_load() {
    [ -z "$ENGINE" ] && return 1
    _end="$1"
    ( while [ ! -f "$OS_TMP/stop" ]; do
          [ "$(date +%s)" -ge "$_end" ] && break
          # shellcheck disable=SC2086
          $ENGINE >> "$OS_TMP/engine.out" 2>&1 || break
      done ) &
    LOAD_PIDS="$!"
    return 0
}

# ======================================================================
#  plan
# ======================================================================
if [ "$HAS_NVSMI" = "1" ]; then
    src_temp='nvidia-smi'; src_util='nvidia-smi'
    src_clk='nvidia-smi';  src_pwr='nvidia-smi'
else
    src_temp="$(dv "$G_TEMP_LBL" 'no sensor')  $CD$(dv "$G_TEMP" '')$CR"
    src_util=$(dv "$G_BUSY" 'not exposed by this driver')
    src_clk=$(dv "$G_CLK" 'not exposed')
    src_pwr=$(dv "$G_PWR" 'not exposed')
fi

t_open "TEST PLAN"
t_row "Target GPU"     "#$G_IDX  $(pci_name "$G_BDF")"
t_row "Vendor/driver"  "$G_VEN / $G_DRV"
t_row "Duration"       "${DURATION}s  (+${BASELINE}s idle baseline)"
t_row "Load engine"    "$ENGINE_DESC"
t_row "Temp sensor"    "$src_temp"
t_row "Utilisation"    "$src_util"
t_row "Clock source"   "$src_clk"
t_row "Power source"   "$src_pwr"
t_end

if [ -z "$ENGINE" ]; then
    warn "no GPU load generator could be started - running in monitor-only mode."
    note "run your own load (a game, a benchmark, ollama, blender...) while this samples."
    note "on a bare console install:  apt-get install -y glmark2-drm   (or stress-ng)"
fi

# ======================================================================
#  idle baseline
# ======================================================================
hdr "IDLE BASELINE (${BASELINE}s)"
b_end=$(( $(date +%s) + BASELINE ))
while [ "$(date +%s)" -lt "$b_end" ]; do
    if [ "$HAS_NVSMI" = "1" ]; then
        nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,clocks.current.sm,power.draw \
                   --format=csv,noheader,nounits -i "$G_IDX" 2>/dev/null > "$OS_TMP/nv"
        awk -F', *' 'NR==1{ if ($1+0 > 0) printf "%d\n", $1*1000 }' "$OS_TMP/nv" >> "$BT_LOG"
        awk -F', *' 'NR==1{ if ($2 ~ /^[0-9]/) printf "%d\n", $2 }' "$OS_TMP/nv" >> "$BU_LOG"
        awk -F', *' 'NR==1{ if ($3 ~ /^[0-9]/) printf "%d\n", $3 }' "$OS_TMP/nv" >> "$BC_LOG"
        awk -F', *' 'NR==1{ if ($4 ~ /^[0-9.]+$/) printf "%d\n", $4*1000 }' "$OS_TMP/nv" >> "$BP_LOG"
    else
        gpu_sample "$BT_LOG" "$BU_LOG" "$BC_LOG" "$BP_LOG" "$BH_LOG"
    fi
    sleep "$INTERVAL"
done

t_head "IDLE" "METRIC" "MIN" "MAX" "AVG" "MEDIAN" "SAMPLES"
stats_row "Temperature" "$BT_LOG" 1000 "C" 1
[ -s "$BH_LOG" ] && stats_row "Hotspot / junction" "$BH_LOG" 1000 "C" 1
stats_row "Utilisation" "$BU_LOG" 1 "%" 0
stats_row "Clock" "$BC_LOG" 1 "MHz" 0
stats_row "Power" "$BP_LOG" 1000 "W" 1
t_end
idle_temp=$(stats_calc "$BT_LOG" 1000 1 | awk '{print $3}')

# ======================================================================
#  load run
# ======================================================================
hdr "LOAD RUN (${DURATION}s)"
l_end=$(( $(date +%s) + DURATION ))
start_gpu_load "$l_end" || true
monitor_gpu "$l_end" "$T_LOG" "$U_LOG" "$C_LOG" "$P_LOG" "$H_LOG" 1
touch "$OS_TMP/stop"
[ -n "$LOAD_PIDS" ] && kill $LOAD_PIDS 2>/dev/null
wait 2>/dev/null
rm -f "$OS_TMP/stop"

printf '\n'
t_head "UNDER LOAD" "METRIC" "MIN" "MAX" "AVG" "MEDIAN" "SAMPLES"
stats_row "Temperature" "$T_LOG" 1000 "C" 1
[ -s "$H_LOG" ] && stats_row "Hotspot / junction" "$H_LOG" 1000 "C" 1
stats_row "Utilisation" "$U_LOG" 1 "%" 0
stats_row "Clock" "$C_LOG" 1 "MHz" 0
stats_row "Power" "$P_LOG" 1000 "W" 1
t_end

# PCIe link under load (should climb to full width/speed when busy)
cs=$(rd "$G_DEV/current_link_speed"); cw=$(rd "$G_DEV/current_link_width")
ms=$(rd "$G_DEV/max_link_speed");     mw=$(rd "$G_DEV/max_link_width")

t_open "BEHAVIOUR"
t_row "Idle avg temp"   "$(dv "$idle_temp") C"
t_row "Load avg temp"   "$(stats_calc "$T_LOG" 1000 1 | awk '{print $3}') C"
t_row "Peak temp"       "$(stats_calc "$T_LOG" 1000 1 | awk '{print $2}') C"
t_row "Rise over idle"  "$(awk -v a="$idle_temp" -v b="$(stats_calc "$T_LOG" 1000 1 | awk '{print $2}')" 'BEGIN{ if(a=="-"||b=="-") print "-"; else printf "%+.1f C", b-a }')"
t_row "Peak power"      "$(stats_calc "$P_LOG" 1000 1 | awk '{print $2}') W"
t_row "Avg utilisation" "$(stats_calc "$U_LOG" 1 0 | awk '{print $3}') %"
t_row "PCIe link now"   "$(pcie_gen "$cs") x${cw:-?}  (max $(pcie_gen "$ms") x${mw:-?})"
if [ -r "$G_DEV/mem_info_vram_used" ]; then
    t_row "VRAM used"   "$(size_s "$(rd "$G_DEV/mem_info_vram_used")") of $(size_s "$(rd "$G_DEV/mem_info_vram_total")")"
fi
t_end

if [ -s "$T_LOG" ]; then
    hdr "TEMPERATURE TIMELINE"
    printf '  %s%s%s\n' "$CC" "$(sparkline "$T_LOG" $((OS_COLS - 12)))" "$CR"
    printf '  %s%s C .. %s C%s\n\n' "$CD" \
        "$(stats_calc "$T_LOG" 1000 1 | awk '{print $1}')" \
        "$(stats_calc "$T_LOG" 1000 1 | awk '{print $2}')" "$CR"
fi

# glmark2 / clpeak score if the engine printed one
if [ -s "$OS_TMP/engine.out" ]; then
    score=$(awk '/glmark2 Score|Score:/ { print; }' "$OS_TMP/engine.out" | tail -1)
    if [ -n "$score" ]; then
        t_open "ENGINE SCORE"
        t_row "$(trim "$score")"
        t_note "only comparable between identical engine versions and resolutions"
        t_end
    fi
fi

# ======================================================================
#  verdict
# ======================================================================
hdr "VERDICT"
peak=$(stats_calc "$T_LOG" 1000 0 | awk '{print $2}')
util=$(stats_calc "$U_LOG" 1 0 | awk '{print $3}')

t_open "ASSESSMENT"
if [ "$peak" = "-" ]; then
    t_row "Cooling" "${CY}no GPU temperature sensor available${CR}"
elif [ "$peak" -ge 95 ] 2>/dev/null; then
    t_row "Cooling" "${CE}peak ${peak} C - overheating, expect throttling / dead fans / old paste${CR}"
elif [ "$peak" -ge 85 ] 2>/dev/null; then
    t_row "Cooling" "${CY}peak ${peak} C - hot but within spec for most GPUs${CR}"
else
    t_row "Cooling" "${CG}peak ${peak} C - healthy${CR}"
fi
if [ -z "$ENGINE" ]; then
    t_row "Load" "${CY}monitor only - no load was generated, temperatures are not conclusive${CR}"
elif [ "$util" != "-" ] && [ "$util" -lt 50 ] 2>/dev/null; then
    t_row "Load" "${CY}average utilisation only ${util}% - the engine may not have hit the GPU hard${CR}"
else
    t_row "Load" "${CG}engine ran for ${DURATION}s ($ENGINE_DESC)${CR}"
fi
if [ -n "$cw" ] && [ -n "$mw" ] && [ "$cw" -lt "$mw" ] 2>/dev/null; then
    t_row "PCIe" "${CY}linked at x$cw of x$mw - reseat the card or check the slot${CR}"
else
    t_row "PCIe" "${CG}full width (x${cw:-?})${CR}"
fi
t_end
note "longer soak:  curl -fsSL $(os_url /gpu-load.sh) | sudo DURATION=900 sh"

os_footer
