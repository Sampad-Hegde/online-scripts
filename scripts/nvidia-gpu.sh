#!/bin/sh
# shellcheck shell=sh disable=SC2086,SC2012,SC3043
#@name        nvidia-gpu
#@title       NVIDIA GPU stress test
#@description NVIDIA only: full nvidia-smi telemetry, throttle-reason accounting, ECC / retired pages, XID scan
#@root        recommended
#@params      duration,interval,baseline,gpu,instances,vram
#@include _lib.sh

os_init "nvidia-gpu"

DURATION=${DURATION:-120}
INTERVAL=${INTERVAL:-1}
BASELINE=${BASELINE:-10}
GPU=${GPU:-0}
INSTANCES=${INSTANCES:-2}
LOAD_CMD=${LOAD_CMD:-}          # env only: your own burn command, e.g. "gpu_burn 600"
VRAM_TEST=${VRAM_TEST:-1}       # 0 disables the VRAM pattern test
VRAM_PCT=${VRAM_PCT:-70}        # share of *free* VRAM to test

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
case "$VRAM_PCT"  in ''|*[!0-9]*) VRAM_PCT=70 ;; esac
[ "$VRAM_PCT" -gt 90 ] && VRAM_PCT=90
[ "$VRAM_PCT" -lt 10 ] && VRAM_PCT=10
[ "$DURATION" -gt 7200 ] && DURATION=7200
[ "$DURATION" -lt 5 ] && DURATION=5
[ "$INSTANCES" -gt 8 ] && INSTANCES=8
[ "$INSTANCES" -lt 1 ] && INSTANCES=1

PCI_ROOT="$OS_SYSFS/bus/pci/devices"

LOGD="$OS_TMP/log"; mkdir -p "$LOGD"
BLOGD="$OS_TMP/base"; mkdir -p "$BLOGD"
for f in temp mtemp util clk mclk pwr fan mem pstate sysfan; do
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

# ---- hybrid graphics? on a laptop the display belongs to the iGPU, and a
# ---- graphics load will run there instead of on the NVIDIA chip
HYBRID=0
OTHER_GPU=''
IS_LAPTOP=0
case "$(rd "$OS_SYSFS/class/dmi/id/chassis_type")" in
    8|9|10|11|12|14|30|31|32) IS_LAPTOP=1 ;;
esac
for p in "$PCI_ROOT"/*; do
    [ -d "$p" ] || continue
    case "$(rd "$p/class")" in 0x0300*|0x0302*|0x0380*) ;; *) continue ;; esac
    v=$(rd "$p/vendor")
    [ "$v" = "0x10de" ] && continue
    HYBRID=1
    case "$v" in
        0x8086) OTHER_GPU="Intel" ;;
        0x1002|0x1022) OTHER_GPU="AMD" ;;
        *) OTHER_GPU="$v" ;;
    esac
done

G_BDF=$(head -1 "$OS_TMP/nvcards" | cut -f1)
RUNTIME_STATUS=$(rd "$PCI_ROOT/$G_BDF/power/runtime_status")
HAS_DRM_NODE=0
for c in "$PCI_ROOT/$G_BDF"/drm/card*; do
    case "$c" in *-*) continue ;; esac
    [ -d "$c" ] && HAS_DRM_NODE=1
done

# ---- fan: nvidia-smi reports [N/A] on almost every laptop, because the fan
# ---- hangs off the embedded controller. Fall back to a chassis fan sensor.
SYSFAN=''
SYSFAN_LABEL=''
if [ "$(nvn "$(nv_csv 'fan.speed')" '')" = "" ]; then
    os_try_sensor_modules >/dev/null 2>&1 || true
    for h in "$OS_SYSFS"/class/hwmon/hwmon*; do
        [ -d "$h" ] || continue
        for f in "$h"/fan*_input; do
            [ -r "$f" ] || continue
            fv=$(rd "$f")
            case "$fv" in ''|*[!0-9]*) continue ;; esac
            SYSFAN="$f"
            SYSFAN_LABEL="$(dv "$(rd "$h/name")" hwmon)/$(dv "$(rd "${f%_input}_label")" "$(basename "${f%_input}")")"
            break
        done
        [ -n "$SYSFAN" ] && break
    done
fi

if [ "$HYBRID" = "1" ] || [ -n "$RUNTIME_STATUS" ] || [ -n "$SYSFAN" ]; then
    t_open "LAPTOP / HYBRID GRAPHICS"
    if [ "$HYBRID" = "1" ]; then
        t_row "Hybrid graphics" "${CY}yes - an $OTHER_GPU GPU is also present (Optimus)${CR}"
        t_row "What that means" "OpenGL and Vulkan run on the $OTHER_GPU chip unless they are explicitly offloaded, which is how a graphics benchmark can leave this card at 0%. Compute loads (CUDA, OpenCL) always land here, so they are tried first, and whatever is picked is verified against this card's utilisation before the timed run starts."
    else
        t_row "Hybrid graphics" "no - this card drives the display"
    fi
    t_row "Chassis"         "$([ "$IS_LAPTOP" = 1 ] && echo 'laptop / portable' || echo 'desktop or server')"
    t_row "DRM node"        "$([ "$HAS_DRM_NODE" = 1 ] && echo present || echo 'none (render offload only)')"
    t_row "Runtime power"   "$(dv "$RUNTIME_STATUS" 'always on')"
    t_row "GPU fan sensor"  "$([ -n "$SYSFAN" ] && printf 'not on the GPU; using %s' "$SYSFAN_LABEL" || echo 'reported by nvidia-smi')"
    t_end
fi

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
t_note "'n/a' means the board has no ECC and cannot report memory faults - GeForce and the smaller Quadros (P400, P1000) are like this, so they need the pattern test below"
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
    if [ -n "$SYSFAN" ]; then
        _fv=$(rd "$SYSFAN")
        case "$_fv" in ''|*[!0-9]*) ;; *) printf '%s\n' "$_fv" >> "$1/sysfan" ;; esac
    fi
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
#
#  Order matters: a compute load (CUDA/OpenCL) always lands on this card,
#  while a graphics load lands on whichever GPU owns the display - which on
#  a hybrid laptop is the iGPU. Whatever is chosen, the load is started and
#  the card's utilisation is measured before the timed run begins, so a
#  test can never report "0% for ten minutes" again.
# ======================================================================
[ -z "${DISPLAY:-}" ] && [ -e /tmp/.X11-unix/X0 ] && DISPLAY=:0 && export DISPLAY
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    for wd in /run/user/*/wayland-0; do
        [ -e "$wd" ] && { WAYLAND_DISPLAY=wayland-0; XDG_RUNTIME_DIR=${wd%/wayland-0}
                          export WAYLAND_DISPLAY XDG_RUNTIME_DIR; break; }
    done
