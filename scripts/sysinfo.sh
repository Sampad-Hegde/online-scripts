#!/bin/sh
# shellcheck shell=sh disable=SC2086,SC2012,SC3043
#@name        sysinfo
#@title       Hardware inventory
#@description CPU, memory modules, motherboard/BIOS, storage, network, PCIe links, GPU
#@root        recommended
#@params      spd
#@include _lib.sh

os_init "sysinfo"

# ======================================================================
#  helpers
# ======================================================================
DMI=/sys/class/dmi/id
HAS_DMIDECODE=0
if [ "$OS_ROOT" = "1" ] && ensure_cmd dmidecode; then HAS_DMIDECODE=1; fi

# dmi_fields <type> "Key1|Key2|..."  -> one tab separated line per record
dmi_fields() {
    [ "$HAS_DMIDECODE" = "1" ] || return 1
    $SUDO dmidecode -t "$1" 2>/dev/null | awk -v keys="$2" '
    function flush() {
        if (inr && got) {
            out = ""
            for (i=1; i<=nk; i++) out = out (i>1 ? "\t" : "") V[K[i]]
            print out
        }
        inr = 0; got = 0; delete V
    }
    BEGIN { nk = split(keys, K, "|") }
    /^Handle / { flush(); inr = 1; next }
    inr && /^[ \t]/ {
        line = $0
        sub(/^[ \t]+/, "", line)
        p = index(line, ": ")
        if (p > 0) { V[substr(line, 1, p-1)] = substr(line, p+2); got = 1 }
    }
    END { flush() }'
}

chassis_name() {
    case "$1" in
        3) echo Desktop ;; 4) echo "Low profile desktop" ;; 5) echo "Pizza box" ;;
        6) echo "Mini tower" ;; 7) echo Tower ;; 8) echo Portable ;; 9) echo Laptop ;;
        10) echo Notebook ;; 11) echo "Hand held" ;; 12) echo "Docking station" ;;
        13) echo "All-in-one" ;; 14) echo "Sub notebook" ;; 15) echo "Space saving" ;;
        16) echo "Lunch box" ;; 17) echo "Main server chassis" ;; 18) echo "Expansion chassis" ;;
        22) echo "RAID chassis" ;; 23) echo "Rack mount chassis" ;; 24) echo "Sealed-case PC" ;;
        28) echo Blade ;; 30) echo Tablet ;; 31) echo Convertible ;; 32) echo Detachable ;;
        35) echo "Mini PC" ;; 36) echo "Stick PC" ;; '') echo "-" ;; *) echo "type $1" ;;
    esac
}

# ======================================================================
#  1. SYSTEM / FIRMWARE
# ======================================================================
hdr "SYSTEM"

fw="Legacy BIOS (CSM)"
[ -d /sys/firmware/efi ] && fw="UEFI"

sb="-"
if [ "$OS_ROOT" = "1" ] && have mokutil; then
    sb=$($SUDO mokutil --sb-state 2>/dev/null | head -1)
fi
if [ "$sb" = "-" ]; then
    sbf=$(ls /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | head -1)
    if [ -n "$sbf" ] && have od; then
        sbv=$(od -An -tu1 "$sbf" 2>/dev/null | awk 'NR==1{print $5}')
        case "$sbv" in 1) sb="SecureBoot enabled" ;; 0) sb="SecureBoot disabled" ;; esac
    fi
fi

tpm="not present"
if [ -d /sys/class/tpm/tpm0 ]; then
    tv=$(rd /sys/class/tpm/tpm0/tpm_version_major)
    [ -z "$tv" ] && tv="1.2?"
    tpm="present (TPM $tv)"
fi

virt="none (bare metal)"
if have systemd-detect-virt; then
    v=$(systemd-detect-virt 2>/dev/null)
    [ -n "$v" ] && [ "$v" != "none" ] && virt="$v"
elif grep -qm1 '^flags.* hypervisor' /proc/cpuinfo 2>/dev/null; then
    virt="hypervisor flag set"
fi

