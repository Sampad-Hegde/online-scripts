#!/bin/sh
# Integration test: run cpu-load.sh and gpu-load.sh against a fake /sys tree
# with sensors that move, then assert the report says what it should.
# Must run on Linux (the scripts read /proc too).  Needs rendered scripts:
#     python -m app.render --out build/rendered
#     sh tests/fake_hw_run.sh build/rendered
S=${1:-build/rendered}
DUR=${DUR:-10}
BASE=${BASE:-3}
FAILED=0
F=$(mktemp -d)
trap 'rm -rf "$F"; kill $SIM $NVSIM 2>/dev/null' EXIT

for f in "$S/cpu-load.sh" "$S/gpu-load.sh" "$S/nvidia-gpu.sh"; do
    [ -r "$f" ] || { echo "missing $f - run 'python -m app.render' first"; exit 2; }
done

want() { # description needle file
    if grep -q -- "$2" "$3"; then
        printf '  ok    %s\n' "$1"
    else
        printf '  FAIL  %s  (no match for [%s])\n' "$1" "$2"
        FAILED=$((FAILED + 1))
    fi
}
wantnot() { # $2 is an extended regexp
    if grep -qE -- "$2" "$3"; then
        printf '  FAIL  %s  (unexpected [%s])\n' "$1" "$2"
        FAILED=$((FAILED + 1))
    else
        printf '  ok    %s\n' "$1"
    fi
}

# ---------------------------------------------------------------- fake CPU
mkdir -p "$F/class/hwmon/hwmon0" \
         "$F/devices/system/cpu/cpu0/cpufreq" "$F/devices/system/cpu/cpu1/cpufreq" \
         "$F/devices/system/cpu/cpu0/thermal_throttle" \
         "$F/class/powercap/intel-rapl:0"
echo coretemp        > "$F/class/hwmon/hwmon0/name"
echo 'Package id 0'  > "$F/class/hwmon/hwmon0/temp1_label"
echo 100000          > "$F/class/hwmon/hwmon0/temp1_crit"
echo 35000           > "$F/class/hwmon/hwmon0/temp1_input"
echo 3600000         > "$F/devices/system/cpu/cpu0/cpufreq/base_frequency"
echo 5000000         > "$F/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq"
echo 800000          > "$F/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
echo 800000          > "$F/devices/system/cpu/cpu1/cpufreq/scaling_cur_freq"
echo 0               > "$F/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count"
echo 1000000         > "$F/class/powercap/intel-rapl:0/energy_uj"

# ---------------------------------------------------------------- fake GPU
B="$F/bus/pci/devices/0000:03:00.0"
mkdir -p "$B/hwmon/hwmon3" "$F/class/drm/card0" "$F/driver/amdgpu"
echo 0x030000          > "$B/class"
echo 0x1002            > "$B/vendor"
echo 0x73df            > "$B/device"
echo '8.0 GT/s PCIe'   > "$B/current_link_speed"
echo 8                 > "$B/current_link_width"
echo '16.0 GT/s PCIe'  > "$B/max_link_speed"
echo 16                > "$B/max_link_width"
echo 12884901888       > "$B/mem_info_vram_total"
echo 2147483648        > "$B/mem_info_vram_used"
echo 0                 > "$B/gpu_busy_percent"
echo amdgpu            > "$B/hwmon/hwmon3/name"
echo edge              > "$B/hwmon/hwmon3/temp1_label"
echo 40000             > "$B/hwmon/hwmon3/temp1_input"
echo junction          > "$B/hwmon/hwmon3/temp2_label"
echo 43000             > "$B/hwmon/hwmon3/temp2_input"
echo 15000000          > "$B/hwmon/hwmon3/power1_average"
printf '0: 500Mhz\n1: 1200Mhz\n2: 2450Mhz *\n' > "$B/pp_dpm_sclk"
ln -sfn "$F/driver/amdgpu" "$B/driver"