fi

# pin compute loads to the card under test
G_UUID=$(nvn "$(nv_f "$S1" 3)" '')
CUDA_PIN="CUDA_VISIBLE_DEVICES=${G_UUID:-$G_IDX}"

# force OpenGL/Vulkan/EGL onto the NVIDIA chip on a hybrid machine
GFX_ENV=''
if [ "$HYBRID" = "1" ]; then
    GFX_ENV="__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only"
    _egl=/usr/share/glvnd/egl_vendor.d/10_nvidia.json
    [ -r "$_egl" ] && GFX_ENV="$GFX_ENV __EGL_VENDOR_LIBRARY_FILENAMES=$_egl"
fi

# ------------------------------------------------------------- VRAM test
# nvidia-smi can only report VRAM faults on boards that have ECC. Consumer
# and small Quadro boards (P400, P1000, GTX/RTX) have none, so the only way
# to know is to write patterns into the memory and read them back - which is
# what this does, once cold and again while the card is hot.
VRAM_PROG=''
VRAM_TESTED=''
VRAM_ERR_COLD=''
VRAM_ERR_HOT=''
VRAM_DETAIL="$OS_TMP/vram.detail"

build_vram_test() {
    [ "$VRAM_TEST" = "1" ] || return 1
    have nvcc || return 1
    cat > "$OS_TMP/vramtest.cu" <<'VREOF'
// online-script VRAM pattern test.
// Fills most of the free memory, reads it back and counts mismatches.
// Passes: own-address, 0x55555555 + moving inversion, pseudo random.
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cuda_runtime.h>

__device__ __forceinline__ uint32_t want_of(size_t i, uint32_t pat, int mode) {
    if (mode == 0) return pat;
    if (mode == 1) return (uint32_t)i;
    return (uint32_t)(i * 2654435761u) ^ pat;
}

__global__ void fill(uint32_t *p, size_t n, uint32_t pat, int mode) {
    size_t stride = (size_t)gridDim.x * blockDim.x;
    for (size_t i = (size_t)blockIdx.x * blockDim.x + threadIdx.x; i < n; i += stride)
        p[i] = want_of(i, pat, mode);
}

// verify, then write the complement in place: the classic moving inversion
__global__ void check(uint32_t *p, size_t n, uint32_t pat, int mode, int invert,
                      unsigned long long *errs, unsigned long long *first, int maxfirst) {
    size_t stride = (size_t)gridDim.x * blockDim.x;
    for (size_t i = (size_t)blockIdx.x * blockDim.x + threadIdx.x; i < n; i += stride) {
        uint32_t w = want_of(i, pat, mode);
        uint32_t g = p[i];
        if (g != w) {
            unsigned long long k = atomicAdd(errs, 1ULL);
            if (k < (unsigned long long)maxfirst) first[k] = (unsigned long long)i;
        }
        if (invert) p[i] = ~w;
    }
}

// do_fill == 0 verifies what a previous pass left behind, which is what makes
// this a moving inversion rather than six unrelated write/read rounds.
static unsigned long long run_pass(uint32_t *buf, size_t n, const char *name,
                                   uint32_t pat, int mode, int do_fill, int invert,
                                   unsigned long long *d_errs, unsigned long long *d_first) {
    unsigned long long zero = 0, errs = 0;
    cudaMemcpy(d_errs, &zero, sizeof(zero), cudaMemcpyHostToDevice);
    if (do_fill) {
        fill<<<2048, 256>>>(buf, n, pat, mode);
        if (cudaDeviceSynchronize() != cudaSuccess) { printf("FAULT %s fill\n", name); return 1; }
    }
    check<<<2048, 256>>>(buf, n, pat, mode, invert, d_errs, d_first, 8);
    if (cudaDeviceSynchronize() != cudaSuccess) { printf("FAULT %s check\n", name); return 1; }
    cudaMemcpy(&errs, d_errs, sizeof(errs), cudaMemcpyDeviceToHost);
    printf("RESULT %s %llu\n", name, errs);
    if (errs) {
        unsigned long long f[8] = {0};
        cudaMemcpy(f, d_first, sizeof(f), cudaMemcpyDeviceToHost);
        int shown = (int)(errs < 8 ? errs : 8);
        for (int i = 0; i < shown; i++)
            printf("WORD %s %llu\n", name, f[i]);
    }
    return errs;
}

int main(int argc, char **argv) {
    int pct = (argc > 1) ? atoi(argv[1]) : 70;
    if (pct < 10 || pct > 95) pct = 70;
    size_t freeb = 0, totalb = 0;
    if (cudaMemGetInfo(&freeb, &totalb) != cudaSuccess) {
        fprintf(stderr, "cudaMemGetInfo failed\n");
        return 3;
    }
    size_t want = (size_t)((double)freeb * pct / 100.0);
    uint32_t *buf = 0;
    while (want >= (64u << 20)) {
        if (cudaMalloc((void **)&buf, want) == cudaSuccess) break;
        buf = 0;
        want /= 2;
    }
    if (!buf) { fprintf(stderr, "could not allocate VRAM\n"); return 3; }
    size_t n = want / sizeof(uint32_t);
    printf("TESTED %zu\n", want >> 20);

    unsigned long long *d_errs = 0, *d_first = 0;
    cudaMalloc((void **)&d_errs, sizeof(unsigned long long));
    cudaMalloc((void **)&d_first, 8 * sizeof(unsigned long long));

    unsigned long long total = 0;
    /*                            pattern       mode fill invert */
    total += run_pass(buf, n, "own-address",   0u,           1, 1, 0, d_errs, d_first);
    total += run_pass(buf, n, "0x55555555",    0x55555555u,  0, 1, 1, d_errs, d_first);
    total += run_pass(buf, n, "inverted-0xAA", 0xAAAAAAAAu,  0, 0, 1, d_errs, d_first);
    total += run_pass(buf, n, "inverted-0x55", 0x55555555u,  0, 0, 0, d_errs, d_first);
    total += run_pass(buf, n, "0xFFFFFFFF",    0xFFFFFFFFu,  0, 1, 0, d_errs, d_first);
    total += run_pass(buf, n, "0x00000000",    0x00000000u,  0, 1, 0, d_errs, d_first);
    total += run_pass(buf, n, "pseudo-random", 0x9E3779B9u,  2, 1, 0, d_errs, d_first);
    printf("TOTAL %llu\n", total);

    cudaFree(d_first);
    cudaFree(d_errs);
    cudaFree(buf);
    return total ? 1 : 0;
}
VREOF
    step "compiling the VRAM pattern test with nvcc"
    if nvcc -O2 -o "$OS_TMP/osvram" "$OS_TMP/vramtest.cu" >"$OS_TMP/nvccv.log" 2>&1 &&
       [ -x "$OS_TMP/osvram" ]; then
        VRAM_PROG="$OS_TMP/osvram"
        return 0
    fi
    warn "nvcc could not build the VRAM test"
    head -3 "$OS_TMP/nvccv.log" 2>/dev/null | while IFS= read -r l; do note "$l"; done
    return 1
}

