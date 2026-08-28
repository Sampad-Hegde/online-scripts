#!/bin/sh
# shellcheck shell=sh disable=SC2086,SC2012,SC3043
#@name        cpu-load
#@title       CPU load + thermal test
#@description Pegs every thread, samples temperature / clock / power, reports min-max-avg-median
#@root        recommended
#@params      duration,threads,interval,baseline
#@include _lib.sh

os_init "cpu-load"

# ------------------------------------------------------------- settings
DURATION=${DURATION:-60}
THREADS=${THREADS:-0}
INTERVAL=${INTERVAL:-1}
BASELINE=${BASELINE:-8}

while [ $# -gt 0 ]; do
    case "$1" in
        --duration|-d) DURATION="$2"; shift 2 ;;
        --threads|-t)  THREADS="$2"; shift 2 ;;
        --interval|-i) INTERVAL="$2"; shift 2 ;;
        --baseline|-b) BASELINE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

NPROC=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
[ "$THREADS" = "0" ] && THREADS="$NPROC"

case "$DURATION" in ''|*[!0-9]*) DURATION=60 ;; esac
case "$THREADS"  in ''|*[!0-9]*) THREADS="$NPROC" ;; esac
[ "$DURATION" -gt 3600 ] && DURATION=3600
[ "$DURATION" -lt 5 ] && DURATION=5

TEMP_LOG="$OS_TMP/temp.log"
FREQ_LOG="$OS_TMP/freq.log"
PWR_LOG="$OS_TMP/pwr.log"
BASE_LOG="$OS_TMP/base.log"
: > "$TEMP_LOG"; : > "$FREQ_LOG"; : > "$PWR_LOG"; : > "$BASE_LOG"

os_find_cpu_temp || warn "no CPU temperature sensor found - thermal stats will be empty"
os_find_rapl || true

# rated clocks, so the sustained figure can be compared against them
CPUFREQ="$OS_SYSFS/devices/system/cpu/cpu0/cpufreq"
BASE_KHZ=$(rd "$CPUFREQ/base_frequency")
MAX_KHZ=$(rd "$CPUFREQ/cpuinfo_max_freq")
khz_ghz() { [ -n "$1" ] && awk -v k="$1" 'BEGIN{ printf "%.2f GHz", k/1000000 }'; }

TJMAX=''
if [ -n "$CPU_TEMP_PATH" ]; then
    for s in crit max; do
        f="${CPU_TEMP_PATH%_input}_$s"
        [ -r "$f" ] && { TJMAX=$(rd "$f"); break; }
    done
fi

LOAD_PIDS=''
MON_PID=''
stop_all() {
    touch "$OS_TMP/stop" 2>/dev/null
    [ -n "$LOAD_PIDS" ] && kill $LOAD_PIDS 2>/dev/null
    [ -n "$MON_PID" ] && kill $MON_PID 2>/dev/null
    have pkill && pkill -P $$ 2>/dev/null
}
trap 'stop_all; os_cleanup; exit 130' INT
trap 'stop_all; os_cleanup; exit 143' TERM
trap 'stop_all; os_cleanup' EXIT

# ------------------------------------------------------------- sampling
sample_once() { # $1 = temp log, $2 = freq log, $3 = pwr log
    t=$(cpu_temp_mc); [ -n "$t" ] && printf '%s\n' "$t" >> "$1"
    f=$(cpu_freq_khz); [ -n "$f" ] && printf '%s\n' "$f" >> "$2"
    if [ -n "$RAPL_PATH" ]; then
        e=$(rapl_uj)
        if [ -n "$e" ] && [ -n "$PREV_UJ" ]; then
            d=$((e - PREV_UJ))
            if [ "$d" -ge 0 ]; then
                # milliwatts = uJ / interval_seconds / 1000
                awk -v d="$d" -v i="$INTERVAL" 'BEGIN{ printf "%d\n", d/i/1000 }' >> "$3"
            fi
        fi
        PREV_UJ="$e"
    fi
}