up=$(awk '{d=int($1/86400); h=int(($1%86400)/3600); m=int(($1%3600)/60); if(d) printf "%dd %dh %dm\n", d,h,m; else printf "%dh %dm\n", h,m}' /proc/uptime 2>/dev/null)

product=$(trim "$(rd $DMI/product_name) $(rd $DMI/product_version)")

t_open "SYSTEM"
t_row "Manufacturer"   "$(dv "$(rd $DMI/sys_vendor)")"
t_row "Product"        "$(dv "$product")"
t_row "Family"         "$(dv "$(rd $DMI/product_family)")"
t_row "Serial"         "$(dv "$(rd $DMI/product_serial)" 'hidden (needs root)')"
t_row "Chassis"        "$(chassis_name "$(rd $DMI/chassis_type)")"
t_row "BIOS / firmware" "$(dv "$(rd $DMI/bios_vendor)") $(dv "$(rd $DMI/bios_version)")  [$(dv "$(rd $DMI/bios_date)")]"
t_row "Boot mode"      "$fw"
t_row "Secure Boot"    "$(dv "$sb")"
t_row "TPM"            "$tpm"
t_row "Virtualisation" "$virt"
t_row "OS / kernel"    "$DISTRO_NAME  |  $(uname -r) $(uname -m)"
t_row "Uptime"         "$(dv "$up")"
t_end

# ======================================================================
#  2. PROCESSOR
# ======================================================================
hdr "PROCESSOR"

LSCPU="$OS_TMP/lscpu"
if ensure_cmd lscpu; then lscpu > "$LSCPU" 2>/dev/null; else : > "$LSCPU"; fi
lsc() {
    awk -v k="$1" '{
        p = index($0, ":")
        if (p < 1) next
        key = substr($0, 1, p-1)
        sub(/[ \t]+$/, "", key)
        if (key == k) { v = substr($0, p+1); sub(/^[ \t]+/, "", v); print v; exit }
    }' "$LSCPU"
}

model=$(lsc 'Model name')
[ -z "$model" ] && model=$(awk -F: '/^model name/{sub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo)
[ -z "$model" ] && model=$(awk -F: '/^Model|^Hardware|^Processor/{sub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo)
model=$(printf '%s' "$model" | sed -e 's/(R)//g' -e 's/(TM)//g' -e 's/(tm)//g' -e 's/  */ /g')

vendor=$(lsc 'Vendor ID')
[ -z "$vendor" ] && vendor=$(awk -F: '/^vendor_id/{sub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo)

sockets=$(lsc 'Socket(s)')
cps=$(lsc 'Core(s) per socket')
tpc=$(lsc 'Thread(s) per core')
threads=$(lsc 'CPU(s)')
[ -z "$threads" ] && threads=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
if [ -n "$sockets" ] && [ -n "$cps" ]; then
    cores=$((sockets * cps))
else
    cores=$(awk -F: '/^physical id/{p=$2} /^core id/{print p"-"$2}' /proc/cpuinfo 2>/dev/null | sort -u | wc -l | tr -d ' ')
    [ "$cores" = "0" ] && cores="$threads"
    sockets=${sockets:-1}
fi
smt="no"
[ -n "$tpc" ] && [ "$tpc" != "1" ] && smt="yes (${tpc} threads/core)"
[ "$smt" = "no" ] && [ -n "$threads" ] && [ -n "$cores" ] && [ "$threads" != "$cores" ] && smt="yes"

# base clock
base=''
bf=/sys/devices/system/cpu/cpu0/cpufreq/base_frequency
if [ -r "$bf" ]; then
    base=$(awk -v k="$(rd $bf)" 'BEGIN{printf "%.2f GHz", k/1000000}')
fi
if [ -z "$base" ]; then
    case "$model" in
        *@*) base=$(trim "${model##*@}") ;;
    esac
fi
if [ -z "$base" ] && [ "$HAS_DMIDECODE" = "1" ]; then
    cs=$(dmi_fields 4 'Current Speed' | head -1)
    [ -n "$cs" ] && base="$cs (DMI)"
fi

# turbo / max clock
turbo=''
mf=/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq
if [ -r "$mf" ]; then
    turbo=$(awk -v k="$(rd $mf)" 'BEGIN{printf "%.2f GHz", k/1000000}')
else
    mm=$(lsc 'CPU max MHz')
    [ -n "$mm" ] && turbo=$(awk -v m="$mm" 'BEGIN{printf "%.2f GHz", m/1000}')
fi
minf=''
nf=/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq
if [ -r "$nf" ]; then
    minf=$(awk -v k="$(rd $nf)" 'BEGIN{printf "%.2f GHz", k/1000000}')
fi

nowf=$(cpu_freq_khz)
[ -n "$nowf" ] && nowf=$(awk -v k="$nowf" 'BEGIN{printf "%.2f GHz", k/1000000}')

gov=$(dv "$(rd /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)")
drv=$(dv "$(rd /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver)")

os_find_cpu_temp
tnow='-'
tmc=$(cpu_temp_mc)
[ -n "$tmc" ] && tnow=$(awk -v t="$tmc" 'BEGIN{printf "%.1f C", t/1000}')

FLAGS=" $(lsc 'Flags') "
[ "$(trim "$FLAGS")" = "" ] && FLAGS=" $(awk -F: '/^flags/{print $2; exit}' /proc/cpuinfo 2>/dev/null) "
feat=''
case "$FLAGS" in *' avx512f '*) feat="$feat AVX-512" ;; esac
case "$FLAGS" in *' avx2 '*)    feat="$feat AVX2" ;; esac
case "$FLAGS" in *' avx '*)     feat="$feat AVX" ;; esac
case "$FLAGS" in *' aes '*)     feat="$feat AES-NI" ;; esac
case "$FLAGS" in *' sha_ni '*)  feat="$feat SHA-NI" ;; esac
case "$FLAGS" in *' vmx '*)     feat="$feat VT-x" ;; esac
case "$FLAGS" in *' svm '*)     feat="$feat AMD-V" ;; esac
case "$FLAGS" in *' rdrand '*)  feat="$feat RDRAND" ;; esac