run_vram_test() { # $1 = label (cold|hot)
    [ -n "$VRAM_PROG" ] || return 1
    _tmp="$OS_TMP/vram.$1"
    step "VRAM pattern test ($1) - writing and verifying ${VRAM_PCT}% of free memory"
    if have timeout; then
        env $CUDA_PIN timeout 600 "$VRAM_PROG" "$VRAM_PCT" > "$_tmp" 2>>"$OS_TMP/vram.err"
    else
        env $CUDA_PIN "$VRAM_PROG" "$VRAM_PCT" > "$_tmp" 2>>"$OS_TMP/vram.err"
    fi
    _rc=$?
    VRAM_TESTED=$(awk '/^TESTED /{print $2; exit}' "$_tmp")
    _tot=$(awk '/^TOTAL /{print $2; exit}' "$_tmp")
    [ -z "$_tot" ] && _tot='?'
    if grep -q '^FAULT ' "$_tmp"; then
        _tot="fault: $(awk '/^FAULT /{print $2" "$3; exit}' "$_tmp")"
    fi
    case "$1" in
        cold) VRAM_ERR_COLD="$_tot" ;;
        hot)  VRAM_ERR_HOT="$_tot" ;;
    esac
    awk -v lbl="$1" '/^RESULT /{ printf "%s\t%s\t%s\n", lbl, $2, $3 }' "$_tmp" >> "$VRAM_DETAIL"
    awk -v lbl="$1" '/^WORD /{ printf "%s\tword offset %s (pattern %s)\n", lbl, $3, $2 }' "$_tmp" \
        >> "$OS_TMP/vram.words"
    return "$_rc"
}

