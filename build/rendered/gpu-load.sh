#!/bin/sh
# shellcheck shell=sh disable=SC2086,SC2012,SC3043
#@name        gpu-load
#@title       GPU load + thermal test
#@description Loads the GPU, samples temperature / utilisation / clock / power, min-max-avg-median
#@root        recommended
#@params      duration,interval,baseline,gpu
# shellcheck shell=sh disable=SC2086,SC2181,SC3043
# ======================================================================
#  online-script :: shared library
#  The server splices this file into every script it serves (see the
#  include directive in each one), so a served script is self-contained.
#  POSIX sh only (must run under dash, ash/busybox and bash).
# ======================================================================

OS_BASE_URL="http://localhost:8080"
OS_TOKEN_Q=""
OS_VERSION="1.0.0"

TAB=$(printf '\t')
OS_FS=$(printf '\001')   # table column separator (never appears in hw strings)

# ------------------------------------------------------------ scratch dir
OS_TMP="${TMPDIR:-/tmp}/onlinescript.$$"
if ! mkdir -p "$OS_TMP" 2>/dev/null; then
    echo "FATAL: cannot create temp dir $OS_TMP" >&2
    exit 1
fi
os_cleanup() { [ -n "$OS_TMP" ] && rm -rf "$OS_TMP" 2>/dev/null; }
trap 'os_cleanup' EXIT
trap 'os_cleanup; exit 130' INT
trap 'os_cleanup; exit 143' TERM

# ---------------------------------------------------------------- colours
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${PLAIN:-0}" != "1" ]; then
    CB=$(printf '\033[1m')      # bold
    CD=$(printf '\033[2m')      # dim
    CR=$(printf '\033[0m')      # reset
    CC=$(printf '\033[36m')     # cyan   (borders)
    CG=$(printf '\033[32m')     # green  (good)
    CY=$(printf '\033[33m')     # yellow (warn)
    CE=$(printf '\033[31m')     # red    (bad)
else
    CB= ; CD= ; CR= ; CC= ; CG= ; CY= ; CE=
fi

# ------------------------------------------------------- box drawing set
case "${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}" in
    *UTF-8*|*utf-8*|*UTF8*|*utf8*) OS_UNI=1 ;;
    *) OS_UNI=0 ;;
esac
[ "${PLAIN:-0}" = "1" ] && OS_UNI=0
if [ "$OS_UNI" = "1" ]; then
    B_TL='+' ; B_TR='+' ; B_BL='+' ; B_BR='+'
    B_TL=$(printf '\342\225\255')   # top-left round
    B_TR=$(printf '\342\225\256')
    B_BL=$(printf '\342\225\260')
    B_BR=$(printf '\342\225\257')
    B_H=$(printf '\342\224\200')
    B_V=$(printf '\342\224\202')
    B_ML=$(printf '\342\224\234')
    B_MR=$(printf '\342\224\244')
    B_EQ=$(printf '\342\225\220')
else
    B_TL='+' ; B_TR='+' ; B_BL='+' ; B_BR='+'
    B_H='-'  ; B_V='|'  ; B_ML='+' ; B_MR='+' ; B_EQ='='
fi

# ------------------------------------------------------- terminal width
have() { command -v "$1" >/dev/null 2>&1; }

# "curl | sh" leaves stdin pointing at the pipe, so the window size has to
# come from stdout (tput) or from the controlling terminal (/dev/tty).
os_term_width() {
    _w=''
    if have tput; then
        _w=$(tput cols 2>/dev/null)
        case "$_w" in ''|*[!0-9]*) _w='' ;; esac
    fi
    if [ -z "$_w" ] && have stty; then
        _w=$(stty size 2>/dev/null < /dev/tty | awk '{ print $2 }')
        case "$_w" in ''|*[!0-9]*) _w='' ;; esac
    fi
    [ -z "$_w" ] && _w=${COLUMNS:-}
    case "$_w" in ''|*[!0-9]*) _w=120 ;; esac        # unknown: assume roomy
    [ "$_w" -lt 40 ] && _w=120                       # bogus reading
    [ "$_w" -gt 220 ] && _w=220                      # very wide is hard to read
    printf '%s' "$_w"
}