t_open "PROCESSOR"
t_row "Model"          "$(dv "$model")"
t_row "Vendor"         "$(dv "$vendor")"
t_row "Family/Model/Stepping" "$(dv "$(lsc 'CPU family')")/$(dv "$(lsc 'Model')")/$(dv "$(lsc 'Stepping')")"
t_row "Microcode"      "$(dv "$(awk -F: '/^microcode/{sub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)")"
t_row "Sockets"        "$(dv "$sockets")"
t_row "Cores (total)"  "$(dv "$cores")"
t_row "Threads (total)" "$(dv "$threads")"
t_row "SMT / HT"       "$smt"
t_row "Base clock"     "$(dv "$base")"
t_row "Turbo / max clock" "$(dv "$turbo")"
t_row "Min clock"      "$(dv "$minf")"
t_row "Current clock (avg)" "$(dv "$nowf")"
t_row "Governor / driver" "$gov / $drv"
if [ -n "$CPU_TEMP_LABEL" ]; then
    t_row "Temperature now" "$tnow  $CD($CPU_TEMP_LABEL)$CR"
else
    t_row "Temperature now" "- $CD(no sensor)$CR"
fi
t_row "L1d / L1i cache" "$(dv "$(lsc 'L1d cache')") / $(dv "$(lsc 'L1i cache')")"
t_row "L2 cache"       "$(dv "$(lsc 'L2 cache')")"
t_row "L3 cache"       "$(dv "$(lsc 'L3 cache')")"
t_row "NUMA nodes"     "$(dv "$(lsc 'NUMA node(s)')")"
t_row "Features"       "$(dv "$(trim "$feat")")"
t_end

# ======================================================================
#  3. MEMORY
# ======================================================================
hdr "MEMORY"

memtotal_kb=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)
memavail_kb=$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo 2>/dev/null)
swap_kb=$(awk '/^SwapTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)

maxcap='-'; ndev='-'; ecc='-'
if [ "$HAS_DMIDECODE" = "1" ]; then
    arr=$(dmi_fields 16 'Maximum Capacity|Number Of Devices|Error Correction Type' | head -1)
    maxcap=$(printf '%s' "$arr" | cut -f1)
    ndev=$(printf '%s' "$arr" | cut -f2)
    ecc=$(printf '%s' "$arr" | cut -f3)
    [ -z "$ndev" ] && ndev='-'
fi

: > "$OS_TMP/dimms"
used=0
if [ "$HAS_DMIDECODE" = "1" ]; then
    dmi_fields 17 'Locator|Size|Type|Form Factor|Speed|Configured Memory Speed|Configured Clock Speed|Manufacturer|Part Number|Rank|Volatile Size' \
        > "$OS_TMP/dimms"
    used=$(awk -F'\t' '$2 != "" && $2 !~ /No Module/ {n++} END{print n+0}' "$OS_TMP/dimms")
fi

t_open "MEMORY SUMMARY"
t_row "Total installed" "$(size_h $((memtotal_kb * 1024)))"
t_row "Available now"   "$(size_s $((memavail_kb * 1024)))"
t_row "Swap"            "$(size_s $((swap_kb * 1024)))"
if [ "$ndev" = "-" ]; then
    t_row "Slots populated" "$used $CD(total slot count not reported by this firmware)$CR"
else
    t_row "Slots populated" "$used of $ndev"
fi
t_row "Max capacity"    "$(dv "$maxcap")"
t_row "Error correction" "$(dv "$ecc")"
t_end

if [ -s "$OS_TMP/dimms" ]; then
    t_head "MEMORY MODULES" "SLOT" "SIZE" "TYPE" "CONFIGURED" "RATED" "RANK" "MANUFACTURER" "PART NUMBER"
    while IFS="$TAB" read -r loc sz typ ff spd cspd cclk man pn rank; do
        [ -z "$sz" ] && continue
        case "$sz" in *'No Module'*) t_row "$(dv "$loc")" "empty" "-" "-" "-" "-" "-" "-" ; continue ;; esac
        cfg="$cspd"; [ -z "$cfg" ] && cfg="$cclk"
        t_row "$(dv "$loc")" "$sz" "$(trim "$typ $ff")" "$(dv "$cfg")" "$(dv "$spd")" \
              "$(dv "$rank")" "$(dv "$man")" "$(dv "$pn")"
    done < "$OS_TMP/dimms"
    t_note "CONFIGURED = speed the module actually runs at, RATED = speed printed on the module"
    t_note "CAS latency is not exposed via DMI - re-run with SPD=1 (or ?spd=1) to read the SPD EEPROM"
    t_end