# ---------------------------------------------------------------- CUDA burn
# The toolkit is often already there on a machine that runs CUDA workloads;
# if nvcc exists we get the heaviest, most reliable load for free.
CUDA_BURN=''
build_cuda_burn() {
    have nvcc || return 1
    vram_mib=$(num_only "$(nv_f "$S1" 8)")
    buf=256
    [ -n "$vram_mib" ] && buf=$((vram_mib / 6))
    [ "$buf" -lt 64 ] && buf=64
    [ "$buf" -gt 1024 ] && buf=1024
    cat > "$OS_TMP/burn.cu" <<'CUEOF'
// online-script GPU burn: alternating FMA and memory-bandwidth kernels.
// Launches are kept short so the display driver watchdog never fires.
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <cuda_runtime.h>

__global__ void fma_burn(float *buf, int iters) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    float a = buf[i], m = 1.0000001f, s = 0.0f;
    for (int k = 0; k < iters; ++k) {
        a = fmaf(a, m, 0.5f);
        s = fmaf(s, m, a);
    }
    buf[i] = a + s * 1e-30f;
}

__global__ void mem_burn(float *dst, const float *src, size_t n) {
    size_t i = (size_t)blockIdx.x * blockDim.x + threadIdx.x;
    size_t stride = (size_t)gridDim.x * blockDim.x;
    for (; i < n; i += stride) dst[i] = src[i] * 1.000001f + 1.0f;
}

int main(int argc, char **argv) {
    int secs = (argc > 1) ? atoi(argv[1]) : 60;
    size_t mib = (argc > 2) ? (size_t)atoll(argv[2]) : 256;
    size_t n = mib * 1024u * 1024u / sizeof(float);
    float *a = 0, *b = 0;
    if (cudaMalloc((void **)&a, n * sizeof(float)) != cudaSuccess ||
        cudaMalloc((void **)&b, n * sizeof(float)) != cudaSuccess) {
        fprintf(stderr, "cudaMalloc failed\n");
        return 1;
    }
    cudaMemset(a, 1, n * sizeof(float));
    cudaMemset(b, 1, n * sizeof(float));
    time_t end = time(NULL) + secs;
    unsigned long long rounds = 0;
    while (time(NULL) < end) {
        fma_burn<<<1024, 256>>>(a, 2000);
        mem_burn<<<1024, 256>>>(b, a, n);
        if (cudaDeviceSynchronize() != cudaSuccess) {
            fprintf(stderr, "kernel failed\n");
            return 2;
        }
        ++rounds;
    }
    printf("burn rounds: %llu\n", rounds);
    cudaFree(a);
    cudaFree(b);
    return 0;
}
CUEOF
    step "compiling a CUDA burn kernel with nvcc (a few seconds)"
    if nvcc -O3 -o "$OS_TMP/osburn" "$OS_TMP/burn.cu" >"$OS_TMP/nvcc.log" 2>&1 &&
       [ -x "$OS_TMP/osburn" ]; then
        CUDA_BURN="$OS_TMP/osburn"
        CUDA_BURN_MIB="$buf"
        return 0
    fi
    warn "nvcc could not build the burn kernel (see below), falling back"
    head -3 "$OS_TMP/nvcc.log" 2>/dev/null | while IFS= read -r l; do note "$l"; done
    return 1
}

# ------------------------------------------------------- start / stop / verify
LOAD_PIDS=''
ENGINE=''; ENGINE_DESC=''; ENGINE_KIND=''; ENGINE_CLASS=''

stop_load() {
    touch "$OS_TMP/stop" 2>/dev/null
    [ -n "$LOAD_PIDS" ] && kill $LOAD_PIDS 2>/dev/null
    have pkill && pkill -P $$ 2>/dev/null
    sleep 1
    LOAD_PIDS=''
    rm -f "$OS_TMP/stop"
}
trap 'stop_load; os_cleanup; exit 130' INT
trap 'stop_load; os_cleanup; exit 143' TERM
trap 'stop_load; os_cleanup' EXIT