# ------------------------------------------------- sensors that move in time
simulate() {
    t=35000; f=800000; e=1000000; gt=40000; gj=43000; n=0
    while [ "$n" -lt 300 ]; do
        n=$((n + 1))
        if [ "$n" -gt "$BASE" ]; then
            t=$((t + 12000)); [ "$t" -gt 100000 ] && t=100000
            f=4900000
            [ "$t" -ge 100000 ] && f=3200000           # thermal throttle
            [ "$t" -ge 100000 ] && echo $((n / 4)) > "$F/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count"
            e=$((e + 95000000))                        # 95 W
            gt=$((gt + 3000)); [ "$gt" -gt 78000 ] && gt=78000
            gj=$((gj + 4000)); [ "$gj" -gt 95000 ] && gj=95000
            echo 96 > "$B/gpu_busy_percent"
            echo 240000000 > "$B/hwmon/hwmon3/power1_average"
        else
            e=$((e + 12000000))                        # 12 W idle
        fi
        echo "$t" > "$F/class/hwmon/hwmon0/temp1_input"
        echo "$f" > "$F/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
        echo $((f - 100000)) > "$F/devices/system/cpu/cpu1/cpufreq/scaling_cur_freq"
        echo "$e" > "$F/class/powercap/intel-rapl:0/energy_uj"
        echo "$gt" > "$B/hwmon/hwmon3/temp1_input"
        echo "$gj" > "$B/hwmon/hwmon3/temp2_input"
        sleep 1
    done
}
simulate & SIM=$!

echo "== cpu-load.sh against a CPU that overheats and throttles"
OS_SYSFS="$F" NO_INSTALL=1 NO_COLOR=1 PLAIN=1 DURATION="$DUR" BASELINE="$BASE" \
    sh "$S/cpu-load.sh" > "$F/cpu.out" 2> "$F/cpu.err"
rc=$?
check_empty() {
    if [ -s "$1" ]; then
        printf '  FAIL  %s wrote to stderr:\n' "$2"; sed 's/^/        /' "$1"
        FAILED=$((FAILED + 1))
    else
        printf '  ok    %s stderr is empty\n' "$2"
    fi
}
[ "$rc" = "0" ] && printf '  ok    cpu-load exit code 0\n' || {
    printf '  FAIL  cpu-load exit code %s\n' "$rc"; FAILED=$((FAILED + 1)); }
check_empty "$F/cpu.err" cpu-load
want "reports the package sensor"   'coretemp/Package id 0' "$F/cpu.out"
want "reports the thermal limit"    '100 C'                 "$F/cpu.out"
want "reports rated clocks"         'base 3.60 GHz / max 5.00 GHz' "$F/cpu.out"
want "compares sustained clock"     'rated 3.60 GHz base clock' "$F/cpu.out"
want "samples the temperature"      '100.0 C'               "$F/cpu.out"
want "reads RAPL power"             '95.0 W'                "$F/cpu.out"
want "detects the thermal limit"    'reached the 100 C limit' "$F/cpu.out"
want "counts throttle events"       'thermal throttle event' "$F/cpu.out"
want "prints a timeline"            'TEMPERATURE TIMELINE'  "$F/cpu.out"
want "prints heat soak"             'Heat soak'             "$F/cpu.out"
wantnot "no unexpanded placeholder" '@@[A-Z_]+@@'           "$F/cpu.out"

echo "== gpu-load.sh against an AMD card on a downgraded PCIe link"
OS_SYSFS="$F" NO_INSTALL=1 NO_COLOR=1 PLAIN=1 DURATION="$DUR" BASELINE="$BASE" \
    sh "$S/gpu-load.sh" > "$F/gpu.out" 2> "$F/gpu.err"
rc=$?
[ "$rc" = "0" ] && printf '  ok    gpu-load exit code 0\n' || {
    printf '  FAIL  gpu-load exit code %s\n' "$rc"; FAILED=$((FAILED + 1)); }
check_empty "$F/gpu.err" gpu-load
want "finds the AMD card"          'amd'            "$F/gpu.out"
want "reads VRAM size"             '12.0 GiB'       "$F/gpu.out"
want "reads the edge sensor"       '78.0 C'         "$F/gpu.out"
want "reads the junction sensor"   'Hotspot'        "$F/gpu.out"
want "reads utilisation"           '96 %'           "$F/gpu.out"
want "parses pp_dpm_sclk"          '2450 MHz'       "$F/gpu.out"
want "reads power draw"            '240.0 W'        "$F/gpu.out"
want "flags the narrow PCIe link"  'linked at x8 of x16' "$F/gpu.out"
want "notes monitor-only mode"     'monitor only'   "$F/gpu.out"
wantnot "no unexpanded placeholder" '@@[A-Z_]+@@'   "$F/gpu.out"