elif [ "$OS_ROOT" != "1" ]; then
    warn "per-module memory details need root"
fi

# optional SPD / EEPROM decode (CAS latencies, XMP profiles)
if [ "${SPD:-0}" = "1" ] && [ "$OS_ROOT" = "1" ]; then
    hdr "MEMORY SPD (EEPROM)"
    if ensure_cmd decode-dimms; then
        $SUDO modprobe i2c-dev 2>/dev/null
        $SUDO modprobe ee1004 2>/dev/null || $SUDO modprobe eeprom 2>/dev/null
        $SUDO modprobe at24 2>/dev/null
        spdout=$($SUDO decode-dimms 2>/dev/null)
        if printf '%s' "$spdout" | grep -q 'Fundamental Memory type\|Memory type'; then
            t_head "SPD DETAIL" "FIELD" "VALUE"
            printf '%s\n' "$spdout" | awk '
                /^(Fundamental Memory type|Memory type|Module Manufacturer|DRAM Manufacturer|Part Number|Maximum module speed|Size|Ranks|tCL|CAS Latencies|Supported CAS Latencies|Minimum CAS Latency|Module Configuration Type|XMP|Manufacturing Date)/ {
                    p = index($0, "  ")
                    k = $0; v = ""
                    if (p > 0) { k = substr($0, 1, p-1); v = substr($0, p); }
                    gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v)
                    print k "\t" v
                }' | while IFS="$TAB" read -r k v; do t_row "$k" "$v"; done
            t_end
        else
            warn "SPD EEPROM not readable (no i2c access on this board / driver missing)"
        fi
    fi
