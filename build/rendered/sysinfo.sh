#!/bin/sh
# shellcheck shell=sh disable=SC2086,SC2012,SC3043
#@name        sysinfo
#@title       Hardware inventory
#@description CPU, memory modules, motherboard/BIOS, storage, network, PCIe links, GPU
#@root        recommended
#@params      spd
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

# try_cmd: like ensure_cmd, but for optional extras (load generators). A
# failure here is normal, so it is not reported as a missing tool.
try_cmd() {
    _saved="$OS_MISSING"
    if ensure_cmd "$@"; then
        return 0
    fi
    OS_MISSING="$_saved"
    return 1
}

# ====================================================================
#  PCI helpers  (lspci -mm is machine readable; sysfs is the fallback)
#  OS_SYSFS lets the test suite point every sysfs read at a fake tree.
# ====================================================================
OS_SYSFS=${OS_SYSFS:-/sys}
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
        _v=$(rd "$OS_SYSFS/bus/pci/devices/$1/vendor")
        _d=$(rd "$OS_SYSFS/bus/pci/devices/$1/device")
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
# ====================================================================
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
    [ -n "$OS_MISSING" ] && warn "not installed, so some rows are blank:$OS_MISSING"
    printf '%s  more:%s' "$CD" "$CR"
    printf '%s curl -fsSL %s | sudo sh%s\n' "$CD" "$(os_url /sysinfo.sh)" "$CR"
    printf '%s        curl -fsSL %s   # list every script%s\n' \
        "$CD" "$(os_url /scripts)" "$CR"
    printf '\n'
}

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