monitor() { # $1 endtime  $2 templog  $3 freqlog  $4 pwrlog  $5 show-progress
    PREV_UJ=''
    n=0
    while [ ! -f "$OS_TMP/stop" ]; do
        now=$(date +%s)
        [ "$now" -ge "$1" ] && break
        sample_once "$2" "$3" "$4"
        n=$((n + 1))
        if [ "$5" = "1" ] && [ $((n % 5)) = 0 ]; then
            tc='-'; fc='-'; wc='-'
            tl=$(tail -1 "$2" 2>/dev/null); [ -n "$tl" ] && tc=$(awk -v v="$tl" 'BEGIN{printf "%.1f C", v/1000}')
            fl=$(tail -1 "$3" 2>/dev/null); [ -n "$fl" ] && fc=$(awk -v v="$fl" 'BEGIN{printf "%.2f GHz", v/1000000}')
            wl=$(tail -1 "$4" 2>/dev/null); [ -n "$wl" ] && wc=$(awk -v v="$wl" 'BEGIN{printf "%.1f W", v/1000}')
            printf '%s  [%3ds/%ds]  temp %-10s clock %-11s package %s%s\n' \
                "$CD" "$((n * INTERVAL))" "$DURATION" "$tc" "$fc" "$wc" "$CR"
        fi
        sleep "$INTERVAL"
    done
}

# ------------------------------------------------------------ load engine
ENGINE=''
ENGINE_DESC=''
if ensure_cmd stress-ng; then
    ENGINE=stress-ng
    ENGINE_DESC="stress-ng --cpu $THREADS (heaviest, uses vector units)"
elif have openssl; then
    ENGINE=openssl
    ENGINE_DESC="openssl speed -multi $THREADS (AES/SHA load)"
else
    ENGINE='awk'
    ENGINE_DESC="pure awk busy loops x $THREADS (lightest - install stress-ng for a real burn-in)"
fi

start_load() {
    end="$1"
    case "$ENGINE" in
        stress-ng)
            ( stress-ng --cpu "$THREADS" --timeout "${DURATION}s" --metrics-brief \
                > "$OS_TMP/stress.out" 2>&1 ) &
            LOAD_PIDS="$!"
            ;;
        openssl)
            i=0
            while [ "$i" -lt "$THREADS" ]; do
                ( while [ ! -f "$OS_TMP/stop" ]; do
                      [ "$(date +%s)" -ge "$end" ] && break
                      openssl speed -seconds 2 -evp aes-256-cbc >/dev/null 2>&1 || \
                          openssl speed -seconds 2 aes-256-cbc >/dev/null 2>&1 || break
                  done ) &
                LOAD_PIDS="$LOAD_PIDS $!"
                i=$((i + 1))
            done
            ;;
        awk)
            i=0
            while [ "$i" -lt "$THREADS" ]; do
                ( while [ ! -f "$OS_TMP/stop" ]; do
                      [ "$(date +%s)" -ge "$end" ] && break
                      awk 'BEGIN{s=0; for(j=0;j<1500000;j++) s += sqrt(j) + j%7; exit}'
                  done ) &
                LOAD_PIDS="$LOAD_PIDS $!"
                i=$((i + 1))
            done
            ;;
    esac
}