fi

# ======================================================================
#  4. MOTHERBOARD / CHIPSET / SLOTS
# ======================================================================
hdr "MOTHERBOARD"

os_lspci_cache
chipset=$(awk -F'"' '$2 == "ISA bridge" { print $4 " " $6; exit }' "$OS_TMP/lspci" | pci_clean)
[ -z "$(trim "$chipset")" ] && chipset=$(awk -F'"' '$2 == "Host bridge" { print $4 " " $6; exit }' "$OS_TMP/lspci" | pci_clean)

# SATA / AHCI
sata_ports=$(ls -d /sys/class/ata_port/ata* 2>/dev/null | wc -l | tr -d ' ')
sata_used=0
for d in /sys/block/sd*; do
    [ -e "$d" ] || continue
    lnk=$(readlink -f "$d" 2>/dev/null)
    case "$lnk" in *ata[0-9]*) sata_used=$((sata_used + 1)) ;; esac
done
sata_ctl=$(awk -F'"' '$2 == "SATA controller" || $2 == "IDE interface" || $2 == "RAID bus controller" { c++ } END { print c+0 }' "$OS_TMP/lspci")

# NVMe
nvme_ctl=$(awk -F'"' '$2 == "Non-Volatile memory controller" { c++ } END { print c+0 }' "$OS_TMP/lspci")
nvme_ns=$(ls -d /sys/block/nvme*n1 2>/dev/null | wc -l | tr -d ' ')

usb_ctl=$(awk -F'"' '$2 == "USB controller" { c++ } END { print c+0 }' "$OS_TMP/lspci")

t_open "MOTHERBOARD"
t_row "Board"        "$(dv "$(trim "$(rd $DMI/board_vendor) $(rd $DMI/board_name) $(rd $DMI/board_version)")")"
t_row "Board serial"  "$(dv "$(rd $DMI/board_serial)" 'hidden (needs root)')"
t_row "Chipset"      "$(dv "$(trim "$chipset")")"
t_row "BIOS"         "$(dv "$(rd $DMI/bios_vendor)") $(dv "$(rd $DMI/bios_version)") [$(dv "$(rd $DMI/bios_date)")]"
t_row "SATA ports"   "$sata_used of $sata_ports in use  ($sata_ctl SATA/IDE controller(s))"
t_row "NVMe"         "$nvme_ns namespace(s) on $nvme_ctl controller(s)"
t_row "USB controllers" "$usb_ctl"
t_note "SATA port count comes from the kernel ATA ports the chipset exposes - physical connectors can differ"
t_end

if [ "$HAS_DMIDECODE" = "1" ]; then
    slots=$(dmi_fields 9 'Designation|Type|Current Usage|Length|Bus Address')
    if [ -n "$slots" ]; then
        t_head "EXPANSION SLOTS (M.2 / PCIe / other)" "DESIGNATION" "TYPE" "USAGE" "LENGTH" "OCCUPANT"
        printf '%s\n' "$slots" | while IFS="$TAB" read -r des typ use len bus; do
            occ='-'
            case "$bus" in
                ''|'Not Specified'|0000:00:00.0) occ='-' ;;
                *) occ=$(pci_name "$bus") ;;
            esac
            t_row "$(dv "$des")" "$(dv "$typ")" "$(dv "$use")" "$(dv "$len")" "$occ"
        done
        t_end
    fi
else
    note "slot inventory (free M.2 / PCIe slots) needs root"
fi

# ======================================================================
#  5. STORAGE (summary - see storage.sh for SMART health)
# ======================================================================
hdr "STORAGE"