# COLS=200 (or ?cols=200 on the URL) overrides the detected width
OS_COLS=${COLS:-$(os_term_width)}
case "$OS_COLS" in ''|*[!0-9]*) OS_COLS=120 ;; esac
[ "$OS_COLS" -lt 40 ] && OS_COLS=40
[ "$OS_COLS" -gt 400 ] && OS_COLS=400

# ====================================================================
#  tiny helpers
# ====================================================================
# read first line of a sysfs/proc file without spawning a process
# NOTE: stderr is redirected *before* the input redirection on purpose - a
# sysfs file can pass "test -r" and still fail to open (e.g. root-only DMI
# fields inside a rootless container), and the shell would print that itself.
rd() {
    _v=''
    [ -r "$1" ] || { printf ''; return 1; }
    read -r _v 2>/dev/null < "$1" || true
    printf '%s' "$_v"
}

# read whole file, newlines squashed to spaces
rdall() { [ -r "$1" ] || return 1; tr '\n' ' ' 2>/dev/null < "$1"; }

# default a value to "-" when empty / unknown
dv() {
    case "$1" in
        ''|'Unknown'|'unknown'|'To Be Filled By O.E.M.'|'To be filled by O.E.M.'|\
        'Not Specified'|'None'|'Default string'|'System manufacturer'|'0x0000'|'N/A'|\
        'System Product Name'|'System Version'|'Filled by OEM.')
            printf '%s' "${2--}" ;;
        *) printf '%s' "$1" ;;
    esac
}

trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# 1024-based + decimal size from a byte count -> "465.8 GiB (500.1 GB)"
size_h() {
    awk -v b="$1" 'BEGIN{
        if (b+0 <= 0) { print "-"; exit }
        split("B KiB MiB GiB TiB PiB", u, " ");
        i=1; x=b; while (x>=1024 && i<6) { x/=1024; i++ }
        split("B KB MB GB TB PB", d, " ");
        j=1; y=b; while (y>=1000 && j<6) { y/=1000; j++ }
        if (i==1) printf "%d B\n", b;
        else printf "%.1f %s (%.1f %s)\n", x, u[i], y, d[j];
    }'
}

# plain 1024-based size, no decimal twin
size_s() {
    awk -v b="$1" 'BEGIN{
        if (b+0 <= 0) { print "-"; exit }
        split("B KiB MiB GiB TiB PiB", u, " ");
        i=1; while (b>=1024 && i<6) { b/=1024; i++ }
        if (i<=2) printf "%d %s\n", b, u[i]; else printf "%.1f %s\n", b, u[i];
    }'
}

# horizontal percentage bar:  pct_bar 72 20 -> [##############------]  72%
pct_bar() {
    awk -v p="$1" -v w="${2:-16}" 'BEGIN{
        if (p == "" || p+0 != p) { print "-"; exit }
        n = int(p*w/100 + 0.5); if (n<0) n=0; if (n>w) n=w;
        s="["; for (i=0;i<n;i++) s=s "#"; for (i=n;i<w;i++) s=s "-";
        printf "%s] %3d%%\n", s, p;
    }'
}

# printable URL for a script; quoted when it carries a token, so it survives
# being pasted into zsh as well as bash
os_url() {
    if [ -n "$OS_TOKEN_Q" ]; then
        printf "'%s%s%s'" "$OS_BASE_URL" "$1" "$OS_TOKEN_Q"
    else
        printf '%s%s' "$OS_BASE_URL" "$1"
    fi
}

# wrap free text to the terminal, with a hanging indent
#   os_wrap <first-indent> <continuation-indent> <colour> <text...>
os_wrap() {
    _i1="$1"; _i2="$2"; _c="$3"; shift 3
    awk -v i1="$_i1" -v i2="$_i2" -v col="$_c" -v rst="$CR" -v w="$OS_COLS" -v s="$*" '
    BEGIN {
        width = w - length(i2); if (width < 20) width = 20
        n = split(s, a, " "); line = ""; first = 1
        for (i = 1; i <= n; i++) {
            if (line == "") line = a[i]
            else if (length(line) + 1 + length(a[i]) <= width) line = line " " a[i]
            else { print col (first ? i1 : i2) line rst; first = 0; line = a[i] }
        }
        if (line != "" || first) print col (first ? i1 : i2) line rst
    }'
}