# ======================================================================
#  plan
# ======================================================================
t_open "TEST PLAN"
t_row "CPU"            "$(dv "$(awk -F: '/^model name/{sub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo | sed -e 's/(R)//g' -e 's/(TM)//g')")"
t_row "Logical CPUs"   "$NPROC"
t_row "Load threads"   "$THREADS"
t_row "Duration"       "${DURATION}s  (+${BASELINE}s idle baseline)"
t_row "Sample interval" "${INTERVAL}s"
t_row "Load engine"    "$ENGINE_DESC"
t_row "Rated clocks"   "base $(dv "$(khz_ghz "$BASE_KHZ")") / max $(dv "$(khz_ghz "$MAX_KHZ")")"
t_row "Temp sensor"    "$(dv "$CPU_TEMP_LABEL" 'none')"
t_row "Thermal limit"  "$([ -n "$TJMAX" ] && awk -v t="$TJMAX" 'BEGIN{printf "%.0f C", t/1000}' || echo '-')"
t_row "Package power"  "$([ -n "$RAPL_PATH" ] && echo "RAPL ($RAPL_PATH)" || echo 'not available')"
t_end

# ======================================================================
#  1. idle baseline
# ======================================================================
hdr "IDLE BASELINE (${BASELINE}s)"
b_end=$(( $(date +%s) + BASELINE ))
PREV_UJ=''
while [ "$(date +%s)" -lt "$b_end" ]; do
    sample_once "$BASE_LOG" "$OS_TMP/bfreq.log" "$OS_TMP/bpwr.log"
    sleep "$INTERVAL"
done
idle_temp=$(stats_calc "$BASE_LOG" 1000 1 | awk '{print $3}')
idle_freq=$(stats_calc "$OS_TMP/bfreq.log" 1000000 2 | awk '{print $3}')
idle_pwr=$(stats_calc "$OS_TMP/bpwr.log" 1000 1 | awk '{print $3}')

t_head "IDLE" "METRIC" "MIN" "MAX" "AVG" "MEDIAN" "SAMPLES"
stats_row "Temperature" "$BASE_LOG" 1000 "C" 1
stats_row "Clock" "$OS_TMP/bfreq.log" 1000000 "GHz" 2
[ -s "$OS_TMP/bpwr.log" ] && stats_row "Package power" "$OS_TMP/bpwr.log" 1000 "W" 1
t_end

# ======================================================================
#  2. load run
# ======================================================================
hdr "LOAD RUN (${DURATION}s, $THREADS threads)"

thr_before=$(cpu_throttle_count)
l_end=$(( $(date +%s) + DURATION ))
start_load "$l_end"
monitor "$l_end" "$TEMP_LOG" "$FREQ_LOG" "$PWR_LOG" 1
touch "$OS_TMP/stop"
[ -n "$LOAD_PIDS" ] && kill $LOAD_PIDS 2>/dev/null
wait 2>/dev/null
thr_after=$(cpu_throttle_count)
thr_delta=$((thr_after - thr_before))
rm -f "$OS_TMP/stop"

printf '\n'
t_head "UNDER LOAD" "METRIC" "MIN" "MAX" "AVG" "MEDIAN" "SAMPLES"
stats_row "Temperature" "$TEMP_LOG" 1000 "C" 1
stats_row "Clock (all-core avg)" "$FREQ_LOG" 1000000 "GHz" 2
[ -s "$PWR_LOG" ] && stats_row "Package power" "$PWR_LOG" 1000 "W" 1
t_end

# heat soak: first quarter vs last quarter of the samples
soak='-'
if [ -s "$TEMP_LOG" ]; then
    soak=$(awk '{a[++n]=$1} END{
        if (n < 8) { print "-"; exit }
        q = int(n/4); s1=0; s2=0
        for (i=1;i<=q;i++) s1 += a[i]
        for (i=n-q+1;i<=n;i++) s2 += a[i]
        printf "%.1f C -> %.1f C  (drift %+.1f C)", s1/q/1000, s2/q/1000, (s2/q - s1/q)/1000
    }' "$TEMP_LOG")
fi

t_open "THERMAL BEHAVIOUR"
t_row "Idle avg temp"      "$(dv "$idle_temp") C"
t_row "Load avg temp"      "$(stats_calc "$TEMP_LOG" 1000 1 | awk '{print $3}') C"
t_row "Peak temp"          "$(stats_calc "$TEMP_LOG" 1000 1 | awk '{print $2}') C"
t_row "Rise over idle"     "$(awk -v a="$idle_temp" -v b="$(stats_calc "$TEMP_LOG" 1000 1 | awk '{print $2}')" 'BEGIN{ if(a=="-"||b=="-"){print "-"} else printf "%+.1f C", b-a }')"
t_row "Heat soak (1st vs last quarter)" "$soak"
t_row "Idle avg clock"     "$(dv "$idle_freq") GHz"
t_row "Load avg clock"     "$(stats_calc "$FREQ_LOG" 1000000 2 | awk '{print $3}') GHz"
t_row "Throttle events"    "$thr_delta $CD(core_throttle_count delta)$CR"
[ -s "$PWR_LOG" ] && t_row "Idle / load power" "$(dv "$idle_pwr") W  ->  $(stats_calc "$PWR_LOG" 1000 1 | awk '{print $3}') W"
t_end

# ------------------------------------------------------------- timeline
if [ -s "$TEMP_LOG" ]; then
    hdr "TEMPERATURE TIMELINE"
    tmin=$(stats_calc "$TEMP_LOG" 1000 1 | awk '{print $1}')
    tmax=$(stats_calc "$TEMP_LOG" 1000 1 | awk '{print $2}')
    printf '  %s%s%s\n' "$CC" "$(sparkline "$TEMP_LOG" $((OS_COLS - 12)))" "$CR"
    printf '  %s%s C (low) .. %s C (high), left = start of load%s\n\n' "$CD" "$tmin" "$tmax" "$CR"
fi

if [ -s "$FREQ_LOG" ]; then
    hdr "CLOCK TIMELINE"
    fmin=$(stats_calc "$FREQ_LOG" 1000000 2 | awk '{print $1}')
    fmax=$(stats_calc "$FREQ_LOG" 1000000 2 | awk '{print $2}')
    printf '  %s%s%s\n' "$CC" "$(sparkline "$FREQ_LOG" $((OS_COLS - 12)))" "$CR"
    printf '  %s%s GHz (low) .. %s GHz (high)%s\n\n' "$CD" "$fmin" "$fmax" "$CR"
fi

# ------------------------------------------------------------ throughput
if [ "$ENGINE" = "stress-ng" ] && [ -s "$OS_TMP/stress.out" ]; then
    bogo=$(awk '{ for (i=1;i<=NF;i++) if ($i=="cpu" && (i+5)<=NF) { print $(i+1) "\t" $(i+5); exit } }' "$OS_TMP/stress.out")
    if [ -n "$bogo" ]; then
        t_open "THROUGHPUT (stress-ng)"
        t_row "Bogo ops"       "$(printf '%s' "$bogo" | cut -f1)"
        t_row "Bogo ops/s"     "$(printf '%s' "$bogo" | cut -f2)"
        t_note "compare the same figure between machines only with identical stress-ng versions"
        t_end
    fi
fi

# ======================================================================
#  verdict
# ======================================================================
hdr "VERDICT"
peak=$(stats_calc "$TEMP_LOG" 1000 0 | awk '{print $2}')
avgclk=$(stats_calc "$FREQ_LOG" 1000000 2 | awk '{print $3}')
tj='-'
[ -n "$TJMAX" ] && tj=$(awk -v t="$TJMAX" 'BEGIN{printf "%.0f", t/1000}')

t_open "ASSESSMENT"
if [ "$peak" = "-" ]; then
    t_row "Cooling" "${CY}unknown - no temperature sensor${CR}"
else
    if [ "$tj" != "-" ] && [ "$peak" -ge "$tj" ] 2>/dev/null; then
        t_row "Cooling" "${CE}peak ${peak} C reached the ${tj} C limit - throttling / bad cooler / dry paste${CR}"
    elif [ "$peak" -ge 95 ] 2>/dev/null; then
        t_row "Cooling" "${CE}peak ${peak} C - too hot for sustained load${CR}"
    elif [ "$peak" -ge 85 ] 2>/dev/null; then
        t_row "Cooling" "${CY}peak ${peak} C - warm, expect throttling in a hot room${CR}"
    else
        t_row "Cooling" "${CG}peak ${peak} C - healthy${CR}"
    fi
fi
if [ "$thr_delta" -gt 0 ] 2>/dev/null; then
    t_row "Throttling" "${CE}$thr_delta thermal throttle event(s) during the run${CR}"
else
    t_row "Throttling" "${CG}none reported by the kernel${CR}"
fi
if [ -n "$BASE_KHZ" ] && [ "$avgclk" != "-" ]; then
    verdict_clk=$(awk -v a="$avgclk" -v b="$BASE_KHZ" 'BEGIN{
        pc = a * 1000000 / b * 100
        printf "%.0f%% of the rated %.2f GHz base clock", pc, b/1000000 }')
    below=$(awk -v a="$avgclk" -v b="$BASE_KHZ" 'BEGIN{ print (a*1000000 < b*0.95) ? 1 : 0 }')
    if [ "$below" = "1" ]; then
        t_row "Sustained all-core clock" "${CY}$avgclk GHz - $verdict_clk${CR}"
    else
        t_row "Sustained all-core clock" "${CG}$avgclk GHz - $verdict_clk${CR}"
    fi
else
    t_row "Sustained all-core clock" "$avgclk GHz"
fi
nt=$(stats_calc "$TEMP_LOG" 1000 1 | awk '{print $5}')
nf=$(stats_calc "$FREQ_LOG" 1000000 2 | awk '{print $5}')
t_row "Stability" "${CG}completed ${DURATION}s of load${CR}  ${CD}($nt temperature / $nf clock samples)${CR}"
if [ "$nt" = "0" ]; then
    t_note "no temperature samples: this machine exposes no CPU sensor, so only the clock and throughput figures are meaningful"
fi
t_end
note "for a real burn-in run 15-30 min:  curl -fsSL $(os_url /cpu-load.sh) | sudo DURATION=1800 sh"

os_footer