t_head "BLOCK DEVICES" "DEVICE" "MODEL" "SIZE" "KIND" "BUS" "ROTA" "FIRMWARE"
found=0
for b in /sys/block/*; do
    [ -d "$b" ] || continue
    name=${b##*/}
    case "$name" in
        loop*|ram*|zram*|dm-*|md*|sr*|fd*) continue ;;
    esac
    sectors=$(rd "$b/size")
    [ -z "$sectors" ] || [ "$sectors" = "0" ] && continue
    bytes=$((sectors * 512))
    rota=$(rd "$b/queue/rotational")
    model=$(rd "$b/device/model")
    [ -z "$model" ] && model=$(rd "$b/device/name")
    vend=$(rd "$b/device/vendor")
    fw=$(rd "$b/device/firmware_rev")
    [ -z "$fw" ] && fw=$(rd "$b/device/rev")
    rem=$(rd "$b/removable")
    lnk=$(readlink -f "$b" 2>/dev/null)
    case "$name" in
        nvme*) bus="NVMe" ;;
        mmcblk*) bus="eMMC/SD" ;;
        *)
            case "$lnk" in
                *usb*) bus="USB" ;;
                *ata[0-9]*) bus="SATA" ;;
                *virtio*) bus="virtio" ;;
                *) bus=$(dv "$(rd "$b/device/../../transport")" "SCSI") ;;
            esac ;;
    esac
    case "$name" in
        nvme*) kind="SSD (NVMe)" ;;
        *) if [ "$rota" = "0" ]; then kind="SSD"; else kind="HDD"; fi ;;
    esac
    [ "$rem" = "1" ] && kind="$kind, removable"
    if [ "$rota" = "1" ]; then rotc=yes; else rotc=no; fi
    t_row "/dev/$name" "$(dv "$(trim "$vend $model")")" "$(size_h "$bytes")" "$kind" "$bus" \
          "$rotc" "$(dv "$fw")"
    found=1
done
t_end
[ "$found" = "0" ] && warn "no block devices found"
note "SMART health / wear / lifespan:  curl -fsSL $(os_url /storage.sh) | sudo sh"

# ======================================================================
#  6. NETWORK
# ======================================================================
hdr "NETWORK"