msg()   { printf '%s\n' "$*"; }
note()  { os_wrap "  "    "  "    "$CD" "$*"; }
warn()  { os_wrap "  ! "  "    "  "$CY" "$*"; }
err()   { os_wrap "  x "  "    "  "$CE" "$*"; }
step()  { os_wrap "  .. " "     " "$CD" "$*"; }

# section heading (between tables)
hdr() { printf '\n%s%s%s\n' "$CB$CC" "$*" "$CR"; }

rule() { awk -v w="$OS_COLS" -v ch="$B_EQ" -v c="$CC" -v r="$CR" 'BEGIN{s="";for(i=0;i<w;i++)s=s ch; print c s r}'; }

# ====================================================================
#  table rendering
#     t_head "TITLE" col1 col2 ...     table with a header row
#     t_open "TITLE"                   table without header (key/value)
#     t_row  v1 v2 ...
#     t_end
# ====================================================================
OS_T_TITLE=''
OS_T_HDR=0

t_head() {
    OS_T_TITLE="$1"; shift
    : > "$OS_TMP/t"
    OS_T_HDR=1
    t_row "$@"
}

t_open() {
    OS_T_TITLE="$1"
    : > "$OS_TMP/t"
    OS_T_HDR=0
}

t_row() {
    _r=''; _first=1
    for _f in "$@"; do
        if [ "$_first" = 1 ]; then _r="$_f"; _first=0; else _r="$_r$OS_FS$_f"; fi
    done
    # one row must stay one line, and a stray tab must not split a cell
    _r=$(printf '%s' "$_r" | tr '\r\n\t' '   ')
    printf '%s\n' "$_r" >> "$OS_TMP/t"
}

# footnote printed under the table currently being built (or right away if
# no table is open)
t_note() {
    if [ -s "$OS_TMP/t" ]; then
        os_wrap "    " "    " "$CD" "$*" >> "$OS_TMP/n"
    else
        os_wrap "    " "    " "$CD" "$*"
    fi
}