start_load() { # $1 = deadline epoch
    [ -z "$ENGINE" ] && return 1
    _end="$1"
    rm -f "$OS_TMP/stop"
    case "$ENGINE_KIND" in
        single) _copies=1 ;;
        *) _copies="$INSTANCES" ;;
    esac
    _n=1
    while [ "$_n" -le "$_copies" ]; do
        ( while [ ! -f "$OS_TMP/stop" ]; do
              [ "$(date +%s)" -ge "$_end" ] && break
              # shellcheck disable=SC2086
              env $ENGINE >> "$OS_TMP/engine.out" 2>&1 || break
          done ) &
        LOAD_PIDS="$LOAD_PIDS $!"
        _n=$((_n + 1))
    done
    return 0
}

# is the card actually busy? this is what was missing before
verify_load() {
    _sum=0; _n=0; _i=0
    while [ "$_i" -lt 8 ]; do
        _u=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits -i "$G_IDX" 2>/dev/null | tr -cd '0-9')
        case "$_u" in ''|*[!0-9]*) _u=0 ;; esac
        [ "$_u" -ge 30 ] && return 0
        _sum=$((_sum + _u)); _n=$((_n + 1))
        _i=$((_i + 1))
        sleep 1
    done
    [ "$_n" -gt 0 ] && [ $((_sum / _n)) -ge 10 ]
}

try_engine() { # kind class desc command...
    _k="$1"; _cl="$2"; _d="$3"; shift 3
    ENGINE_KIND="$_k"; ENGINE_CLASS="$_cl"; ENGINE_DESC="$_d"; ENGINE="$*"
    step "trying $_d"
    start_load "$(( $(date +%s) + 600 ))" || return 1
    if verify_load; then
        stop_load
        note "confirmed: this raised utilisation on GPU $G_IDX"
        return 0
    fi
    stop_load
    warn "$_d left GPU $G_IDX idle - not using it"
    ENGINE=''; ENGINE_DESC=''; ENGINE_CLASS=''
    return 1
}

pick_engine() {
    if [ -n "$LOAD_CMD" ]; then
        try_engine single compute "your LOAD_CMD: $LOAD_CMD" $CUDA_PIN $LOAD_CMD && return 0
    fi
    for b in gpu_burn gpu-burn; do
        have "$b" || continue
        try_engine single compute "$b (CUDA burn)" $CUDA_PIN "$b" "$DURATION" && return 0
    done
    if build_cuda_burn; then
        try_engine single compute "CUDA burn kernel, ${CUDA_BURN_MIB} MiB working set (nvcc built)" \
            $CUDA_PIN "$CUDA_BURN" "$DURATION" "$CUDA_BURN_MIB" && return 0
    fi
    if have clpeak || try_cmd clpeak; then
        try_engine multi compute "clpeak (OpenCL compute, x$INSTANCES)" $CUDA_PIN clpeak && return 0
    fi
    if try_cmd stress-ng; then
        try_engine single graphics "stress-ng --gpu (EGL/GBM)" \
            $GFX_ENV stress-ng --gpu "$INSTANCES" --timeout "${DURATION}s" && return 0
    fi
    for g in glmark2-es2-drm glmark2-drm; do
        have "$g" || try_cmd "$g" || continue
        try_engine multi graphics "$g at 1920x1080 (DRM console)" \
            $GFX_ENV "$g" --off-screen --size 1920x1080 \
            -b build -b texture -b shading -b bump -b refract && return 0
    done
    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        for g in glmark2-es2-wayland glmark2-wayland glmark2-es2 glmark2; do
            have "$g" || try_cmd "$g" glmark2 || continue
            try_engine multi graphics "$g at 1920x1080 on the desktop session" \
                $GFX_ENV "$g" --size 1920x1080 \
                -b build -b texture -b shading -b bump -b refract && return 0
        done
        if try_cmd vkmark; then
            try_engine multi graphics "vkmark (Vulkan)" \
                $GFX_ENV vkmark -b vertex:device-local=true -b texture -b shading && return 0
        fi
    fi
    return 1
}

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
[ -s "$BLOGD/fan" ] && stats_row "Fan" "$BLOGD/fan" 1 "%" 0
[ -s "$BLOGD/sysfan" ] && stats_row "Chassis fan"  "$BLOGD/sysfan" 1 "rpm" 0
t_end
idle_temp=$(stats_calc "$BLOGD/temp" 1000 1 | awk '{print $3}')
idle_pwr=$(stats_calc "$BLOGD/pwr" 1000 1 | awk '{print $3}')
idle_fan=$(stats_calc "$BLOGD/fan" 1 0 | awk '{print $3}')
idle_sysfan=$(stats_calc "$BLOGD/sysfan" 1 0 | awk '{print $3}')