ensure_cmd ethtool >/dev/null 2>&1 || true
t_head "NETWORK ADAPTERS" "IFACE" "TYPE" "DRIVER" "LINK" "SPEED" "MAX" "IPv4" "CONTROLLER"
for n in /sys/class/net/*; do
    [ -d "$n" ] || continue
    ifn=${n##*/}
    [ "$ifn" = "lo" ] && continue
    drv=''
    if [ -L "$n/device/driver" ]; then
        drv=$(readlink -f "$n/device/driver" 2>/dev/null); drv=${drv##*/}
    fi
    mac=$(rd "$n/address")
    oper=$(rd "$n/operstate")
    carr=$(rd "$n/carrier")
    spd=$(rd "$n/speed")
    case "$spd" in ''|-*) spd='-' ;; *) spd="$spd Mb/s" ;; esac
    if [ -d "$n/wireless" ] || [ -e "$n/phy80211" ]; then typ="wifi"
    elif [ -d "$n/bridge" ]; then typ="bridge"
    elif [ -e "$n/tun_flags" ]; then typ="tun/tap"
    elif [ -z "$drv" ]; then typ="virtual"
    else typ="ethernet"; fi
    # PCI controller behind the interface
    ctl='-'
    if [ -L "$n/device" ]; then
        dpath=$(readlink -f "$n/device" 2>/dev/null)
        bdf=${dpath##*/}
        case "$bdf" in
            *:*:*.*) ctl=$(pci_name "$bdf") ;;
            *) case "$dpath" in *usb*) ctl="USB device" ;; esac ;;
        esac
    fi
    maxspd='-'
    if have ethtool && [ "$typ" = "ethernet" ]; then
        maxspd=$(ethtool "$ifn" 2>/dev/null | awk '
            /Supported link modes:/ { grab=1 }
            grab {
                line = $0
                if (line ~ /Supported pause|Supported FEC|Advertised/) grab=0
                else { n = split(line, A, /[ \t]+/); for (i=1;i<=n;i++) if (A[i] ~ /base/) { split(A[i], B, "base"); if (B[1]+0 > m) m = B[1]+0 } }
            }
            END { if (m >= 1000) printf "%g Gb/s\n", m/1000; else if (m > 0) printf "%d Mb/s\n", m }')
        [ -z "$maxspd" ] && maxspd='-'
    fi
    ip4='-'
    if have ip; then
        ip4=$(ip -o -4 addr show dev "$ifn" 2>/dev/null | awk '{print $4}' | tr '\n' ' ')
    elif have ifconfig; then
        ip4=$(ifconfig "$ifn" 2>/dev/null | awk '/inet /{print $2}' | tr '\n' ' ')
    fi
    [ -z "$(trim "$ip4")" ] && ip4='-'
    lnkst="$oper"
    [ "$carr" = "1" ] && lnkst="up"
    t_row "$ifn" "$typ" "$(dv "$drv")" "$lnkst" "$spd" "$maxspd" "$(trim "$ip4")" "$ctl"
    printf '%s\t%s\n' "$ifn" "$(dv "$mac")" >> "$OS_TMP/macs"
done
t_end

if [ -s "$OS_TMP/macs" ]; then
    t_head "MAC ADDRESSES" "IFACE" "MAC"
    while IFS="$TAB" read -r a b; do t_row "$a" "$b"; done < "$OS_TMP/macs"
    t_end
fi

# ======================================================================
#  7. GPU / DISPLAY
# ======================================================================
hdr "GRAPHICS"

t_head "GPU" "BDF" "DEVICE" "CLASS" "DRIVER" "VRAM" "LINK"
gpu_found=0
for p in /sys/bus/pci/devices/*; do
    [ -d "$p" ] || continue
    bdf=${p##*/}
    cls=$(rd "$p/class")
    case "$cls" in
        0x0300*|0x0302*|0x0380*) ;;
        *) continue ;;
    esac
    gpu_found=1
    drv='-'
    [ -L "$p/driver" ] && { drv=$(readlink -f "$p/driver"); drv=${drv##*/}; }
    vram='-'
    for vf in "$p"/mem_info_vram_total "$p"/drm/card*/device/mem_info_vram_total; do
        [ -r "$vf" ] && { vram=$(size_s "$(rd "$vf")"); break; }
    done
    if [ "$vram" = "-" ] && have nvidia-smi; then
        vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1)
        [ -z "$vram" ] && vram='-'
    fi
    cls_s=$(pci_class_short "$(pci_class "$bdf")")
    cs=$(rd "$p/current_link_speed"); cw=$(rd "$p/current_link_width")
    ms=$(rd "$p/max_link_speed");     mw=$(rd "$p/max_link_width")
    link="-"
    [ -n "$cs" ] && link="$(pcie_gen "$cs") x${cw:-?} / max $(pcie_gen "$ms") x${mw:-?}"
    t_row "$bdf" "$(pci_name "$bdf")" "$(dv "$cls_s")" "$drv" "$vram" "$link"
done
t_end
[ "$gpu_found" = "0" ] && warn "no PCI display controller found"

# connected displays
dsp=0
: > "$OS_TMP/disp"
for c in /sys/class/drm/*-*; do
    [ -r "$c/status" ] || continue
    st=$(rd "$c/status")
    conn=${c##*/}
    conn=${conn#card*-}
    en=$(rd "$c/enabled")
    mode=$(head -1 "$c/modes" 2>/dev/null)
    printf '%s\t%s\t%s\t%s\n' "$conn" "$st" "$(dv "$en")" "$(dv "$mode")" >> "$OS_TMP/disp"
    [ "$st" = "connected" ] && dsp=$((dsp + 1))
done
if [ -s "$OS_TMP/disp" ]; then
    t_head "DISPLAY OUTPUTS ($dsp connected)" "CONNECTOR" "STATUS" "ENABLED" "PREFERRED MODE"
    while IFS="$TAB" read -r a b c d; do t_row "$a" "$b" "$c" "$d"; done < "$OS_TMP/disp"
    t_end
fi

# ======================================================================
#  8. PCIe LINKS
# ======================================================================
hdr "PCIe"

t_head "PCIe LINKS" "BDF" "DEVICE" "CLASS" "CURRENT" "CAPABLE" "NOTE"
for p in /sys/bus/pci/devices/*; do
    [ -r "$p/max_link_speed" ] || continue
    bdf=${p##*/}
    ms=$(rd "$p/max_link_speed"); mw=$(rd "$p/max_link_width")
    cs=$(rd "$p/current_link_speed"); cw=$(rd "$p/current_link_width")
    [ -z "$mw" ] || [ "$mw" = "0" ] && continue
    cls=$(rd "$p/class")
    isbridge=0
    case "$cls" in 0x0604*|0x0600*|0x0601*) isbridge=1 ;; esac
    # hide empty bridges / root ports with no device behind them
    if [ "$isbridge" = "1" ] && { [ -z "$cw" ] || [ "$cw" = "0" ]; }; then continue; fi
    if [ "$isbridge" = "1" ]; then
        kids=$(ls -d "$p"/0000:* 2>/dev/null | wc -l | tr -d ' ')
        [ "$kids" = "0" ] && continue
    fi
    note=''
    gcur=$(pcie_gen "$cs"); gmax=$(pcie_gen "$ms")
    [ -n "$cw" ] && [ -n "$mw" ] && [ "$cw" -lt "$mw" ] 2>/dev/null && note="width below capability"
    if [ "$gcur" != "$gmax" ] && [ "$gcur" != "-" ]; then
        [ -n "$note" ] && note="$note, " ; note="${note}running at lower gen"
    fi
    [ -z "$note" ] && note="ok"
    t_row "$bdf" "$(pci_name "$bdf")" "$(dv "$(pci_class_short "$(pci_class "$bdf")")")" \
          "$gcur x${cw:-?}" "$gmax x${mw:-?}" "$note"