t_end() {
    awk -v title="$OS_T_TITLE" -v hdr="$OS_T_HDR" -v maxw="$OS_COLS" \
        -v TL="$B_TL" -v TR="$B_TR" -v BL="$B_BL" -v BR="$B_BR" \
        -v H="$B_H" -v V="$B_V" -v ML="$B_ML" -v MR="$B_MR" \
        -v CB="$CB" -v CR="$CR" -v CC="$CC" -v CD="$CD" \
        -v ESC="$(printf '\033')" -v maxlines="${OS_T_MAXLINES:-8}" '
    function rep(s, n,   o, i) { o=""; for (i=0; i<n; i++) o = o s; return o }
    # cells may carry colour escapes, which take no space on screen
    function strip(s) { gsub(ESC "\\[[0-9;]*m", "", s); return s }
    function vislen(s) { return length(strip(s)) }
    # longest single word: shrinking a column past this splits a word in half
    function maxword(s,   words, n, i, m) {
        n = split(strip(s), words, " "); m = 0
        for (i=1; i<=n; i++) if (length(words[i]) > m) m = length(words[i])
        return m
    }

    # Split a cell over as many lines as it needs instead of cutting it off.
    # A colour that wraps the whole cell is re-applied to every line.
    function wrap(s, width, out,   pre, post, words, n, i, k, word, line, cnt) {
        delete out
        pre = ""; post = ""
        while (match(s, "^" ESC "\\[[0-9;]*m")) {
            pre = pre substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
        }
        while (match(s, ESC "\\[[0-9;]*m$")) {
            post = substr(s, RSTART) post; s = substr(s, 1, RSTART - 1)
        }
        s = strip(s)
        cnt = 0; line = ""
        n = split(s, words, " ")
        for (i = 1; i <= n; i++) {
            word = words[i]
            while (length(word) > width) {          # single unbreakable token
                if (line != "") { out[++cnt] = line; line = "" }
                out[++cnt] = substr(word, 1, width)
                word = substr(word, width + 1)
            }
            if (line == "") line = word
            else if (length(line) + 1 + length(word) <= width) line = line " " word
            else { out[++cnt] = line; line = word }
        }
        if (line != "" || cnt == 0) out[++cnt] = line
        if (cnt > maxlines) {                        # pathological value
            out[maxlines] = substr(out[maxlines], 1, width - 1) "~"
            for (k = maxlines + 1; k <= cnt; k++) delete out[k]
            cnt = maxlines
        }
        if (pre != "" || post != "")
            for (k = 1; k <= cnt; k++) out[k] = pre out[k] post
        return cnt
    }

    BEGIN { FS="\001"; gap=2; ncol=0; nrow=0 }
    {
        if (NF > ncol) ncol = NF
        for (i=1; i<=NF; i++) {
            v = $i
            sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
            if (v == "") v = "-"
            c[NR, i] = v
            if (vislen(v) > w[i]) w[i] = vislen(v)
            if (maxword(v) > mw[i]) mw[i] = maxword(v)
        }
        nrow = NR
    }
    END {
        tl = length(title)
        if (nrow == 0 || (hdr == 1 && nrow == 1)) {
            total = (tl > 10 ? tl : 10) + 2
            full = total + 4
            print CC TL H CR " " CB title CR " " CC rep(H, full-tl-5) TR CR
            print CC V CR " " CD "no data" CR rep(" ", total-7) " " CC V CR
            print CC BL rep(H, full-2) BR CR
            printf "\n"
            exit
        }
        for (i=1; i<=ncol; i++) if (w[i] < 1) w[i] = 1
        total = gap * (ncol-1)
        for (i=1; i<=ncol; i++) total += w[i]
        # Narrow the table until it fits. Prose columns give way first: a
        # column is only pushed below its longest word (splitting an address
        # or a part number in half) when nothing else can give.
        avail = maxw - 4
        while (total > avail) {
            b = 0; bi = 0
            for (i=1; i<=ncol; i++)
                if (w[i] > mw[i] && w[i] > b) { b = w[i]; bi = i }
            if (bi == 0) {
                for (i=1; i<=ncol; i++) if (w[i] > b) { b = w[i]; bi = i }
                if (b <= 12) break
            }
            w[bi]--; total--
        }
        if (total < tl + 2) { w[ncol] += (tl + 2 - total); total = tl + 2 }
        full = total + 4

        print CC TL H CR " " CB title CR " " CC rep(H, full-tl-5) TR CR
        for (r=1; r<=nrow; r++) {
            high = 1
            for (i=1; i<=ncol; i++) {
                v = c[r, i]; if (v == "") v = "-"
                nl[i] = wrap(v, w[i], seg)
                for (k=1; k<=nl[i]; k++) cell[i, k] = seg[k]
                if (nl[i] > high) high = nl[i]
            }
            for (k=1; k<=high; k++) {
                line = ""
                for (i=1; i<=ncol; i++) {
                    v = (k <= nl[i]) ? cell[i, k] : ""
                    line = line v rep(" ", w[i] - vislen(v))
                    if (i < ncol) line = line rep(" ", gap)
                }
                if (hdr == 1 && r == 1)
                    print CC V CR " " CB line CR " " CC V CR
                else
                    print CC V CR " " line " " CC V CR
            }
            if (hdr == 1 && r == 1) print CC ML rep(H, full-2) MR CR
        }
        print CC BL rep(H, full-2) BR CR
    }' "$OS_TMP/t"
    : > "$OS_TMP/t"
    if [ -s "$OS_TMP/n" ]; then
        cat "$OS_TMP/n"
        : > "$OS_TMP/n"
    fi
    printf '\n'
}

# ====================================================================
#  statistics  (samples are stored as integers -> divide at print time)
#     stats_row "Label" file divisor unit decimals
# ====================================================================
stats_calc() { # file divisor decimals -> "min max avg median count"
    sort -n "$1" 2>/dev/null | awk -v d="$2" -v dec="${3:-1}" '
        /^-?[0-9]+$/ { a[++n] = $1 }
        END {
            if (n == 0) { print "- - - - 0"; exit }
            mn = a[1]; mx = a[n]; s = 0
            for (i=1; i<=n; i++) s += a[i]
            if (n % 2) med = a[(n+1)/2]; else med = (a[n/2] + a[n/2+1]) / 2
            f = "%." dec "f"
            printf f " " f " " f " " f " %d\n", mn/d, mx/d, s/n/d, med/d, n
        }'
}

stats_row() { # label file divisor unit decimals
    _lbl="$1"; _f="$2"; _div="$3"; _unit="$4"; _dec="${5:-1}"
    [ -s "$_f" ] || { t_row "$_lbl" "-" "-" "-" "-" "-"; return; }
    # shellcheck disable=SC2046
    set -- $(stats_calc "$_f" "$_div" "$_dec")
    t_row "$_lbl" "$1 $_unit" "$2 $_unit" "$3 $_unit" "$4 $_unit" "$5"
}