# ======================================================================
#  nvidia-gpu.sh against a fake nvidia-smi
# ======================================================================
echo "== nvidia-gpu.sh against a card that thermally throttles"
HERE=$(dirname "$0")
if [ ! -x "$HERE/fake-nvidia-smi" ]; then
    echo "  SKIP  $HERE/fake-nvidia-smi not found"
else
    mkdir -p "$F/bin"
    cp "$HERE/fake-nvidia-smi" "$F/bin/nvidia-smi"
    chmod +x "$F/bin/nvidia-smi"

    NV="$F/bus/pci/devices/0000:03:00.0"
    mkdir -p "$NV" "$F/driver/nvidia"
    echo 0x10de   > "$NV/vendor"
    echo 0x030000 > "$NV/class"
    echo 0x2484   > "$NV/device"
    ln -sfn "$F/driver/nvidia" "$NV/driver"

    NVSTATE="$F/nv.state"
    echo 'temp=38 util=0 fan=31 ps=P8' > "$NVSTATE"
    # idle for the baseline, then hot and thermally throttled for the load run
    ( sleep $((BASE + 3))
      echo 'temp=91 util=98 sm=1350 mclk=7000 pwr=198.4 fan=99 ps=P0 mem=3288 pcap=1 hwsd=1 hwth=1 genc=4 widc=8' \
          > "$NVSTATE" ) &
    NVSIM=$!

    PATH="$F/bin:$PATH" OS_SYSFS="$F" FAKE_NV_STATE="$NVSTATE" \
        NO_INSTALL=1 NO_COLOR=1 PLAIN=1 COLS=110 DURATION="$DUR" BASELINE="$BASE" \
        sh "$S/nvidia-gpu.sh" > "$F/nv.out" 2> "$F/nv.err"
    rc=$?
    kill $NVSIM 2>/dev/null

    [ "$rc" = "0" ] && printf '  ok    nvidia-gpu exit code 0\n' || {
        printf '  FAIL  nvidia-gpu exit code %s\n' "$rc"; FAILED=$((FAILED + 1)); }
    check_empty "$F/nv.err" nvidia-gpu
    want "finds the card on the bus"     '0000:03:00.0'         "$F/nv.out"
    want "reads the model"               'NVIDIA GeForce RTX 3070' "$F/nv.out"
    want "reads the VBIOS"               '94.04.3F.00.6E'       "$F/nv.out"
    want "reads the driver version"      '550.90.07'            "$F/nv.out"
    want "reads the power limit"         '220.00 W enforced'    "$F/nv.out"
    want "rounds the limit for maths"    'of 220 W limit'       "$F/nv.out"
    want "reads the slowdown threshold"  '95 C'                 "$F/nv.out"
    want "reads the target temperature"  '83 C'                 "$F/nv.out"
    want "samples the hot temperature"   '91.0 C'               "$F/nv.out"
    want "samples the fan"               '99 %'                 "$F/nv.out"
    want "samples the clock drop"        '1350 MHz'             "$F/nv.out"
    want "accounts throttle reasons"     'SHARE OF SAMPLES'     "$F/nv.out"
    want "flags thermal slowdown"        'HW thermal slowdown'  "$F/nv.out"
    want "verdict names the throttle"    'thermal slowdown in'  "$F/nv.out"
    want "verdict judges against VBIOS limits" 'above the 83 C target' "$F/nv.out"
    want "flags the narrow PCIe link"    'linked at x8 of x16'  "$F/nv.out"
    # this fake board has no ECC, so the report must say it cannot know rather
    # than claiming the memory is fine
    want "does not fake VRAM health"     'cannot report VRAM faults' "$F/nv.out"
    wantnot "no false all-clear"         'counters are all zero'     "$F/nv.out"
    want "reports XID state"             'no XID errors'        "$F/nv.out"
    want "reports pstate"                'P0'                   "$F/nv.out"
    wantnot "no unexpanded placeholder"  '@@[A-Z_]+@@'          "$F/nv.out"
    wantnot "no mangled power figure"    'of 22000 W'           "$F/nv.out"
    wantnot "no unknown query field"     'FAKE_UNKNOWN_FIELD'   "$F/nv.err"

    # ---- same card, healthy: power capped but cool. guards the green paths
    echo "== nvidia-gpu.sh against a healthy card (power capped, cool)"
    echo 'temp=38 util=0 fan=31 ps=P8' > "$NVSTATE"
    ( sleep $((BASE + 3))
      echo 'temp=71 util=99 sm=1905 mclk=7000 pwr=218.6 fan=64 ps=P0 mem=3288 pcap=1 genc=4 widc=16' \
          > "$NVSTATE" ) &
    NVSIM=$!
    PATH="$F/bin:$PATH" OS_SYSFS="$F" FAKE_NV_STATE="$NVSTATE" \
        NO_INSTALL=1 NO_COLOR=1 PLAIN=1 COLS=110 DURATION="$DUR" BASELINE="$BASE" \
        sh "$S/nvidia-gpu.sh" > "$F/nv2.out" 2> "$F/nv2.err"
    rc=$?
    kill $NVSIM 2>/dev/null
    [ "$rc" = "0" ] && printf '  ok    nvidia-gpu exit code 0\n' || {
        printf '  FAIL  nvidia-gpu exit code %s\n' "$rc"; FAILED=$((FAILED + 1)); }
    check_empty "$F/nv2.err" nvidia-gpu
    want "cooling called healthy"      'peak 71 C - healthy'        "$F/nv2.out"
    want "fan ramp accepted"           'ramped to 64%'              "$F/nv2.out"
    want "power cap called normal"     'no thermal throttling - normal' "$F/nv2.out"
    want "full width PCIe accepted"    'full width (x16)'           "$F/nv2.out"
    want "power headroom reported"     'of 220 W limit (100%)'      "$F/nv2.out"
    wantnot "no thermal verdict"       'cooler cannot keep up'      "$F/nv2.out"
    wantnot "no dead fan verdict"      'never spun up'              "$F/nv2.out"

    # ---- hybrid laptop: a graphics load that never reaches the dGPU must be
    # ---- detected and rejected instead of being timed at 0%
    echo "== nvidia-gpu.sh on a hybrid laptop where the load misses the dGPU"
    IG="$F/bus/pci/devices/0000:00:02.0"
    mkdir -p "$IG" "$F/driver/i915" "$F/class/dmi/id" "$F/class/hwmon/hwmon9"
    echo 0x8086   > "$IG/vendor"
    echo 0x030000 > "$IG/class"
    ln -sfn "$F/driver/i915" "$IG/driver"
    echo 10 > "$F/class/dmi/id/chassis_type"          # notebook
    echo dell_smm       > "$F/class/hwmon/hwmon9/name"
    echo "Processor Fan" > "$F/class/hwmon/hwmon9/fan1_label"
    echo 2600           > "$F/class/hwmon/hwmon9/fan1_input"
    # the GPU fan is [N/A] like every laptop
    sed -i 's|^        fan.speed) echo .*|        fan.speed) echo "[N/A]" ;;|' "$F/bin/nvidia-smi"
    # a load generator that exists but leaves the NVIDIA chip idle
    printf '#!/bin/sh\nsleep 60\n' > "$F/bin/glmark2-es2-drm"
    chmod +x "$F/bin/glmark2-es2-drm"
    echo 'temp=42 util=0 sm=139 mclk=405 pwr=6.5 ps=P8 mem=3' > "$NVSTATE"

    PATH="$F/bin:$PATH" OS_SYSFS="$F" FAKE_NV_STATE="$NVSTATE" \
        NO_INSTALL=1 NO_COLOR=1 PLAIN=1 COLS=110 DURATION=6 BASELINE=2 \
        sh "$S/nvidia-gpu.sh" > "$F/nv3.out" 2> "$F/nv3.err"
    rc=$?
    [ "$rc" = "0" ] && printf '  ok    nvidia-gpu exit code 0\n' || {
        printf '  FAIL  nvidia-gpu exit code %s\n' "$rc"; FAILED=$((FAILED + 1)); }
    check_empty "$F/nv3.err" nvidia-gpu
    want "detects hybrid graphics"     'an Intel GPU is also present' "$F/nv3.out"
    want "detects the laptop chassis"  'laptop / portable'            "$F/nv3.out"
    want "falls back to a chassis fan" 'dell_smm/Processor Fan'       "$F/nv3.out"
    want "rejects the useless engine"  'left GPU 0 idle'              "$F/nv3.out"
    want "says no load reached it"     'no load reached this GPU'     "$F/nv3.out"
    want "suggests a compute load"     'nvidia-cuda-toolkit'          "$F/nv3.out"
    want "no reseat advice on a laptop" 'nothing to reseat'           "$F/nv3.out"
    wantnot "does not claim a stress test" 'engine ran for'           "$F/nv3.out"

    # ---- same laptop, but nvcc is available: build a burn and confirm it lands
    echo "== nvidia-gpu.sh building its own CUDA burn when nvcc exists"
    cat > "$F/bin/nvcc" <<'NVCCEOF'