# ======================================================================
#  7. find a load that really reaches this card
# ======================================================================
hdr "VRAM TEST (cold)"
if build_vram_test; then
    run_vram_test cold || true
    t_open "VRAM PATTERN TEST - COLD"
    t_row "Memory tested"  "$(dv "$VRAM_TESTED") MiB of $(nvn "$(nv_f "$S1" 8)") MiB installed  ${CD}(${VRAM_PCT}% of free)${CR}"
    t_row "Mismatched words" "$(if [ "$VRAM_ERR_COLD" = "0" ]; then printf '%s0%s' "$CG" "$CR"; else printf '%s%s%s' "$CE" "$VRAM_ERR_COLD" "$CR"; fi)"
    t_end
elif [ "$VRAM_TEST" = "1" ]; then
    warn "no VRAM test available: it needs nvcc (sudo apt-get install -y nvidia-cuda-toolkit)"
    note "without it, VRAM faults can only be seen if the board has ECC, or if the card"
    note "faults hard enough to log an XID during the stress run"
    note "standalone alternatives: cuda_memtest, or the memtest_vulkan single binary"
fi

hdr "LOAD GENERATOR"
pick_engine || { ENGINE=''; ENGINE_DESC='none reached this GPU - MONITOR ONLY'; }

t_open "TEST PLAN"
t_row "GPU"             "#$G_IDX  $GNAME"
t_row "Duration"        "${DURATION}s  (+${BASELINE}s idle baseline)"
t_row "Sample interval" "${INTERVAL}s"
t_row "Load engine"     "$ENGINE_DESC"
t_row "Throttle source" "$(case $THR_MODE in csv) echo 'nvidia-smi query fields' ;; text) echo 'nvidia-smi -q -d PERFORMANCE' ;; *) echo 'not supported by this driver' ;; esac)"
t_end

if [ -z "$ENGINE" ]; then
    warn "nothing available put load on this GPU - this run only monitors it."
    if [ "$HYBRID" = "1" ]; then
        note "this is a hybrid laptop, so graphics benchmarks land on the $OTHER_GPU chip."
        note "install a compute load, which always runs on the NVIDIA card:"
        note "  sudo apt-get install -y nvidia-cuda-toolkit   # gives nvcc; the script then"
        note "                                               # builds its own burn kernel"
        note "  sudo apt-get install -y clpeak                # smaller, OpenCL only"
    else
        note "install one of:  nvidia-cuda-toolkit (nvcc), clpeak, glmark2-drm, stress-ng"
    fi
    note "or run your own load (a game, a benchmark, ollama, blender) while this samples,"
    note "or point the script at your own burn:  LOAD_CMD='gpu_burn 600' ... | sudo sh"
fi



# ======================================================================
#  8. load run
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
        if [ -n "$fc" ]; then fanstr="fan ${fc}%"
        else
            fc=$(tail -1 "$LOGD/sysfan" 2>/dev/null)
            if [ -n "$fc" ]; then fanstr="fan ${fc} rpm"; else fanstr="fan n/a"; fi
        fi
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
        printf '%s  [%4ds/%ds]  %s C  util %s%%  %s MHz  %s W  %s%s%s\n' \
            "$CD" "$((n * INTERVAL))" "$DURATION" \
            "$(awk -v v="${tc:-0}" 'BEGIN{printf "%.0f", v/1000}')" "${uc:--}" \
            "${cc:--}" "$(awk -v v="${wc:-0}" 'BEGIN{printf "%.0f", v/1000}')" "$fanstr" \
            "$CY$flags" "$CR"
    fi
    sleep "$INTERVAL"
done
touch "$OS_TMP/stop"
[ -n "$LOAD_PIDS" ] && kill $LOAD_PIDS 2>/dev/null
wait 2>/dev/null
rm -f "$OS_TMP/stop"

hot_now=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits -i "$G_IDX" 2>/dev/null | tr -cd '0-9')

printf '\n'
if [ -n "$VRAM_PROG" ]; then
    hdr "VRAM TEST (hot - straight after the soak, at ${hot_now:-?} C)"
    run_vram_test hot || true
    t_open "VRAM PATTERN TEST - HOT"
    t_row "Core temperature" "${hot_now:-?} C"
    t_row "Memory tested"    "$(dv "$VRAM_TESTED") MiB"
    t_row "Mismatched words" "$(if [ "$VRAM_ERR_HOT" = "0" ]; then printf '%s0%s' "$CG" "$CR"; else printf '%s%s%s' "$CE" "$VRAM_ERR_HOT" "$CR"; fi)"
    t_note "marginal VRAM usually passes cold and fails hot, which is why this runs twice"
    t_end

    if [ -s "$VRAM_DETAIL" ]; then
        t_head "VRAM TEST DETAIL" "RUN" "PATTERN" "MISMATCHES"
        while IFS="$TAB" read -r a b c; do t_row "$a" "$b" "$c"; done < "$VRAM_DETAIL"
        t_end
    fi
    if [ -s "$OS_TMP/vram.words" ]; then
        t_head "FIRST FAILING ADDRESSES" "RUN" "LOCATION"
        head -16 "$OS_TMP/vram.words" | while IFS="$TAB" read -r a b; do t_row "$a" "$b"; done
        t_end
    fi