# sparkline of a sample file (integers), width columns
sparkline() {
    awk -v w="${2:-60}" -v uni="$OS_UNI" '
    /^-?[0-9]+$/ { a[++n] = $1 }
    END {
        if (n == 0) { print "(no samples)"; exit }
        if (uni == 1) {
            split("\342\226\201 \342\226\202 \342\226\203 \342\226\204 \342\226\205 \342\226\206 \342\226\207 \342\226\210", L, " ")
        } else {
            split("_ . - = + * # @", L, " ")
        }
        mn = a[1]; mx = a[1]
        for (i=1; i<=n; i++) { if (a[i]<mn) mn=a[i]; if (a[i]>mx) mx=a[i] }
        if (mx == mn) mx = mn + 1
        if (n < w) w = n
        out = ""
        for (b=0; b<w; b++) {
            lo = int(b*n/w) + 1; hi = int((b+1)*n/w); if (hi < lo) hi = lo
            s = 0; k = 0
            for (i=lo; i<=hi; i++) { s += a[i]; k++ }
            v = s/k
            idx = int((v-mn) * 7 / (mx-mn) + 0.5) + 1
            if (idx < 1) idx = 1; if (idx > 8) idx = 8
            out = out L[idx]
        }
        print out
    }' "$1"
}

# ====================================================================
#  privilege + package management
# ====================================================================
SUDO=''
OS_ROOT=0
OS_INSTALLED=''
OS_MISSING=''
OS_PKG_REFRESHED=''
PKG=''
DISTRO_ID=''
DISTRO_LIKE=''
DISTRO_NAME=''

os_detect_priv() {
    if [ "$(id -u)" = "0" ]; then
        OS_ROOT=1; SUDO=''
    elif have sudo && sudo -n true 2>/dev/null; then
        OS_ROOT=1; SUDO='sudo -n'
    else
        OS_ROOT=0; SUDO=''
    fi
}

os_detect_distro() {
    if [ -r /etc/os-release ]; then
        DISTRO_ID=$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}")
        DISTRO_LIKE=$(. /etc/os-release 2>/dev/null; printf '%s' "${ID_LIKE:-}")
        DISTRO_NAME=$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-${NAME:-}}")
    fi
    [ -z "$DISTRO_NAME" ] && DISTRO_NAME="unknown Linux"

    case " $DISTRO_ID $DISTRO_LIKE " in
        *alpine*)                          PKG=apk ;;
        *debian*|*ubuntu*|*mint*|*pop*)    PKG=apt ;;
        *fedora*|*rhel*|*centos*|*almalinux*|*rocky*) PKG=dnf ;;
        *arch*|*manjaro*|*endeavouros*)    PKG=pacman ;;
        *suse*)                            PKG=zypper ;;
        *)                                 PKG='' ;;
    esac
    if [ -z "$PKG" ]; then   # fall back to whatever tool exists
        if   have apt-get; then PKG=apt
        elif have apk;     then PKG=apk
        elif have dnf;     then PKG=dnf
        elif have yum;     then PKG=yum
        elif have pacman;  then PKG=pacman
        elif have zypper;  then PKG=zypper
        fi
    fi
    [ "$PKG" = dnf ] && ! have dnf && have yum && PKG=yum
}

# package name for a given command, per package manager
pkg_for() {
    case "$1" in
        dmidecode)   echo dmidecode ;;
        lspci|setpci) echo pciutils ;;
        lsusb)       echo usbutils ;;
        lscpu|lsblk|findmnt)
            case "$PKG" in apk) echo "util-linux" ;; *) echo util-linux ;; esac ;;
        smartctl)    echo smartmontools ;;
        nvme)        echo nvme-cli ;;
        hdparm)      echo hdparm ;;
        ethtool)     echo ethtool ;;
        ip)          echo iproute2 ;;
        sensors)
            case "$PKG" in
                apt|apk) echo lm-sensors ;;
                dnf|yum|pacman) echo lm_sensors ;;
                zypper) echo sensors ;;
                *) echo lm-sensors ;;
            esac ;;
        stress-ng)   echo stress-ng ;;
        glmark2)     echo glmark2 ;;
        glmark2-es2-drm|glmark2-drm)
            case "$PKG" in apt) echo glmark2-drm ;; *) echo glmark2 ;; esac ;;
        vkmark)      echo vkmark ;;
        clpeak)      echo clpeak ;;
        clinfo)      echo clinfo ;;
        mokutil)     echo mokutil ;;
        decode-dimms) echo i2c-tools ;;
        lshw)        echo lshw ;;
        fio)         echo fio ;;
        *)           echo "$1" ;;
    esac
}