done
t_note "'running at lower gen' is often just power saving at idle - re-check while the GPU is busy"
t_end

# ======================================================================
#  9. SENSORS
# ======================================================================
hdr "SENSORS"

os_try_sensor_modules >/dev/null 2>&1 || true

t_head "TEMPERATURES & FANS" "CHIP" "SENSOR" "READING"
sfound=0
for h in /sys/class/hwmon/hwmon*; do
    [ -d "$h" ] || continue
    cn=$(rd "$h/name"); [ -z "$cn" ] && cn=${h##*/}
    for f in "$h"/temp*_input; do
        [ -r "$f" ] || continue
        lab=$(rd "${f%_input}_label")
        [ -z "$lab" ] && lab=$(basename "${f%_input}")
        v=$(rd "$f")
        [ -z "$v" ] && continue
        crit=$(rd "${f%_input}_crit")
        extra=''
        [ -n "$crit" ] && extra=$(awk -v c="$crit" 'BEGIN{printf "  (crit %.0f C)", c/1000}')
        t_row "$cn" "$lab" "$(awk -v t="$v" 'BEGIN{printf "%.1f C", t/1000}')$extra"
        sfound=1
    done
    for f in "$h"/fan*_input; do
        [ -r "$f" ] || continue
        lab=$(rd "${f%_input}_label")
        [ -z "$lab" ] && lab=$(basename "${f%_input}")
        v=$(rd "$f")
        [ -z "$v" ] && continue
        t_row "$cn" "$lab" "$v rpm"
        sfound=1
    done
done
if [ "$sfound" = "0" ]; then
    for z in /sys/class/thermal/thermal_zone*; do
        [ -r "$z/temp" ] || continue
        t_row "thermal" "$(rd "$z/type")" "$(awk -v t="$(rd "$z/temp")" 'BEGIN{printf "%.1f C", t/1000}')"
    done
fi
t_end
if [ "$sfound" = "0" ]; then
    note "no hwmon sensors found - the board driver may be missing; try 'sensors-detect'"
    [ "$OS_ROOT" != "1" ] && note "running as root lets the script load the coretemp/k10temp/nct6775 modules itself"
fi

os_footer