#!/bin/sh
# stand-in for the CUDA compiler: builds either the burn or the VRAM tester.
# FAKE_VRAM_HOT_ERRS makes the hot VRAM pass report failures.
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
[ -n "$out" ] || exit 1
case "$out" in
    *osvram)
        cat > "$out" <<INNER
#!/bin/sh
echo "TESTED 1408"
if [ -f "\$HOTFLAG" ] && [ -n "\$FAKE_VRAM_HOT_ERRS" ]; then
    echo "RESULT own-address 0"
    echo "RESULT 0x55555555 \$FAKE_VRAM_HOT_ERRS"
    echo "WORD 0x55555555 184320119"
    echo "RESULT inverted-0xAA 0"
    echo "RESULT inverted-0x55 0"
    echo "RESULT 0xFFFFFFFF 0"
    echo "RESULT 0x00000000 0"
    echo "RESULT pseudo-random 0"
    echo "TOTAL \$FAKE_VRAM_HOT_ERRS"
    exit 1
fi
for p in own-address 0x55555555 inverted-0xAA inverted-0x55 0xFFFFFFFF 0x00000000 pseudo-random; do
    echo "RESULT \$p 0"
done
echo "TOTAL 0"
INNER
        ;;
    *)
        cat > "$out" <<INNER