pkg_refresh() {
    [ -n "$OS_PKG_REFRESHED" ] && return 0
    OS_PKG_REFRESHED=1
    case "$PKG" in
        apt)    step "refreshing package index (apt-get update)"
                $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true ;;
        apk)    step "refreshing package index (apk update)"
                $SUDO apk update -q >/dev/null 2>&1 || true ;;
        pacman) step "refreshing package index (pacman -Sy)"
                $SUDO pacman -Syq --noconfirm >/dev/null 2>&1 || true ;;
        *)      : ;;
    esac
}

pkg_install() {
    case "$PKG" in
        apt)    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                    -o Dpkg::Use-Pty=0 "$@" ;;
        apk)    $SUDO apk add --no-cache -q "$@" ;;
        dnf)    $SUDO dnf install -y -q "$@" ;;
        yum)    $SUDO yum install -y -q "$@" ;;
        pacman) $SUDO pacman -S --noconfirm --needed -q "$@" ;;
        zypper) $SUDO zypper --non-interactive --quiet install "$@" ;;
        *)      return 1 ;;
    esac
}

# ensure_cmd <command> [package]   -> 0 if the command is usable afterwards
ensure_cmd() {
    _cmd="$1"
    have "$_cmd" && return 0
    if [ "${NO_INSTALL:-0}" = "1" ]; then
        OS_MISSING="$OS_MISSING $_cmd"; return 1
    fi
    if [ "$OS_ROOT" != "1" ]; then
        OS_MISSING="$OS_MISSING $_cmd"; return 1
    fi
    _pkg="${2:-$(pkg_for "$_cmd")}"
    [ -z "$_pkg" ] && { OS_MISSING="$OS_MISSING $_cmd"; return 1; }
    pkg_refresh
    step "installing $_pkg (provides $_cmd)"
    if pkg_install $_pkg >/dev/null 2>&1 && have "$_cmd"; then
        OS_INSTALLED="$OS_INSTALLED $_pkg"
        return 0
    fi
    OS_MISSING="$OS_MISSING $_cmd"
    return 1
}

# ====================================================================
#  PCI helpers  (lspci -mm is machine readable; sysfs is the fallback)
# ====================================================================
os_lspci_cache() {
    [ -f "$OS_TMP/lspci" ] && return 0
    if ensure_cmd lspci; then
        lspci -mm 2>/dev/null > "$OS_TMP/lspci" || : > "$OS_TMP/lspci"
    else
        : > "$OS_TMP/lspci"
    fi
}

pci_clean() {
    sed -e 's/ Corporation//g' -e 's/ Corp\.//g' -e 's/, Inc\.//g' -e 's/ Inc\.//g' \
        -e 's/ Co\., Ltd\.//g' -e 's/ Technology Group//g' -e 's/ Semiconductor//g' \
        -e 's/\[AMD\/ATI\]/AMD/g' -e 's/Advanced Micro Devices/AMD/g' \
        -e 's/ PCI Express / /g' -e 's/ Controller$//' -e 's/ Network Adapter$//' \
        -e 's/  */ /g' -e 's/^ //' -e 's/ $//'
}