fi

t_head "UNDER LOAD" "METRIC" "MIN" "MAX" "AVG" "MEDIAN" "SAMPLES"
stats_row "Core temperature" "$LOGD/temp" 1000 "C" 1
[ -s "$LOGD/mtemp" ] && stats_row "Memory temperature" "$LOGD/mtemp" 1000 "C" 1
stats_row "Utilisation"      "$LOGD/util" 1 "%" 0
stats_row "SM clock"         "$LOGD/clk" 1 "MHz" 0
stats_row "Memory clock"     "$LOGD/mclk" 1 "MHz" 0
stats_row "Power draw"       "$LOGD/pwr" 1000 "W" 1
[ -s "$LOGD/fan" ] && stats_row "Fan speed" "$LOGD/fan" 1 "%" 0
[ -s "$LOGD/sysfan" ] && stats_row "Chassis fan ($SYSFAN_LABEL)" "$LOGD/sysfan" 1 "rpm" 0
stats_row "VRAM used"        "$LOGD/mem" 1 "MiB" 0
t_end

peak_temp=$(stats_calc "$LOGD/temp" 1000 0 | awk '{print $2}')
avg_temp=$(stats_calc "$LOGD/temp" 1000 1 | awk '{print $3}')
peak_pwr=$(stats_calc "$LOGD/pwr" 1000 0 | awk '{print $2}')
avg_util=$(stats_calc "$LOGD/util" 1 0 | awk '{print $3}')
peak_fan=$(stats_calc "$LOGD/fan" 1 0 | awk '{print $2}')
peak_sysfan=$(stats_calc "$LOGD/sysfan" 1 0 | awk '{print $2}')
avg_clk=$(stats_calc "$LOGD/clk" 1 0 | awk '{print $3}')
max_clk_seen=$(stats_calc "$LOGD/clk" 1 0 | awk '{print $2}')
min_clk=$(stats_calc "$LOGD/clk" 1 0 | awk '{print $1}')
nsamp=$(stats_calc "$LOGD/temp" 1000 0 | awk '{print $5}')

# ======================================================================
#  9. throttle accounting  - the reason this script exists
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
if [ -s "$LOGD/sysfan" ]; then
    t_row "Idle -> load fan" "$(dv "$idle_sysfan") rpm  ->  peak $peak_sysfan rpm  $CD($SYSFAN_LABEL)$CR"
else
    t_row "Idle -> load fan" "$(dv "$idle_fan") %  ->  peak $peak_fan %"
fi
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
#  10. faults logged during the run
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
#  11. verdict
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

# --- fan.  nvidia-smi reports [N/A] on laptops (the EC owns the fan), so a
# --- chassis sensor is used instead and judged on whether it ramped up.
if [ "$peak_fan" != "-" ]; then
    if [ "$peak_fan" = "0" ] && [ "$peak_temp" != "-" ] && [ "$peak_temp" -ge 55 ] 2>/dev/null; then
        t_row "Fan" "${CE}fan never spun up while the core hit ${peak_temp} C - dead fan or unplugged${CR}"
    elif [ "$peak_fan" -ge 95 ] 2>/dev/null && [ "$peak_temp" -ge 80 ] 2>/dev/null; then
        t_row "Fan" "${CY}fan at ${peak_fan}% and still ${peak_temp} C - cooler is past its best${CR}"
    else
        t_row "Fan" "${CG}ramped to ${peak_fan}%${CR}"
    fi
elif [ -s "$LOGD/sysfan" ]; then
    if [ "$idle_sysfan" != "-" ] && [ "$peak_sysfan" != "-" ] && \
       [ "$(awk -v a="$idle_sysfan" -v b="$peak_sysfan" 'BEGIN{ print (b > a + 200) ? 1 : 0 }')" = "1" ]; then
        t_row "Fan" "${CG}chassis fan ramped ${idle_sysfan} -> ${peak_sysfan} rpm ($SYSFAN_LABEL)${CR}"
    elif [ "$peak_sysfan" = "0" ] && [ "$peak_temp" != "-" ] && [ "$peak_temp" -ge 60 ] 2>/dev/null; then
        t_row "Fan" "${CE}chassis fan reads 0 rpm at ${peak_temp} C - dead or clogged fan${CR}"
    else
        t_row "Fan" "${CY}chassis fan barely moved (${idle_sysfan} -> ${peak_sysfan} rpm) - check the vents${CR}"
    fi