#!/bin/sh
echo 'temp=81 util=99 sm=1670 mclk=3500 pwr=71.2 fan=[N/A] ps=P0 mem=680 pcap=1' > "\$FAKE_NV_STATE"
touch "\$HOTFLAG"
sleep \${1:-60}
INNER
        ;;
esac
chmod +x "$out"
NVCCEOF
    chmod +x "$F/bin/nvcc"
    # a mobile 1050 Ti-class power limit, so 71 W is a real full load
    sed -i 's|^        power.limit) echo .*|        power.limit) echo 75.00 ;;|' "$F/bin/nvidia-smi"
    sed -i 's|^        enforced.power.limit) echo .*|        enforced.power.limit) echo 75.00 ;;|' "$F/bin/nvidia-smi"
    echo 'temp=42 util=0 sm=139 mclk=405 pwr=6.5 ps=P8 mem=3' > "$NVSTATE"
    rm -f "$F/hot"
    PATH="$F/bin:$PATH" OS_SYSFS="$F" FAKE_NV_STATE="$NVSTATE" HOTFLAG="$F/hot" \
        NO_INSTALL=1 NO_COLOR=1 PLAIN=1 COLS=110 DURATION=8 BASELINE=2 \
        sh "$S/nvidia-gpu.sh" > "$F/nv4.out" 2> "$F/nv4.err"
    rc=$?
    [ "$rc" = "0" ] && printf '  ok    nvidia-gpu exit code 0\n' || {
        printf '  FAIL  nvidia-gpu exit code %s\n' "$rc"; FAILED=$((FAILED + 1)); }
    check_empty "$F/nv4.err" nvidia-gpu
    want "compiles a burn kernel"      'CUDA burn kernel'          "$F/nv4.out"
    want "verifies the load landed"    'raised utilisation on GPU' "$F/nv4.out"
    want "credits a compute load"       'compute load'             "$F/nv4.out"
    want "reports the fan ramp"         'rpm'                      "$F/nv4.out"
    wantnot "does not blame a graphics load" 'a graphics load'      "$F/nv4.out"
    # the timed table must hold the boosted clock, not the idle 139 MHz
    awk '/UNDER LOAD/ { f = 1 } f { print } f && /^[+].*[+]$/ && ++b == 3 { exit }' \
        "$F/nv4.out" > "$F/nv4.load"
    want "timed table has the boosted clock" '1670 MHz' "$F/nv4.load"
    want "timed table has real utilisation"  '99 %'     "$F/nv4.load"
    wantnot "timed table has no idle clock"  '139 MHz'  "$F/nv4.load"
    want "runs a cold VRAM test"       'VRAM PATTERN TEST - COLD'  "$F/nv4.out"
    want "runs a hot VRAM test"        'VRAM PATTERN TEST - HOT'   "$F/nv4.out"
    want "tests most of the memory"    '1408 MiB'                  "$F/nv4.out"
    want "lists every pattern"         'pseudo-random'             "$F/nv4.out"
    want "does moving inversions"      'inverted-0xAA'             "$F/nv4.out"
    want "clean memory verdict"        'verified cold and hot'     "$F/nv4.out"
    want "explains missing ECC"        'cannot report VRAM faults' "$F/nv4.out"

    # ---- and the case that matters for a used card: clean cold, bad hot
    echo "== nvidia-gpu.sh with VRAM that only fails once hot"
    echo 'temp=42 util=0 sm=139 mclk=405 pwr=6.5 ps=P8 mem=3' > "$NVSTATE"
    rm -f "$F/hot"
    PATH="$F/bin:$PATH" OS_SYSFS="$F" FAKE_NV_STATE="$NVSTATE" HOTFLAG="$F/hot" \
        FAKE_VRAM_HOT_ERRS=3 \
        NO_INSTALL=1 NO_COLOR=1 PLAIN=1 COLS=110 DURATION=6 BASELINE=2 \
        sh "$S/nvidia-gpu.sh" > "$F/nv5.out" 2> "$F/nv5.err"
    rc=$?
    [ "$rc" = "0" ] && printf '  ok    nvidia-gpu exit code 0\n' || {
        printf '  FAIL  nvidia-gpu exit code %s\n' "$rc"; FAILED=$((FAILED + 1)); }
    check_empty "$F/nv5.err" nvidia-gpu
    want "cold pass reported clean"    'VRAM PATTERN TEST - COLD'  "$F/nv5.out"
    want "hot mismatches counted"      'Mismatched words  3'       "$F/nv5.out"
    want "failing address listed"      '184320119'                 "$F/nv5.out"
    want "verdict says walk away"      'marginal memory, walk away' "$F/nv5.out"
    wantnot "not called clean"         'verified cold and hot'     "$F/nv5.out"
fi

# every rendered table row must line up
echo "== table alignment in real output"
for f in "$F/cpu.out" "$F/gpu.out" "$F/nv.out" "$F/nv2.out" "$F/nv3.out" \
         "$F/nv4.out" "$F/nv5.out"; do
    bad=$(awk '
        /^[+|]/ {
            if (block == 0) { block = 1; w = length($0) }
            else if (length($0) != w) { print FILENAME ": " NR; bad = 1 }
            next
        }
        { block = 0 }
        END { }' "$f")
    if [ -n "$bad" ]; then
        printf '  FAIL  misaligned rows in %s: %s\n' "$f" "$bad"
        FAILED=$((FAILED + 1))
    else
        printf '  ok    %s tables aligned\n' "$(basename "$f")"
    fi
done

printf '\n'
if [ "$FAILED" = "0" ]; then
    echo "fake hardware run: all checks passed"
    exit 0
fi
printf '%s check(s) FAILED\n' "$FAILED"
exit 1