# pci_name 0000:01:00.0 -> "NVIDIA GP106 [GeForce GTX 1060 6GB]"
pci_name() {
    _b=${1#0000:}
    os_lspci_cache
    _n=$(awk -F'"' -v b="$_b" 'index($0, b) == 1 { print $4 " " $6; exit }' "$OS_TMP/lspci" | pci_clean)
    if [ -z "$_n" ] || [ "$_n" = " " ]; then
        _v=$(rd "/sys/bus/pci/devices/$1/vendor"); _d=$(rd "/sys/bus/pci/devices/$1/device")
        _n="${_v#0x}:${_d#0x}"
    fi
    printf '%s' "$_n"
}

# pci_class 0000:01:00.0 -> "VGA compatible controller"
pci_class() {
    _b=${1#0000:}
    os_lspci_cache
    awk -F'"' -v b="$_b" 'index($0, b) == 1 { print $2; exit }' "$OS_TMP/lspci"
}

# compact label for a PCI class, so the class column stays narrow
pci_class_short() {
    case "$1" in
        'VGA compatible controller')          echo "VGA" ;;
        '3D controller')                      echo "3D" ;;
        'Display controller')                 echo "Display" ;;
        'Non-Volatile memory controller')     echo "NVMe" ;;
        'SATA controller')                    echo "SATA" ;;
        'IDE interface')                      echo "IDE" ;;
        'RAID bus controller')                echo "RAID" ;;
        'SCSI storage controller')            echo "SCSI" ;;
        'USB controller')                     echo "USB" ;;
        'Ethernet controller')                echo "Ethernet" ;;
        'Network controller')                 echo "Wi-Fi" ;;
        'Audio device'|'Multimedia audio controller') echo "Audio" ;;
        'PCI bridge')                         echo "PCI bridge" ;;
        'Host bridge')                        echo "Host bridge" ;;
        'ISA bridge')                         echo "ISA bridge" ;;
        'SMBus')                              echo "SMBus" ;;
        'Serial controller')                  echo "Serial" ;;
        'SD Host controller')                 echo "SD host" ;;
        'Signal processing controller')       echo "Signal proc" ;;
        'System peripheral')                  echo "Sys periph" ;;
        'Encryption controller')              echo "Crypto" ;;
        'Communication controller')           echo "Comms" ;;
        'Memory controller')                  echo "Memory" ;;
        '')                                   echo "-" ;;
        *) printf '%s' "$1" | sed -e 's/ controller$//' -e 's/ interface$//' ;;
    esac
}

# PCIe generation from a "8.0 GT/s PCIe" style string
pcie_gen() {
    case "$1" in
        2.5*) echo "Gen1" ;;  5.0*|5\ *) echo "Gen2" ;;  8.0*) echo "Gen3" ;;
        16.0*) echo "Gen4" ;; 32.0*) echo "Gen5" ;;      64.0*) echo "Gen6" ;;
        *) echo "-" ;;
    esac
}

# ====================================================================
#  temperature / frequency / power sensors
#  OS_SYSFS exists so the test suite can point these at a fake tree.
# ====================================================================
OS_SYSFS=${OS_SYSFS:-/sys}
CPU_TEMP_PATH=''
CPU_TEMP_LABEL=''

OS_MODPROBED=''

# A live USB often boots without the hwmon drivers loaded, which leaves the
# machine looking like it has no sensors at all. Nudge the usual suspects.
os_try_sensor_modules() {
    [ -n "$OS_MODPROBED" ] && return 1
    OS_MODPROBED=1
    [ "$OS_ROOT" = "1" ] || return 1
    have modprobe || return 1
    for _m in coretemp k10temp zenpower nct6775 nct6683 jc42 drivetemp; do
        $SUDO modprobe "$_m" 2>/dev/null
    done
    return 0
}

os_find_cpu_temp() {
    [ -n "$CPU_TEMP_PATH" ] && return 0
    if ! os_scan_cpu_temp; then
        os_try_sensor_modules && os_scan_cpu_temp
    fi
    [ -n "$CPU_TEMP_PATH" ]
}

os_scan_cpu_temp() {
    for h in "$OS_SYSFS"/class/hwmon/hwmon*; do
        [ -d "$h" ] || continue
        n=$(rd "$h/name")
        case "$n" in
            coretemp|k10temp|zenpower|k8temp|cpu_thermal|soc_thermal) ;;
            *) continue ;;
        esac
        # prefer the package / Tdie sensor
        for l in "$h"/temp*_label; do
            [ -r "$l" ] || continue
            lv=$(rd "$l")
            case "$lv" in
                'Package id 0'|Tdie|Tctl|CPU)
                    CPU_TEMP_PATH="${l%_label}_input"
                    CPU_TEMP_LABEL="$n/$lv"
                    [ -r "$CPU_TEMP_PATH" ] && return 0 ;;
            esac
        done
        if [ -r "$h/temp1_input" ]; then
            CPU_TEMP_PATH="$h/temp1_input"; CPU_TEMP_LABEL="$n/temp1"; return 0
        fi
    done
    for z in "$OS_SYSFS"/class/thermal/thermal_zone*; do
        [ -r "$z/type" ] || continue
        t=$(rd "$z/type")
        case "$t" in
            x86_pkg_temp|cpu-thermal|cpu_thermal|soc_thermal|acpitz)
                CPU_TEMP_PATH="$z/temp"; CPU_TEMP_LABEL="thermal/$t"; return 0 ;;
        esac
    done
    # last resort: the first hwmon sensor we can find
    for h in "$OS_SYSFS"/class/hwmon/hwmon*/temp1_input; do
        [ -r "$h" ] || continue
        CPU_TEMP_PATH="$h"; CPU_TEMP_LABEL="hwmon (generic)"; return 0
    done
    return 1
}