else
    t_row "Fan" "${CD}no fan sensor: on laptops the fan is driven by the embedded controller, and${CR}"
    t_row ""    "${CD}on datacenter boards the chassis does the cooling - judge on temperature${CR}"
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
    t_row "Load quality" "${CE}no load reached this GPU - the thermal result proves nothing${CR}"
    if [ "$HYBRID" = "1" ]; then
        t_row "" "${CY}hybrid laptop: install the CUDA toolkit (nvcc) or clpeak, which run on the${CR}"
        t_row "" "${CY}NVIDIA chip directly:  sudo apt-get install -y nvidia-cuda-toolkit clpeak${CR}"
    fi
elif [ "$avg_util" != "-" ] && [ "$avg_util" -lt 50 ] 2>/dev/null; then
    t_row "Load quality" "${CY}average utilisation only ${avg_util}% - the engine barely touched the GPU${CR}"
elif [ -n "$PWR_LIMIT" ] && [ "$peak_pwr" != "-" ] && \
     [ "$(awk -v p="$peak_pwr" -v l="$PWR_LIMIT" 'BEGIN{ print (l+0>0 && p*100/l < 60) ? 1 : 0 }')" = "1" ]; then
    if [ "$ENGINE_CLASS" = "graphics" ]; then
        t_row "Load quality" "${CY}${avg_util}% busy but only ${peak_pwr} W of ${PWR_LIMIT} W - a graphics load; a CUDA or OpenCL burn would push harder${CR}"
    else
        t_row "Load quality" "${CY}${avg_util}% busy at only ${peak_pwr} W of ${PWR_LIMIT} W - the card is power limited or downclocked$([ "$IS_LAPTOP" = 1 ] && printf ', which laptops usually are')${CR}"
    fi
else
    t_row "Load quality" "${CG}${avg_util}% busy, peak ${peak_pwr} W$([ -n "$PWR_LIMIT" ] && printf ' of %s W' "$PWR_LIMIT") ($ENGINE_CLASS load)${CR}"
fi

# --- memory.  "[N/A]" means the board cannot report faults, which is NOT the
# --- same as reporting none: small Quadros and all GeForce boards have no ECC.
mem_bad=0
mem_reportable=0
for v in "$(nv_f "$E1" 2)" "$(nv_f "$R1" 2)" "$(nv_f "$R1" 3)"; do
    case "$v" in
        ''|'[N/A]'|'[Not Supported]') ;;
        0) mem_reportable=1 ;;
        *) mem_reportable=1; mem_bad=1 ;;
    esac
done

if [ -n "$VRAM_ERR_COLD$VRAM_ERR_HOT" ]; then
    if [ "$VRAM_ERR_COLD" = "0" ] && [ "$VRAM_ERR_HOT" = "0" ]; then
        t_row "VRAM test" "${CG}${VRAM_TESTED} MiB verified cold and hot, zero mismatched words${CR}"
    elif [ "$VRAM_ERR_COLD" = "0" ]; then
        t_row "VRAM test" "${CE}clean cold but $VRAM_ERR_HOT mismatch(es) hot - marginal memory, walk away${CR}"
    else
        t_row "VRAM test" "${CE}$VRAM_ERR_COLD mismatch(es) cold / $VRAM_ERR_HOT hot - the memory is bad${CR}"
    fi
elif [ "$VRAM_TEST" = "1" ]; then
    t_row "VRAM test" "${CY}not run - install nvidia-cuda-toolkit (nvcc) to pattern-test the memory${CR}"
fi

if [ "$mem_bad" = "1" ]; then
    t_row "VRAM counters" "${CE}the card reports retired pages or uncorrected ECC errors - failing memory${CR}"
elif [ "$mem_reportable" = "1" ]; then
    t_row "VRAM counters" "${CG}ECC/retired-page counters are all zero${CR}"
else
    t_row "VRAM counters" "${CD}this board has no ECC, so it cannot report VRAM faults at all - the pattern test is the only evidence about its memory${CR}"
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
    if [ "$IS_LAPTOP" = "1" ]; then
        t_row "PCIe" "${CD}linked at x$cw of x$mw - normal for a soldered mobile GPU, nothing to reseat${CR}"
    else
        t_row "PCIe" "${CY}linked at x$cw of x$mw - reseat the card or check the slot${CR}"
    fi
else
    t_row "PCIe" "${CG}full width (x${cw:-?})${CR}"
fi
t_end

note "longer soak:  curl -fsSL $(os_url /nvidia-gpu.sh) | sudo DURATION=1800 sh"
note "heaviest load: build gpu-burn, then  LOAD_CMD='gpu_burn 1800' ... | sudo sh"

os_footer