# millidegrees C, or empty
cpu_temp_mc() { [ -n "$CPU_TEMP_PATH" ] && rd "$CPU_TEMP_PATH"; }

# average current CPU frequency in kHz
cpu_freq_khz() {
    if [ -r "$OS_SYSFS/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq" ]; then
        awk '{ s += $1; n++ } END { if (n) printf "%d\n", s/n }' \
            "$OS_SYSFS"/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null
    else
        awk -F: '/^cpu MHz/ { s += $2; n++ } END { if (n) printf "%d\n", (s/n)*1000 }' \
            /proc/cpuinfo 2>/dev/null
    fi
}

# RAPL energy counter in microjoules (Intel; needs root on recent kernels)
RAPL_PATH=''
os_find_rapl() {
    for p in "$OS_SYSFS"/class/powercap/intel-rapl:0/energy_uj \
             "$OS_SYSFS"/class/powercap/intel-rapl-mmio:0/energy_uj; do
        if [ -r "$p" ]; then RAPL_PATH="$p"; return 0; fi
    done
    return 1
}
rapl_uj() { [ -n "$RAPL_PATH" ] && rd "$RAPL_PATH"; }

# summed in shell rather than awk: an unmatched glob would make awk bail out
# before its END block and print nothing at all
cpu_throttle_count() {
    _n=0
    for _f in "$OS_SYSFS"/devices/system/cpu/cpu*/thermal_throttle/core_throttle_count; do
        [ -r "$_f" ] || continue
        _v=$(rd "$_f")
        case "$_v" in ''|*[!0-9]*) continue ;; esac
        _n=$((_n + _v))
    done
    printf '%s\n' "$_n"
}

# ====================================================================
#  banner / init / footer
# ====================================================================
os_init() {
    OS_SCRIPT="$1"
    os_detect_priv
    os_detect_distro
    printf '\n'
    rule
    printf ' %sonline-script%s %s/%s %s%s\n' \
        "$CB" "$CR" "$CD" "$CR" "$CB$OS_SCRIPT$CR" "$CD  v$OS_VERSION$CR"
    printf ' %shost%s  %s   %skernel%s %s %s\n' \
        "$CD" "$CR" "$(hostname 2>/dev/null || rd /proc/sys/kernel/hostname)" \
        "$CD" "$CR" "$(uname -r 2>/dev/null)" "$(uname -m 2>/dev/null)"
    printf ' %sos%s    %s\n' "$CD" "$CR" "$DISTRO_NAME"
    printf ' %sdate%s  %s   %spriv%s %s\n' "$CD" "$CR" \
        "$(date -u '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null)" "$CD" "$CR" \
        "$([ "$OS_ROOT" = 1 ] && echo root || echo 'unprivileged')"
    rule
    printf '\n'
    if [ "$OS_ROOT" != "1" ]; then
        warn "not running as root - DMI/SMART data and dependency install are unavailable"
        note "re-run as:  curl -fsSL $(os_url "/$OS_SCRIPT.sh") | sudo sh"
        printf '\n'
    fi
}

os_footer() {
    [ -n "$OS_INSTALLED" ] && note "packages installed during this run:$OS_INSTALLED"
    [ -n "$OS_MISSING" ] && warn "tools unavailable (some rows are blank):$OS_MISSING"
    printf '%s  more:%s' "$CD" "$CR"
    printf '%s curl -fsSL %s | sudo sh%s\n' "$CD" "$(os_url /sysinfo.sh)" "$CR"
    printf '%s        curl -fsSL %s   # list every script%s\n' \
        "$CD" "$(os_url /scripts)" "$CR"
    printf '\n'
}

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
