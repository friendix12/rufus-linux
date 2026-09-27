#!/usr/bin/env bash
# ==============================================================================
#  rufus-linux.sh  --  Bootable USB creator for Linux  (Rufus-style)
#
#  Kya karta hai:
#    * ISO image se bootable pendrive banata hai -- bilkul Rufus ki tarah
#    * 3 modes : Auto / ISO-Hybrid (dd) / Partition & Copy
#    * MBR (BIOS + UEFI) aur GPT (UEFI) dono partition schemes
#    * FAT32 / NTFS / ext4 file systems
#    * Live progress bar, checksum verify, aur safety checks
#
#  Usage:
#    sudo ./rufus-linux.sh                       # interactive menu
#    sudo ./rufus-linux.sh -i ubuntu.iso -d /dev/sdb -y
#    sudo ./rufus-linux.sh -i ubuntu.iso -d /dev/sdb -m dd -y --verify
#    sudo ./rufus-linux.sh -h
#
#  NOTE: Linux ISOs ke liye "dd / ISO-Hybrid" mode sabse reliable hai aur
#        default raha hai. Rufus bhi zyada tar Linux ISOs ko isi tarah likhta hai.
# ==============================================================================

set -u
set -o pipefail

VERSION="2.0"
# SELF = khud ka ABSOLUTE path.  zaroori hai kyunki pkexec hamesha cwd ko "/"
# bana deta hai -> relative "./rufus-linux.sh" wahan "No such file" de deta hai.
SELF=${BASH_SOURCE[0]:-$0}
[[ $SELF == /* ]] || SELF="$PWD/$SELF"
if command -v readlink >/dev/null 2>&1; then
    _self=$(readlink -f -- "$SELF" 2>/dev/null || true)
    [[ -n ${_self:-} ]] && SELF=$_self
    unset _self
fi

# ------------------------------- colors ---------------------------------------
if [[ -t 1 ]]; then
    C_RST=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
    C_BLU=$'\033[34m'; C_CYN=$'\033[36m'
else
    C_RST=''; C_B=''; C_DIM=''; C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_CYN=''
fi

# ------------------------------- globals --------------------------------------
ISO=""
DEV=""
SCHEME="mbr"        # mbr | gpt
FS="fat32"          # auto | fat32 | ntfs | ext4
MODE="auto"         # auto | dd | part
VOLLBL=""
# Rufus jaisa auto-fill: user ne option ko khud chhua ya nahi.
# 0 = abhi tak auto recommendation chali aa rahi hai -> auto_defaults_*
#     ise override kar sakta hai.  1 = user/CLI ne khud set kiya -> chhod do.
SCHEME_SET=0
FS_SET=0
MODE_SET=0
VOLLBL_SET=0
DO_VERIFY=0
ASSUME_YES=0
FINALIZE_EJECT=1

# persistence
PERSIST_MB=0            # 0 = OFF
PERSIST_KIND=""         # casper | live | none
PERSIST_PART=""         # persistence partition device
PERSIST_SIZE_MB=0

# Ventoy-style multi-ISO
VENTOY_ENABLED=0
VENTOY_BOOT_PART=""      # FAT32 boot/ESP partition
VENTOY_ISO_PART=""       # storage partition (ISOs yahan)
VENTOY_STORAGE_FS="ext4" # ext4 | ntfs

# GUI
GUI_PROGRESS=0
GUI_FIFO=""
GUI_PID=""
# progress ka phase -- overall 0-100% bar me is step ka hissa
# (Rufus ki tarah har step apna % dikhata hai, seedha 0% pe atka nahi rehta)
GUI_PHASE_BASE=0
GUI_PHASE_SPAN=100
GUI_TOOL=""              # yad | zenity | ""

# CLI action dispatch
ACTION="menu"
DL_ID=""
ADD_ISO=""
VERIFY_FILE=""

TMPDIR_P=""
MNT=""              # target partition mount
ISOMNT=""           # loop-mounted ISO mount

banner() {
    cat <<EOF
${C_CYN}${C_B}
========================================================================
  RUFUS-LINUX  ::  Bootable USB Creator   v${VERSION}
========================================================================
${C_RST}
EOF
}

info() { printf '%s\n' "${C_GRN}[OK]${C_RST}   $*"; }
warn() { printf '%s\n' "${C_YLW}[WARN]${C_RST} $*"; }
err()  { printf '%s\n' "${C_RED}[ERR]${C_RST}  $*" >&2; }
die()  { err "$*"; exit 1; }

# ------------------------------- helpers --------------------------------------
human() {
    local b=${1:-0}
    if   (( b >= 1073741824 )); then printf '%d.%02d GiB' $((b/1073741824)) $(((b%1073741824)*100/1073741824))
    elif (( b >= 1048576 ));    then printf '%d.%02d MiB' $((b/1048576))    $(((b%1048576)*100/1048576))
    elif (( b >= 1024 ));       then printf '%d KiB'     $((b/1024))
    else                              printf '%d B'      "$b"
    fi
}

cleanup() {
    local rc=$?
    # GUI progress window khuli ho to band karo (warna zombie/dialog bachega)
    if declare -F gui_progress_close >/dev/null 2>&1; then
        gui_progress_close 2>/dev/null || true
    fi

    # 1) WRITE wale bachche abhi bhi chal rahe honge (rsync / dd / mount.ntfs /
    #    7z / bsdtar).  Inhe pehle ROKO -- warna dialog band karte hi orphan
    #    process chalta rehta hai aur pendrive par ADHURA data reh jaata hai.
    #    Pattern = sirf humara temp dir, isliye koi aur process nahi marega.
    if [[ -n ${TMPDIR_P:-} && -d ${TMPDIR_P:-} ]]; then
        local kids
        kids=$(pgrep -f -- "$TMPDIR_P" 2>/dev/null | grep -vx -- "$$" || true)
        if [[ -n $kids ]]; then
            # shellcheck disable=SC2086
            kill -TERM $kids 2>/dev/null || true
            sleep 1
            kids=$(pgrep -f -- "$TMPDIR_P" 2>/dev/null | grep -vx -- "$$" || true)
            # shellcheck disable=SC2086
            [[ -n $kids ]] && kill -KILL $kids 2>/dev/null || true
        fi
        # dd ka cmdline me temp dir nahi hota (if=$ISO of=$DEV) -> alag se roko
        if [[ -n ${ISO:-} && -n ${DEV:-} && -f ${ISO:-} ]]; then
            pkill -TERM -f -- "dd if=$ISO of=$DEV" 2>/dev/null || true
        fi
    fi

    # 2) mounts hatao -- busy ho to lazy umount (varna EXIT hamesha fail)
    if [[ -n ${MNT:-} && -d ${MNT:-} ]]; then
        mountpoint -q "$MNT" 2>/dev/null && { umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null; }
    fi
    if [[ -n ${ISOMNT:-} && -d ${ISOMNT:-} ]]; then
        mountpoint -q "$ISOMNT" 2>/dev/null && { umount "$ISOMNT" 2>/dev/null || umount -l "$ISOMNT" 2>/dev/null; }
    fi
    if declare -F ventoy_umount >/dev/null 2>&1; then
        ventoy_umount 2>/dev/null || true
    fi

    # 3) temp dir -- sirf tabhi hatao jab path humara apna ho (guard: rm -rf)
    if [[ -n ${TMPDIR_P:-} && -d ${TMPDIR_P:-} ]]; then
        case $TMPDIR_P in
            /tmp/rufus-linux.*)
                rm -rf -- "$TMPDIR_P" 2>/dev/null || true
                ;;
            *)
                rm -f "$TMPDIR_P"/*.log "$TMPDIR_P"/gui.fifo 2>/dev/null
                rmdir "$TMPDIR_P" 2>/dev/null
                ;;
        esac
    fi
    return $rc
}
trap cleanup EXIT
trap 'echo; warn "User ne cancel kiya."; exit 130' INT TERM

# ------------------------------- deps -----------------------------------------
require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Root chahiye. Chalao:  sudo $0 $*"
}

have() { command -v "$1" >/dev/null 2>&1; }

check_base_deps() {
    local miss=()
    for c in lsblk blkid mount umount dd awk grep sed find sync; do
        have "$c" || miss+=("$c")
    done
    (( ${#miss[@]} )) && die "Missing tools: ${miss[*]}  (util-linux/coreutils install karo)"
}

# ---------------------- disk discovery / safety --------------------------------
# /dev/sda -> sda  (root disk ka top-level name)
top_disk_name() {
    local n=$1 p i
    for i in 1 2 3 4 5 6; do
        p=$(lsblk -ndo PKNAME "/dev/$n" 2>/dev/null | head -1)
        [[ -z $p ]] && break
        n=$p
    done
    printf '%s\n' "$n"
}

root_disk_name() {
    local src
    src=$(findmnt -n -o SOURCE / 2>/dev/null) || { echo ""; return; }
    src=${src%%[*}
    local b=${src##*/}
    # LVM/mapper case -> resolve via lsblk
    if [[ $b == *"/"* || -z $b ]]; then
        b=$(lsblk -ndo PKNAME "$src" 2>/dev/null | head -1)
    fi
    top_disk_name "$b"
}

is_usb_like() {
    local name=$1 tran rm
    tran=$(lsblk -dn -o TRAN "/dev/$name" 2>/dev/null | xargs)
    rm=$(cat "/sys/block/$name/removable" 2>/dev/null || echo 0)
    [[ $tran == usb || $rm == 1 || $tran == "mmcrd" ]]
}

list_removable_disks() {
    local name type size model tran out
    for d in /sys/block/*; do
        [[ -e $d ]] || continue
        name=${d##*/}
        [[ $name =~ ^(loop|ram|zram|sr|fd|dm-|md|nvme[0-9]+n[0-9]+)$ ]] && continue
        [[ -b /dev/$name ]] || continue
        type=$(lsblk -dn -o TYPE "/dev/$name" 2>/dev/null)
        [[ $type == disk ]] || continue
        is_usb_like "$name" || continue
        size=$(lsblk -dn -o SIZE "/dev/$name" 2>/dev/null)
        model=$(lsblk -dn -o MODEL "/dev/$name" 2>/dev/null | xargs)
        printf '%s|%s|%s|%s\n' "$name" "$size" "${model:-n/a}" "$(lsblk -dn -o TRAN /dev/$name | xargs)"
    done
}

unmount_target() {
    local dev=$1 mp p
    while read -r mp; do
        [[ -z $mp || $mp == "[SWAP]" ]] && continue
        umount -l "$mp" 2>/dev/null || true
    done < <(lsblk -ln -o MOUNTPOINT "$dev" 2>/dev/null | grep -v '^$')
    while read -r p; do
        [[ -z $p ]] && continue
        swapoff "/dev/$p" 2>/dev/null || true
    done < <(lsblk -ln -o NAME "$dev" 2>/dev/null | tail -n +2)
    udevadm settle 2>/dev/null || true
}

assert_safe_device() {
    local name=${DEV##*/}
    [[ -b $DEV ]] || die "$DEV ek block device nahi hai."

    # pehle: optical / loop / ram devices -- inpar kabhi mat likho
    # (sirf integration-test ke liye RUFUS_ALLOW_LOOP=1 se bypass hota hai)
    if [[ $name =~ ^(loop|ram|zram|sr|fd) ]]; then
        [[ ${RUFUS_ALLOW_LOOP:-0} == 1 && $name == loop* ]] || \
            die "$DEV optical/loop/ram device hai — uspar likhna allowed nahi hai."
    fi

    local ptype
    ptype=$(lsblk -dn -o TYPE "$DEV" 2>/dev/null)
    if [[ $ptype != disk ]]; then
        die "$DEV poora disk nahi hai (type='$ptype'). Partition ki jagah pura disk select karo (e.g. /dev/sdb, /dev/sdc)."
    fi

    # 1) device ke koi bhi partition root/boot/home par mount to nahi
    local mp
    while read -r mp; do
        [[ -z $mp ]] && continue
        case $mp in
            /|/boot|/boot/*|/home|/home/*|/usr|/usr/*|/var|/var/*)
                die "REFUSED: $DEV par '$mp' mount hai. Yeh system disk lag rahi hai." ;;
        esac
    done < <(lsblk -ln -o MOUNTPOINT "$DEV" 2>/dev/null)

    # 2) yehi disk root ko hold kar rahi hai?
    local rdk
    rdk=$(root_disk_name)
    if [[ -n $rdk && $rdk == "$name" ]]; then
        die "REFUSED: $DEV wahi disk hai jispar root filesystem hai (${rdk}). Barbaad mat karo!"
    fi

    # 3) removable na ho to strict confirm  (-y se skip hota hai)
    if ! is_usb_like "$name" && ! (( ASSUME_YES )); then
        warn "$DEV removable/USB nahi lag rahi (internal disk ho sakti hai)."
        printf '%s' "Type karo exact '${name}' likhkar confirm karne ke liye (ya ENTER cancel): "
        local ans; read -r ans || true
        [[ $ans == "$name" ]] || die "Cancel kiya gaya."
    fi
}

confirm_write() {                # $1 = effective mode (optional)
    (( ASSUME_YES )) && return 0
    local shown_mode=${1:-$MODE}
    [[ $shown_mode == auto ]] && shown_mode="(auto)"
    echo
    printf '%s\n' "${C_YLW}${C_B}!! DHYAN !!${C_RST} -- neeche diya gaya poora disk ERASE ho jayega:"
    printf '   %-14s : %s\n' "Device"  "$DEV"
    printf '   %-14s : %s\n' "Model"   "$(lsblk -dn -o MODEL "$DEV" 2>/dev/null | xargs)"
    printf '   %-14s : %s\n' "Size"    "$(human "$(blockdev --getsize64 "$DEV" 2>/dev/null || echo 0)")"
    printf '   %-14s : %s\n' "ISO"     "${ISO:-<none>}"
    printf '   %-14s : %s\n' "Mode"    "$shown_mode"
    printf '   %-14s : %s\n' "Scheme"  "$SCHEME"
    printf '   %-14s : %s\n' "Filesys" "$FS"
    if (( ${PERSIST_MB:-0} > 0 )); then
        printf '   %-14s : %s\n' "Persistence" "$(persistence_status_text)"
    fi
    echo
    printf '%s' "Aage badhne ke liye device name type karo [${DEV##*/}] : "
    local ans; read -r ans || true
    [[ $ans == "${DEV##*/}" ]] || die "Cancel kiya gaya."
}

# ------------------------------- ISO checks -----------------------------------
iso_size() { stat -c '%s' "$ISO"; }

is_hybrid_iso() {
    local sig
    sig=$(dd if="$ISO" bs=1 skip=510 count=2 status=none 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [[ $sig == "55aa" ]]
}

is_windows_iso() {
    local m=${ISOMNT:-}
    [[ -n $m && -d $m ]] || return 1
    [[ -d $m/sources && ( -f $m/sources/install.wim || -f $m/sources/install.esd ) ]]
}

max_iso_filesize() {
    local m=${ISOMNT:-}
    [[ -n $m && -d $m ]] || { echo 0; return; }
    find "$m" -type f -printf '%s\n' 2>/dev/null | sort -n | tail -1
}

# --------------------- Rufus jaisa AUTO-FILL ----------------------------------
# ISO khud batata hai volume label, aur machine batati hai UEFI hai ya BIOS.
# User sirf ISO chune -> scheme/FS/label/mode sab apne aap baith jayein.

# ISO9660 Primary Volume Descriptor (sector 16) se asli volume label.
# Non-root bhi chalta hai -- koi mount nahi chahiye.
iso_volume_label() {
    local f=${1:-${ISO:-}} sig lbl
    [[ -f $f ]] || return 1
    if have blkid; then
        lbl=$(blkid -p -o value -s LABEL "$f" 2>/dev/null | head -1)
        lbl=$(printf '%s' "$lbl" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [[ -n $lbl ]] && { printf '%s\n' "$lbl"; return 0; }
    fi
    sig=$(dd if="$f" bs=1 skip=32769 count=5 status=none 2>/dev/null)
    [[ $sig == "CD001" ]] || return 1
    lbl=$(dd if="$f" bs=1 skip=32808 count=32 status=none 2>/dev/null \
            | tr -d '\0' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [[ -n $lbl ]] || return 1
    printf '%s\n' "$lbl"
}

# ISO ke andar sabse badi file ka size -- bina mount kiye (7z/bsdtar se).
# FAT32 ki 4GB limit yahin se pakki ho jaati hai.
iso_max_filesize_noroot() {
    local f=${1:-${ISO:-}} t out
    [[ -f $f ]] || { echo 0; return 0; }
    for t in 7z bsdtar; do
        have "$t" || continue
        case $t in
            7z)     out=$(7z l -ba "$f" 2>/dev/null) ;;
            bsdtar) out=$(bsdtar -tvf "$f" 2>/dev/null) ;;
        esac
        [[ -n $out ]] || continue
        if [[ $t == 7z ]]; then
            # 7z -ba:  <date> <time> <attr> <size> <compressed> <name>
            #   (size = 4th column; dir rows me wahan naam hota hai -> chhoot jayega)
            out=$(printf '%s\n' "$out" \
                  | awk '$1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && $4 ~ /^[0-9]+$/ {print $4}' \
                  | sort -n | tail -1)
        else
            # bsdtar -tv: -rw-r--r-- 0 user group SIZE date time name
            out=$(printf '%s\n' "$out" | awk '$1 ~ /^-/ && $5 ~ /^[0-9]+$/ {print $5}' \
                  | sort -n | tail -1)
        fi
        if [[ $out =~ ^[0-9]+$ ]]; then echo "$out"; return 0; fi
    done
    echo 0
}

# ISO bata rahi hai ki kaunsa file system safe hai.
#   $1 = ISO ke andar sabse badi file (bytes)
#   $2 = Windows ISO? (0/1)   -- caller decide karta hai (mounted ya non-root)
recommend_fs() {
    local maxf=${1:-0} win=${2:-0}
    if (( maxf > 4294967295 )); then
        # FAT32 ka 4GB limit toot rahi hai.
        #  Windows + wimsplit -> Rufus ki tarah FAT32 + install.swm split
        #  warna -> NTFS
        if (( win )) && have wimsplit; then
            echo fat32
        else
            echo ntfs
        fi
    else
        echo fat32
    fi
}

# ISO ke andar Windows installer hai? -- bina mount kiye (non-root safe)
iso_looks_windows_noroot() {
    local f=${1:-${ISO:-}} t out
    [[ -f $f ]] || return 1
    for t in bsdtar 7z; do
        have "$t" || continue
        case $t in
            bsdtar) out=$(bsdtar -tf "$f" 2>/dev/null) ;;
            7z)     out=$(7z l -ba "$f" 2>/dev/null) ;;
        esac
        [[ -n $out ]] || continue
        # name columns me path separator ya space dono ho sakta hai
        if printf '%s\n' "$out" | grep -qiE 'sources[/\\]+install\.(wim|esd)([[:space:]]|$)'; then
            return 0
        fi
        return 1
    done
    # listing tool nahi mila -> filename/label heuristic
    local hay
    hay="$(basename "$f") $(iso_volume_label "$f" 2>/dev/null)"
    printf '%s' "$hay" | grep -qiE 'windows|win1[01]|win11|x64fre|ccsa|cccoma' && return 0
    return 1
}

# FS=auto resolve karo.  Root ho to mounted ISO se (exact), warna non-root
# listing se (7z/bsdtar).  Dono hi same jawab dete hain.
resolve_fs_auto() {
    local f=${1:-${ISO:-}} maxf=0 win=0
    if [[ -n ${ISOMNT:-} && -d ${ISOMNT:-} ]] && mountpoint -q "$ISOMNT" 2>/dev/null; then
        maxf=$(max_iso_filesize)
        is_windows_iso && win=1
    fi
    if (( maxf <= 0 )); then maxf=$(iso_max_filesize_noroot "$f"); fi
    if (( ! win )); then iso_looks_windows_noroot "$f" && win=1; fi
    recommend_fs "$maxf" "$win"
}

# ISO chalte hi (ya CLI me -i dete hi) sab auto-fill kar do.
# *_SET flags user/CLI ke explicitly diye gaye values ko protect karte hain.
auto_defaults_from_iso() {
    # --- machine based (ISO abhi na bhi ho to chalega) ---
    if (( ! ${SCHEME_SET:-0} )); then
        # UEFI machine -> GPT (Rufus ka modern default), BIOS -> MBR
        if [[ -d /sys/firmware/efi ]]; then SCHEME=gpt; else SCHEME=mbr; fi
    fi
    (( ${MODE_SET:-0} )) || MODE=auto          # hybrid? do_start khud decide karega

    # --- ISO based ---
    [[ -f ${ISO:-} ]] || return 0
    if [[ -z ${VOLLBL:-} ]]; then
        VOLLBL=$(iso_volume_label "$ISO" 2>/dev/null || true)
    fi
    if (( ! ${FS_SET:-0} )); then
        FS=auto                                 # write time pe ISO dekh kar finalise
    fi
    return 0
}

# ------------------------------- progress -------------------------------------
draw_bar() {
    local done=$1 total=$2 label=$3
    (( total > 0 )) || return 0
    (( done > total )) && done=$total
    local pct=$(( done * 100 / total ))
    local width=40
    local filled=$(( pct * width / 100 ))
    local bar
    bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' $((width - filled)) '' | tr ' ' '-')"
    printf '\r  %s%-14s%s [%s] %3d%%  %s / %s   ' \
        "$C_CYN" "$label" "$C_RST" "$bar" "$pct" "$(human "$done")" "$(human "$total")"
}

# ---- phase-aware progress ---------------------------------------------------
# Rufus ki tarah overall 0-100% bar ko steps me baanta jaata hai.  Agar har
# step seedha 0% se shuru ho to user ko lagta hai "kuch dikh nahi raha".
# gui_phase <start%> <span%>  ->  agla step overall bar me [base, base+span).
gui_phase() {
    GUI_PHASE_BASE=${1:-0}
    GUI_PHASE_SPAN=${2:-100}
}

# $1 = phase ke andar 0-100, $2 = dikhane wala text   (sirf GUI dialog)
progress_text() {
    (( ${GUI_PROGRESS:-0} )) || return 0
    local pct=${1:-0} text=${2:-}
    local base=${GUI_PHASE_BASE:-0} span=${GUI_PHASE_SPAN:-100}
    local gpct=$(( base + pct * span / 100 ))
    (( gpct > 100 )) && gpct=100
    if declare -F gui_progress_set >/dev/null 2>&1; then
        gui_progress_set "$gpct" "$text"
    fi
}

# $1 = bytes done, $2 = bytes total, $3 = label
# GUI dialog me % + CLI me ASCII bar -- dono jagah yehi function chalata hai.
progress_report() {
    local done=${1:-0} total=${2:-0} label=${3:-} pct=0
    (( total > 0 )) && pct=$(( done * 100 / total ))
    (( pct > 100 )) && pct=100
    if (( ${GUI_PROGRESS:-0} )); then
        local base=${GUI_PHASE_BASE:-0} span=${GUI_PHASE_SPAN:-100}
        local gpct=$(( base + pct * span / 100 ))
        (( gpct > 100 )) && gpct=100
        if declare -F gui_progress_set >/dev/null 2>&1; then
            gui_progress_set "$gpct" "$label  $(human "$done") / $(human "$total")"
        fi
    else
        draw_bar "$done" "$total" "$label"
    fi
}

# dd/cmp jaise background process ka PID dekar live % dikhata hai
# (/proc/pid/io se bytes padhkar).  $4 = kaunsa counter (wchar | rchar).
# GUI mode me wahi % zenity/yad window ko bhejta hai.
progress_watch() {
    local pid=$1 total=$2 label=$3 iof=${4:-wchar}
    local written=0 prev=0 pct=0 lastpct=-1
    while kill -0 "$pid" 2>/dev/null; do
        written=$(awk "/^$iof:/{print \$2}" "/proc/$pid/io" 2>/dev/null)
        [[ -z $written ]] && written=$prev
        prev=$written
        if (( total > 0 )); then
            pct=$(( written * 100 / total ))
            (( pct > 100 )) && pct=100
        fi
        if (( pct != lastpct )); then
            progress_report "$written" "$total" "$label"
            lastpct=$pct
        fi
        sleep 0.3
    done
    progress_report "$total" "$total" "$label"
    (( ${GUI_PROGRESS:-0} )) || printf '\n'
}

# rsync --info=progress2 ka output padh kar progress_report me badalta hai.
#   $1 = error/odd line yahan likhte jao (fail hone par print hoga)
# stdin = rsync output
rsync_progress_feed() {
    local errf=${1:-} line pct
    while IFS= read -r line; do
        if [[ $line =~ ([0-9][0-9]*)% ]]; then
            pct=${BASH_REMATCH[1]}
            (( pct > 100 )) && pct=100
            if (( ${GUI_PROGRESS:-0} )); then
                progress_text "$pct" "ISO files copy ho rahi hain...  ${pct}%"
            else
                local base=${GUI_PHASE_BASE:-0} span=${GUI_PHASE_SPAN:-100}
                local gpct=$(( base + pct * span / 100 ))
                (( gpct > 100 )) && gpct=100
                printf '\r  %-14s %3d%%   (ISO files: %3d%%)   ' \
                       "Copying" "$gpct" "$pct"
            fi
        elif [[ -n $errf && -n $line ]]; then
            printf '%s\n' "$line" >> "$errf"
        fi
    done
    if (( ${GUI_PROGRESS:-0} )); then
        progress_text 100 "ISO files copy ho gayi hain."
    else
        printf '\n'
    fi
}

# ------------------------------- dd mode --------------------------------------
do_dd_write() {
    local total
    total=$(iso_size)
    local devsize
    devsize=$(blockdev --getsize64 "$DEV" 2>/dev/null || echo 0)
    (( total > devsize )) && die "ISO ($(human $total)) device ($(human $devsize)) se bada hai."

    echo
    info "ISO ko seedhe device par likh raha hoon (ISO-Hybrid / dd mode)..."
    local log="$TMPDIR_P/dd.log"
    : > "$log"

    sync
    progress_text 0 "ISO ko device par likh raha hoon (dd)..."
    dd if="$ISO" of="$DEV" bs=4M conv=fsync status=none 2>"$log" &
    local ddpid=$!
    progress_watch "$ddpid" "$total" "Writing"
    wait "$ddpid"
    local rc=$?
    sync

    if (( rc != 0 )); then
        echo
        err "dd fail hua (exit $rc):"
        cat "$log" >&2
        exit $rc
    fi
    partprobe "$DEV" 2>/dev/null || blockdev --rereadpt "$DEV" 2>/dev/null || true
    info "Likha ja chuka hai."
}

verify_dd() {
    local total; total=$(iso_size)
    echo
    info "Verify kar raha hoon (device vs ISO)..."
    progress_text 0 "Verify ho raha hai..."
    # cmp dono file padhta hai -> rchar total ka lagbhag 2 guna hota hai
    cmp -n "$total" -s "$DEV" "$ISO" &
    local cmpid=$!
    progress_watch "$cmpid" "$(( total * 2 ))" "Verify" rchar
    wait "$cmpid"
    local rc=$?
    if (( rc == 0 )); then
        info "VERIFIED: device aur ISO bilkul same hain. ✔"
        progress_text 100 "Verify OK"
    else
        warn "VERIFY FAILED: data match nahi hua. Dobara likho."
        return 1
    fi
}

# ------------------------------- partition mode --------------------------------
make_partition() {
    local dev=$1 lbl=$2 fs=$3

    unmount_target "$dev"
    wipefs -af "$dev" >/dev/null 2>&1 || true

    if have parted; then
        if [[ $lbl == gpt ]]; then
            parted -s "$dev" mklabel gpt || die "parted mklabel gpt fail"
            parted -s "$dev" mkpart primary "$fs" 1MiB 100% || die "parted mkpart fail"
            parted -s "$dev" set 1 esp on || true
        else
            parted -s "$dev" mklabel msdos || die "parted mklabel msdos fail"
            parted -s "$dev" mkpart primary "$fs" 1MiB 100% || die "parted mkpart fail"
            parted -s "$dev" set 1 boot on || true
        fi
    elif have sfdisk; then
        if [[ $lbl == gpt ]]; then
            printf 'label: gpt\n' | sfdisk -q "$dev" || die "sfdisk fail"
            printf 'start=2048, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B\n' | sfdisk -q -a "$dev" || die "sfdisk part fail"
        else
            printf 'label: dos\n' | sfdisk -q "$dev" || die "sfdisk fail"
            local t=c; [[ $fs == ntfs ]] && t=7
            printf 'start=2048, type=%s, bootable\n' "$t" | sfdisk -q -a "$dev" || die "sfdisk part fail"
        fi
    else
        die "parted ya sfdisk chahiye (partition mode ke liye)."
    fi

    blockdev --rereadpt "$dev" 2>/dev/null || true
    partprobe "$dev" 2>/dev/null || true
    udevadm settle 2>/dev/null || sleep 1

    local part
    if [[ ${dev##*/} =~ [0-9]$ ]]; then part="${dev}p1"; else part="${dev}1"; fi

    local i
    for i in $(seq 1 40); do
        [[ -b $part ]] && break
        sleep 0.25
    done
    [[ -b $part ]] || die "$part nahi mila (partitioning fail)."
    printf '%s\n' "$part"
}

format_part() {
    local part=$1 fs=$2 label=$3
    case $fs in
        fat32)
            have mkfs.vfat || die "mkfs.vfat chahiye (dosfstools package)."
            mkfs.vfat -F 32 -n "$label" "$part" >/dev/null || die "mkfs.vfat fail"
            ;;
        ntfs)
            have mkfs.ntfs || die "mkfs.ntfs chahiye (ntfs-3g package)."
            mkfs.ntfs -f -L "$label" "$part" >/dev/null || die "mkfs.ntfs fail"
            ;;
        ext4)
            have mkfs.ext4 || die "mkfs.ext4 chahiye (e2fsprogs)."
            mkfs.ext4 -F -L "$label" "$part" >/dev/null || die "mkfs.ext4 fail"
            ;;
    esac
}

mount_iso() {
    [[ -n $ISOMNT ]] && umount "$ISOMNT" 2>/dev/null
    mkdir -p "$ISOMNT"
    mount -o loop,ro "$ISO" "$ISOMNT" 2>/dev/null && return 0
    warn "loop-mount fail; bsdtar/xorriso/7z fallback use hoga."
    return 1
}

copy_iso_contents() {
    local dst=$1
    if [[ -n ${ISOMNT:-} && -d $ISOMNT ]] && mountpoint -q "$ISOMNT" 2>/dev/null; then
        # rsync ka progress2 output seedha progress bar me daal do
        # (warna user ko sirf 0% dikhta rehta hai aur lagta hai atak gaya)
        if have rsync && rsync --info=progress2 --version >/dev/null 2>&1; then
            ensure_tmpdir
            local errf="$TMPDIR_P/copy.err" rc=0
            : > "$errf"
            rsync -a --info=progress2 "$ISOMNT"/ "$dst"/ 2>&1 \
                | rsync_progress_feed "$errf"
            rc=${PIPESTATUS[0]}
            if (( rc != 0 )); then
                echo
                [[ -s $errf ]] && cat "$errf" >&2
            fi
            return $rc
        fi
        if have rsync; then
            rsync -a "$ISOMNT"/ "$dst"/
        else
            echo "  (files copy ho rahe hain -- thoda wait karo)"
            cp -a "$ISOMNT"/. "$dst"/
        fi
        return $?
    fi
    local t
    for t in bsdtar xorriso 7z; do
        have "$t" || continue
        case $t in
            bsdtar)  bsdtar -xf "$ISO" -C "$dst" 2>/dev/null && return 0 ;;
            xorriso) xorriso -osirrox on -indev "$ISO" -extract / "$dst" >/dev/null 2>&1 && return 0 ;;
            7z)      7z x -y "-o$dst" "$ISO" >/dev/null 2>&1 && return 0 ;;
        esac
    done
    die "ISO extract nahi ho payi. (loop-mount fail + bsdtar/xorriso/7z bhi fail).
        -> 'sudo apt install libarchive-tools' ya 'xorriso' install karo,
           aur check karo ki file sahi ISO hai."
}

find_sys_file() {
    local n=$1 d
    for d in /usr/lib/syslinux/modules/bios /usr/lib/syslinux/mbr /usr/lib/syslinux \
             /usr/lib/syslinux/bios /usr/share/syslinux /usr/share/syslinux/mbr /boot/syslinux; do
        [[ -f $d/$n ]] && { echo "$d/$n"; return 0; }
    done
    return 1
}

find_mbr_bin() {
    local kind=$1 f d
    local names
    if [[ $kind == gpt ]]; then names=(gptmbr.bin mbr.bin); else names=(mbr.bin gptmbr.bin); fi
    for f in "${names[@]}"; do
        for d in /usr/lib/syslinux/mbr /usr/share/syslinux/mbr /usr/lib/syslinux /usr/share/syslinux; do
            [[ -f $d/$f ]] && { echo "$d/$f"; return 0; }
        done
    done
    return 1
}

install_bios_boot() {
    local dev=$1 part=$2 mnt=$3 scheme=$4

    local mbrbin
    if ! mbrbin=$(find_mbr_bin "$scheme"); then
        warn "syslinux MBR boot code nahi mila -- BIOS boot kaam nahi karega."
        warn "  Fix: 'syslinux' package install karo (apt/dnf/pacman)."
        return 1
    fi
    dd if="$mbrbin" of="$dev" bs=440 count=1 conv=notrunc status=none || {
        warn "MBR boot code likhne me fail."
        return 1
    }

    # isolinux dir dhoondho (jahan isolinux.bin hai)
    local iso_dir rel
    iso_dir=$(find "$mnt" -maxdepth 2 -name isolinux.bin -printf '%h\n' 2>/dev/null | head -1)

    if [[ -n $iso_dir ]]; then
        # .c32 modules + configs ko root pe copy karo, taaki syslinux unhe utha sake
        cp -f "$iso_dir"/*.c32 "$mnt"/ 2>/dev/null || true
        cp -f "$iso_dir"/*.cfg "$mnt"/ 2>/dev/null || true
        cp -f "$iso_dir"/*.msg "$mnt"/ 2>/dev/null || true
        cp -f "$iso_dir"/vmlinuz "$mnt"/ 2>/dev/null || true
        cp -f "$iso_dir"/initrd.* "$mnt"/ 2>/dev/null || true
        # kernel/initrd agar sirf isolinux/ me hain to root pe bhi daal do
        rel=${iso_dir#"$mnt"/}
        [[ $rel == "$mnt" ]] && rel=""
        if [[ -f $mnt/isolinux.cfg ]]; then
            printf 'INCLUDE isolinux.cfg\n' > "$mnt/syslinux.cfg"
        elif [[ -n $rel && -f $mnt/$rel/isolinux.cfg ]]; then
            printf 'INCLUDE %s/isolinux.cfg\n' "$rel" > "$mnt/syslinux.cfg"
        fi
    fi

    # ldlinux.c32 zaroori hai (syslinux 6.x)
    if [[ ! -f $mnt/ldlinux.c32 ]]; then
        local ldc
        ldc=$(find_sys_file ldlinux.c32 || true)
        [[ -n $ldc ]] && cp -f "$ldc" "$mnt"/ || warn "ldlinux.c32 nahi mila (syslinux package install karo)."
    fi

    sync

    if [[ $scheme == gpt ]]; then
        warn "GPT = UEFI-only. Legacy BIOS boot ke liye MBR scheme use karo."
        return 0
    fi

    if [[ $FS == ext4 ]]; then
        if have extlinux; then
            extlinux --install "$mnt" >/dev/null 2>&1 || warn "extlinux install fail."
        else
            warn "extlinux nahi mila -- BIOS boot nahi banega."
        fi
    else
        if have syslinux; then
            syslinux --install "$part" >/dev/null 2>&1 || warn "syslinux install fail."
        else
            warn "syslinux nahi mila -- BIOS boot nahi banega (package: syslinux)."
        fi
    fi
    sync
}

ensure_uefi_bootfile() {
    local mnt=$1
    # zyada tar Linux ISOs me /EFI/BOOT/BOOTX64.EFI hota hi hai
    if [[ -f $mnt/EFI/BOOT/BOOTX64.EFI || -f $mnt/efi/boot/bootx64.efi ]]; then
        info "UEFI boot file mili: EFI/BOOT/BOOTX64.EFI"
        return 0
    fi
    warn "EFI/BOOT/BOOTX64.EFI nahi mili -- UEFI boot shayad na chale."
    return 1
}

handle_big_windows_files() {
    local mnt=$1
    local wim="$mnt/sources/install.wim"
    [[ -f $wim ]] || return 0
    local sz; sz=$(stat -c '%s' "$wim")
    (( sz <= 4294967295 )) && return 0     # FAT32 ka 4GB limit

    if [[ $FS == fat32 ]]; then
        if have wimsplit; then
            info "install.wim > 4GB hai -- FAT32 limit ke liye split kar raha hoon (Rufus bhi yahi karta hai)..."
            wimsplit "$wim" "$mnt/sources/install.swm" 3800 && rm -f "$wim"
        else
            warn "install.wim 4GB se bada hai aur FAT32 usse boot nahi kar payega."
            warn "  Fix: 'wimlib-imagex' install karo (wimsplit), ya NTFS use karo."
        fi
    fi
}

do_partition_write() {
    local dev=$1
    local isosz; isosz=$(iso_size)

    # ---- pre-checks (sab loop-mount karke) ----
    local mounted_iso=0
    gui_phase 0 8
    progress_text 0 "ISO check ho rahi hai..."
    if mount_iso; then mounted_iso=1; fi

    local maxf=0
    maxf=$(max_iso_filesize)
    # mount fail ho gaya to bhi size chahiye -- 7z/bsdtar se nikaalo
    if (( maxf <= 0 )); then
        maxf=$(iso_max_filesize_noroot "$ISO")
    fi

    # ---- FS=auto -> ISO ke andar dekh kar decide (Rufus jaisa) ----
    if [[ $FS == auto ]]; then
        FS=$(resolve_fs_auto "$ISO")
        info "Auto file system -> $FS   (sabse badi file: $(human "$maxf"))"
        progress_text 5 "Auto file system -> $FS"
        if (( maxf > 4294967295 )) && [[ $FS == ntfs && $SCHEME == gpt ]]; then
            warn "ISO me 4GB+ file hai -> NTFS. GPT+NTFS se UEFI boot nahi chalega."
            warn "  Do: (a) 'sudo apt install wimlib' karo (FAT32 + wimsplit chalega)"
            warn "      (b) ya -p mbr (legacy BIOS) use karo."
        fi
    fi

    if [[ $FS == fat32 && $maxf -gt 4294967295 ]]; then
        if is_windows_iso && have wimsplit; then
            warn "Windows ISO me 4GB+ file hai -- FAT32 limit ke liye split kiya jayega."
        elif is_windows_iso; then
            warn "install.wim 4GB+ hai aur 'wimsplit' nahi mila -> FAT32 me nahi aayega."
            warn "  Fix: sudo apt install wimlib   (phir FAT32 + split chalega)"
            (( mounted_iso )) && umount "$ISOMNT" 2>/dev/null
            die "FAT32 me 4GB+ file nahi aayegi. -f ntfs use karo ya wimlib install karo."
        else
            (( mounted_iso )) && umount "$ISOMNT" 2>/dev/null
            die "ISO ke andar 4GB se bada file hai; FAT32 me nahi aayega. NTFS choose karo."
        fi
    fi

    local lbl
    lbl=$(sanitize_label "${VOLLBL:-}")

    local devsz; devsz=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)

    # ---- persistence layout (2 partition) ----
    local part="" persist_on=0
    if (( ${PERSIST_MB:-0} > 0 )); then
        if ! persistence_is_supported "${PERSIST_KIND:-}"; then
            PERSIST_KIND=$(persistence_kind "$ISOMNT")
        fi
        if ! persistence_is_supported "${PERSIST_KIND:-}"; then
            warn "ISO persistence support nahi karti -- single partition me write kar raha hoon."
            persistence_reset
        fi
    fi
    if (( ${PERSIST_MB:-0} > 0 )); then
        persist_on=1
        if [[ $SCHEME != mbr ]]; then
            warn "Persistence ke liye MBR scheme chahiye (BIOS+UEFI) -- GPT ignore ho raha hai."
            SCHEME=mbr
        fi
        if [[ $FS != fat32 ]]; then
            warn "Persistence ke liye boot partition FAT32 chahiye -- FS = fat32 kar diya."
            FS=fat32
        fi
    fi

    echo
    gui_phase 8 7
    if (( persist_on )); then
        progress_text 0 "Partition + persistence bana raha hoon..."
        info "Partition plan: MBR / FAT32 boot + ext4 persistence (${PERSIST_MB} MB)"
        part=$(make_partition_persist "$dev" "$lbl" fat32 "$PERSIST_MB" "$isosz" "$devsz") || exit 1
        info "Partition bani: $part  (+ persistence $PERSIST_PART)"
    else
        progress_text 0 "Partition table + format ($SCHEME / $FS)..."
        info "Partition table bana raha hoon ($SCHEME / $FS)..."
        part=$(make_partition "$dev" "$SCHEME" "$FS") || exit 1
        info "Partition bani: $part"
        format_part "$part" "$FS" "$lbl"
    fi
    progress_text 100 "Format complete."

    mkdir -p "$MNT"
    mount "$part" "$MNT" || die "partition mount fail."
    info "Files copy ho rahe hain..."
    gui_phase 15 77                     # copy = overall 15% se 92% tak
    progress_text 0 "ISO files copy ho rahi hain..."
    copy_iso_contents "$MNT" || die "file copy fail."
    sync
    progress_text 100 "ISO files copy ho gayi hain."

    handle_big_windows_files "$MNT"

    if (( persist_on )); then
        local p; p=$(persistence_param_for "${PERSIST_KIND:-}")
        add_boot_param "$MNT" "$p" || warn "Kernel cmdline me '$p' add nahi hua."
        persistence_finish "$PERSIST_PART"
    fi

    gui_phase 92 6
    progress_text 0 "Boot files install ho rahe hain..."
    if [[ $SCHEME == mbr ]]; then
        install_bios_boot "$dev" "$part" "$MNT" "$SCHEME"
    else
        info "GPT scheme: UEFI-only boot (BIOS legacy nahi chalega)."
    fi
    ensure_uefi_bootfile "$MNT" || true
    progress_text 100 "Boot files ready."

    gui_phase 98 2
    progress_text 50 "Sync ho raha hai (data safe karne ke liye)..."
    sync
    umount "$MNT" 2>/dev/null || true
    (( mounted_iso )) && umount "$ISOMNT" 2>/dev/null
    progress_text 100 "Sync complete."
    gui_phase 100 1

    blockdev --rereadpt "$dev" 2>/dev/null || true
    partprobe "$dev" 2>/dev/null || true
    if (( persist_on )); then
        info "Partition mode complete (with persistence: ${PERSIST_SIZE_MB} MB, label=$(persistence_label_for "${PERSIST_KIND:-}"))"
    else
        info "Partition mode complete."
    fi
}

sanitize_label() {
    local s=${1:-}
    [[ -z $s ]] && s=$(basename "$ISO" .iso)
    s=$(printf '%s' "$s" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9_-' )
    s=${s:0:11}
    [[ -z $s ]] && s="BOOT_USB"
    printf '%s\n' "$s"
}

# ------------------------------- temp dirs ------------------------------------
ensure_tmpdir() {
    [[ -n ${TMPDIR_P:-} && -d ${TMPDIR_P:-} ]] && return 0
    TMPDIR_P=$(mktemp -d /tmp/rufus-linux.XXXXXX) || die "temp dir nahi bani"
    MNT="$TMPDIR_P/mnt"
    ISOMNT="$TMPDIR_P/iso"
    mkdir -p "$MNT" "$ISOMNT"
}

# ------------------------------- main flow -------------------------------------
do_start() {
    [[ -n $ISO  ]] || die "ISO select karo (pehla menu item)."
    [[ -f $ISO  ]] || die "ISO file nahi mili: $ISO"
    [[ -n $DEV  ]] || die "USB device select karo (doosra menu item)."

    ensure_tmpdir
    check_base_deps

    # Rufus jaisa auto-fill: jo user/CLI ne khud set nahi kiya wo yahan se
    # (UEFI machine -> GPT, ISO se volume label, FS -> auto).
    auto_defaults_from_iso
    gui_phase 0 3
    progress_text 0 "ISO check ho rahi hai..."

    # ---- mode finalise ----
    local eff="$MODE"
    if [[ $eff == auto ]]; then
        if is_hybrid_iso; then
            eff=dd
            info "Auto detect: ISO hybrid hai -> ISO-Hybrid (dd) mode."
        else
            eff=part
            info "Auto detect: ISO hybrid nahi hai -> Partition & Copy mode."
        fi
    else
        [[ $eff == dd ]] && ! is_hybrid_iso && \
            warn "Yeh ISO hybrid lag nahi rahi -- dd mode me boot na ho. Phir bhi likh raha hoon..."
    fi

    [[ $eff == dd && $SCHEME == gpt && $MODE == dd ]] && \
        warn "dd mode me MBR/GPT selection ignore hota hai (ISO ka apna layout use hota hai)."

    # ---- persistence (sirf Partition & Copy mode) ----
    if [[ $eff == part ]] && (( ${PERSIST_MB:-0} == 0 )); then
        local iso_mounted=0
        mount_iso && iso_mounted=1
        persistence_ask
        (( iso_mounted )) && umount "$ISOMNT" 2>/dev/null
    elif [[ $eff == dd ]] && (( ${PERSIST_MB:-0} > 0 )); then
        warn "Persistence sirf Partition & Copy mode me kaam karta hai -- dd mode me skip ho raha hai."
        persistence_reset
    fi

    assert_safe_device
    confirm_write "$eff"
    unmount_target "$DEV"

    echo
    gui_phase 3 3
    progress_text 0 "Settings final ho rahe hain..."
    printf '%s\n' "${C_B}------------------------------------------------------------------------${C_RST}"
    printf '%s\n' "${C_B}  START  ->  $eff mode${C_RST}"
    printf '%s\n' "${C_B}------------------------------------------------------------------------${C_RST}"

    local t0=$SECONDS
    if [[ $eff == dd ]]; then
        # dd = 6% se shuru; verify ho to wo 94-100% lega
        if (( DO_VERIFY )); then gui_phase 6 88; else gui_phase 6 94; fi
        do_dd_write
        (( DO_VERIFY )) && verify_dd
    else
        do_partition_write "$DEV"
    fi

    local el=$(( SECONDS - t0 ))
    sync
    (( FINALIZE_EJECT )) && eject "$DEV" 2>/dev/null

    echo
    printf '%s\n' "${C_GRN}${C_B}========================================================================${C_RST}"
    printf '%s\n' "${C_GRN}${C_B}  DONE -- Bootable USB tayyar hai!  ($(( el/60 ))m $(( el%60 ))s)${C_RST}"
    printf '%s\n' "${C_GRN}${C_B}========================================================================${C_RST}"
    printf '  Device : %s\n' "$DEV"
    printf '  Mode   : %s\n' "$eff"
    printf '  Scheme : %s\n' "$SCHEME"
    printf '  FS     : %s\n' "$FS"
    printf '\n  Ab USB laga kar reboot karo (BIOS boot menu: F12/ESC/F8).\n\n'
}

# ------------------------------- interactive UI --------------------------------
pick_device() {
    local items=() i=1 line name size model tran
    while IFS='|' read -r name size model tran; do
        [[ -z $name ]] && continue
        items+=("$name")
        printf '  %s[%d]%s  /dev/%-8s %-8s %-25s (%s)\n' "$C_B" "$i" "$C_RST" "$name" "$size" "$model" "${tran:-n/a}"
        i=$((i+1))
    done < <(list_removable_disks)

    if (( ${#items[@]} == 0 )); then
        warn "Koi USB/removable disk nahi mili. Pendrive laga kar dobara try karo."
        return 1
    fi

    local ans
    printf '  Device number chuno (1-%d, ENTER=cancel): ' "${#items[@]}"
    read -r ans || return 1
    [[ -z $ans ]] && return 1
    [[ $ans =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#items[@]} )) || { warn "Ghalat choice."; return 1; }
    DEV="/dev/${items[ans-1]}"
    info "Selected: $DEV"
}

pick_iso() {
    local p
    printf '  ISO file ka path paste karo (ENTER=cancel): '
    read -r p || return 1
    p=${p//\~/~}
    [[ -z $p ]] && return 1
    p=${p%\"}; p=${p#\"}
    if [[ ! -f $p ]]; then warn "File nahi mili: $p"; return 1; fi
    ISO=$p
    if is_hybrid_iso; then
        info "ISO: $(basename "$ISO")  [hybrid: YES]"
    else
        warn "ISO: $(basename "$ISO")  [hybrid: NO -> partition mode better rahega]"
    fi
    printf '  Volume label (ENTER = auto): '
    read -r VOLLBL || true
}

cycle_scheme() {
    if [[ $SCHEME == mbr ]]; then SCHEME=gpt; else SCHEME=mbr; fi
}

cycle_fs() {
    case $FS in fat32) FS=ntfs;; ntfs) FS=ext4;; *) FS=fat32;; esac
}

cycle_mode() {
    case $MODE in auto) MODE=dd;; dd) MODE=part;; *) MODE=auto;; esac
}

persistence_cycle() {            # menu [7]
    if (( ${PERSIST_MB:-0} > 0 )); then
        persistence_reset
        info "Persistence OFF."
        return 0
    fi
    [[ -z ${ISO:-} || ! -f ${ISO:-} ]] && { warn "Pehle ISO select karo."; return 1; }
    ensure_tmpdir
    local im=0
    mount_iso && im=1
    local kind
    kind=$(persistence_kind "$ISOMNT")
    (( im )) && umount "$ISOMNT" 2>/dev/null

    if ! persistence_is_supported "$kind"; then
        warn "Is ISO me persistence supported nahi (Ubuntu / Mint / Debian Live chahiye)."
        warn "  Detected layout: $kind"
        return 1
    fi
    printf '  Persistence size in MB (kam se kam 256, ENTER=cancel): '
    local a
    read -r a || return 1
    [[ -z $a ]] && return 1
    [[ $a =~ ^[0-9]+$ ]] || { warn "Ghalat number."; return 1; }
    (( a < 256 )) && { warn "Kam se kam 256 MB."; return 1; }
    PERSIST_MB=$a
    PERSIST_KIND=$kind
    info "Persistence ON: $a MB  (partition label: $(persistence_label_for "$kind"))"
    [[ $MODE == dd || $MODE == auto ]] && warn "Note: persistence ke liye 'Partition & Copy' mode use hoga (auto me khud switch ho jayega)."
}

verify_current_iso() {
    local f=${ISO:-}
    if [[ -z $f || ! -f $f ]]; then
        printf '  ISO file ka path: '
        read -r f
        f=${f//\~/~}; f=${f%\"}; f=${f#\"}
    fi
    [[ -f $f ]] || { warn "File nahi mili."; return 1; }
    ensure_tmpdir
    dl_verify_existing "$f"
}

interactive_menu() {
    local c
    while true; do
        [[ -t 1 ]] && printf '\033[H\033[2J'
        banner
        # menu item: key, label, value  (labels aligned at 21 chars)
        mi() { printf '  %s[%s]%s  %-24s: %s\n' "$C_B" "$1" "$C_RST" "$2" "$3"; }

        mi 1 "ISO image select" \
            "$([[ -n $ISO ]] && printf '%s' "$ISO" || printf '%s%s%s' "$C_DIM" "(none)" "$C_RST")"
        mi 2 "USB device select" \
            "$([[ -n $DEV ]] && printf '%s' "$DEV" || printf '%s%s%s' "$C_DIM" "(none)" "$C_RST")"
        mi 3 "Partition scheme" \
            "$( [[ $SCHEME == mbr ]] && echo 'MBR  (BIOS + UEFI)' || echo 'GPT  (UEFI only)' )"
        mi 4 "File system" \
            "$( case $FS in
                 fat32) echo 'FAT32  (BIOS + UEFI, recommended)' ;;
                 ntfs)  echo 'NTFS   (files >4GB, UEFI boot limited)' ;;
                 *)     echo 'ext4   (BIOS only)' ;; esac )"
        mi 5 "Write mode" \
            "$( case $MODE in
                 auto) echo 'Auto (hybrid? -> dd : partition+copy)' ;;
                 dd)   echo 'ISO-Hybrid / dd  (recommended for Linux)' ;;
                 *)    echo 'Partition & Copy' ;; esac )"
        mi 6 "Verify after write" \
            "$( ((DO_VERIFY)) && echo ON || echo OFF )"
        mi 7 "Persistence (live save)" \
            "$( (( ${PERSIST_MB:-0} > 0 )) && printf '%s' "$(persistence_status_text)" || printf '%s%s%s' "$C_DIM" "OFF" "$C_RST" )"
        printf '  %s[8]%s  %sSTART%s  <-- likhna shuru karo\n' "$C_B" "$C_RST" "$C_GRN$C_B" "$C_RST"
        printf '\n%s  ------- Tools -------%s\n' "$C_DIM" "$C_RST"
        printf '  %s[D]%s  ISO download + SHA256 verify\n' "$C_B" "$C_RST"
        printf '  %s[V]%s  Verify existing ISO checksum\n' "$C_B" "$C_RST"
        printf '  %s[M]%s  Multi-ISO USB  (Ventoy-style GRUB menu)\n' "$C_B" "$C_RST"
        printf '  %s[H]%s  Drive health + speed + boot test\n' "$C_B" "$C_RST"
        printf '  %s[G]%s  GUI wizard (graphical, yad/zenity)\n' "$C_B" "$C_RST"
        printf '  %s[Q]%s  Quit\n' "$C_B" "$C_RST"
        printf '\n%s------------------------------------------------------------------------%s\n' "$C_DIM" "$C_RST"
        printf '  Choice: '
        read -r c || exit 0
        case $c in
            1) pick_iso ;;
            2) pick_device ;;
            3) cycle_scheme ;;
            4) cycle_fs ;;
            5) cycle_mode ;;
            6) DO_VERIFY=$(( 1 - DO_VERIFY )) ;;
            7) persistence_cycle ;;
            8|s|S) do_start; exit 0 ;;
            d|D) dl_menu ;;
            v|V) verify_current_iso ;;
            m|M) ventoy_menu ;;
            h|H) health_menu ;;
            g|G) gui_wizard; printf '\n  Press ENTER...'; read -r _ ;;
            q|Q) echo "Bye!"; exit 0 ;;
            *) ;;
        esac
    done
}

usage() {
    cat <<EOF
rufus-linux.sh v$VERSION -- Bootable USB creator for Linux (Rufus-style)

Usage:
  sudo $0                          Interactive menu (recommended)
  sudo $0 --gui                    GUI wizard (yad/zenity)
  sudo $0 -i <iso> -d <device> [options]

Write options:
  -i, --iso <file>       ISO image
  -d, --device <dev>     Target disk (e.g. /dev/sdb)
  -m, --mode <m>         auto | dd | part        (default: auto)
  -p, --part <scheme>    mbr | gpt               (default: mbr)
  -f, --fs <fs>          auto | fat32 | ntfs | ext4   (default: auto -> ISO se decide)
  -L, --label <name>     Volume label
      --persist <MB>     Persistence partition size (Partition mode, Debian/Ubuntu live)
      --verify           Write ke baad data verify karo
      --no-eject         Write ke baad eject mat karo
  -y, --yes              Confirmation prompt skip karo  (DHYAN!)

Subcommands:
      --gui                    GUI wizard (graphical)
      --download [id]          ISO download + SHA256 verify (menu, ya seedha id)
      --list-downloads         Distro catalog dikhao (root nahi chahiye)
      --download-dir <dir>     Download folder (default: ~/Downloads)
      --verify-iso <file>      Pehle se download kiya ISO verify karo

      --ventoy                 Multi-ISO USB menu (Ventoy-style)
      --ventoy-prepare         Nayi multi-ISO USB banao  (-d, -p, --storage)
      --ventoy-add <iso>       ISO USB par add karo
      --ventoy-remove          ISO remove karo (menu)
      --ventoy-rescan          GRUB menu rebuild karo
      --ventoy-list            USB par maujood ISO list
      --storage <fs>           Multi-ISO storage fs: ext4 | ntfs  (default ext4)

      --health                 Drive health + speed + boot test menu
      --help                   Yeh help

Modes:
  auto  = ISO hybrid hai to dd, warna partition+copy
  dd    = ISO ko seedhe device par likhna (Linux ISOs ke liye best)
  part  = FAT32 partition banakar files copy (+ persistence / Windows support)

Examples:
  sudo $0                                            # menu
  sudo $0 -i ubuntu.iso -d /dev/sdb -y --verify
  sudo $0 -i ubuntu.iso -d /dev/sdb -m part --persist 4096 -y
  sudo $0 --download ubuntu26                        # Ubuntu 26.04 LTS download
  sudo $0 --ventoy-prepare -d /dev/sdb -p mbr -y
  sudo $0 --ventoy-add ~/Downloads/archlinux.iso
  sudo $0 --health -d /dev/sdb
EOF
}

print_catalog() {
    printf '%s\n' "ISO download catalog (id -> distro):"
    printf '%s\n' "--------------------------------------------------------------"
    printf '%s\n' "$ISO_CATALOG" | awk -F'|' '{ printf "  %-14s %s\n", $1, $2 }'
    printf '%s\n' "--------------------------------------------------------------"
    printf '  Use:  sudo %s --download <id>\n' "$0"
}

parse_args() {
    while (( $# )); do
        case $1 in
            -i|--iso)    ISO=${2:-}; shift 2 ;;
            -d|--device) DEV=${2:-}; shift 2 ;;
            -m|--mode)   MODE=${2:-}; MODE_SET=1; shift 2 ;;
            -p|--part)   SCHEME=${2:-}; SCHEME_SET=1; shift 2 ;;
            -f|--fs)     FS=${2:-}; FS_SET=1; shift 2 ;;
            -L|--label)  VOLLBL=${2:-}; VOLLBL_SET=1; shift 2 ;;
            --storage)     VENTOY_STORAGE_FS=${2:-}; shift 2 ;;
            --persist)     PERSIST_MB=${2:-}; shift 2 ;;
            --download-dir) DL_DEFAULT_DIR=${2:-}; shift 2 ;;
            --download)
                 ACTION=download
                 if [[ ${2:-} != -* && -n ${2:-} ]]; then DL_ID=$2; shift; fi
                 shift ;;
            --list-downloads) ACTION=list-catalog; shift ;;
            --verify-iso)   ACTION=verifyiso; VERIFY_FILE=${2:-}; shift 2 ;;
            --gui)          ACTION=gui; shift ;;
            --ventoy)         ACTION=ventoy; shift ;;
            --ventoy-prepare) ACTION=ventoy-prepare; shift ;;
            --ventoy-add)     ACTION=ventoy-add; ADD_ISO=${2:-}; shift 2 ;;
            --ventoy-remove)  ACTION=ventoy-remove; shift ;;
            --ventoy-rescan)  ACTION=ventoy-rescan; shift ;;
            --ventoy-list)    ACTION=ventoy-list; shift ;;
            --health)         ACTION=health; shift ;;
            --verify)    DO_VERIFY=1; shift ;;
            --no-eject)  FINALIZE_EJECT=0; shift ;;
            -y|--yes)    ASSUME_YES=1; shift ;;
            -h|--help)   usage; exit 0 ;;
            *) err "Unknown option: $1"; usage; exit 1 ;;
        esac
    done
    [[ $MODE  =~ ^(auto|dd|part)$    ]] || die "--mode: auto|dd|part"
    [[ $SCHEME =~ ^(mbr|gpt)$        ]] || die "--part: mbr|gpt"
    [[ $FS    =~ ^(auto|fat32|ntfs|ext4)$ ]] || die "--fs: auto|fat32|ntfs|ext4"
    [[ $VENTOY_STORAGE_FS =~ ^(ext4|ntfs)$ ]] || die "--storage: ext4|ntfs"
    [[ -n $PERSIST_MB ]] && { [[ $PERSIST_MB =~ ^[0-9]+$ ]] || die "--persist: MB number chahiye"; }
    [[ -n $DEV && $DEV != /* ]] && DEV="/dev/$DEV"
}

main() {
    parse_args "$@"        # --help yahin exit kar deta hai (root ki zaroorat nahi)

    # root ki zaroorat nahi wale actions
    if [[ $ACTION == list-catalog ]]; then
        print_catalog
        exit 0
    fi

    # GUI wizard ko bina root ke chalaya ja sakta hai -- browsing (ISO/device/mode
    # pick) sab read-only hai.  Actual write pe wo khud pkexec se escalate karta
    # hai, ya fir "sudo ... --gui" dikhata hai.
    if [[ $ACTION != gui || ${RUFUS_ESCALATED:-0} == 1 ]]; then
        require_root "$@"
    fi
    check_base_deps

    case $ACTION in
        menu)
            interactive_menu ;;
        gui)
            gui_wizard ;;
        download)
            if [[ -n $DL_ID ]]; then dl_run_id "$DL_ID"; else dl_menu; fi ;;
        verifyiso)
            [[ -n $VERIFY_FILE ]] || die "--verify-iso <file> chahiye"
            ensure_tmpdir
            dl_verify_existing "$VERIFY_FILE" ;;
        ventoy)
            ventoy_menu ;;
        ventoy-prepare)
            [[ -n $DEV ]] || die "--ventoy-prepare ke liye -d <device> chahiye"
            assert_safe_device
            confirm_write "multi-ISO"
            ensure_tmpdir
            ventoy_prepare "$DEV" "$SCHEME" "$VENTOY_STORAGE_FS" ;;
        ventoy-add)
            [[ -n $ADD_ISO ]] || die "--ventoy-add <iso> chahiye"
            ventoy_add_iso "${DEV:-}" "$ADD_ISO" ;;
        ventoy-remove)  ventoy_remove_iso "${DEV:-}" ;;
        ventoy-rescan)  ventoy_rescan "${DEV:-}" ;;
        ventoy-list)    ventoy_list "${DEV:-}" ;;
        health)
            health_menu ;;
        *)
            die "Unknown action: $ACTION" ;;
    esac
}


# #############################################################################
#  MODULES below are appended by build.sh -- edit src/*.sh, then run ./build.sh
# #############################################################################


# ========================== 10_downloader.sh ======================================
# ------------------------------------------------------------------------------
#  MODULE: ISO downloader + checksum (SHA256/SHA512/MD5) verify
#
#  Design: har distro ke liye ek ROOT directory + discovery regex rakha hai,
#  seedha version hardcode NAHI. Isse URL rot (naya release aana) khud fix ho
#  jata hai -- script listing scan karke latest file utha leti hai.
#
#  Catalog format (pipe separated):
#    ID|LABEL|ROOT_URL|DIR_RE|SUBPATH|ISO_REGEX|CSUM_FILES
#      DIR_RE   = agar non-empty, to ROOT me se is regex match wale subdirs me
#                 se sabse latest (version sort) chune
#      SUBPATH  = subdir ke baad ka path
#      CSUM_FILES = space separated candidates (glob allowed), tried in order
# ------------------------------------------------------------------------------

ISO_CATALOG=$(cat <<'CATALOG_EOF'
ubuntu26|Ubuntu 26.04 LTS Desktop (latest LTS)|https://releases.ubuntu.com/|^26\.04||^ubuntu-[0-9.]+-desktop-amd64\.iso$|SHA256SUMS
ubuntu24|Ubuntu 24.04 LTS Desktop|https://releases.ubuntu.com/|^24\.04||^ubuntu-[0-9.]+-desktop-amd64\.iso$|SHA256SUMS
ubuntu22|Ubuntu 22.04 LTS Desktop|https://releases.ubuntu.com/|^22\.04||^ubuntu-[0-9.]+-desktop-amd64\.iso$|SHA256SUMS
debian|Debian (netinst - chhoti, online install)|https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/|||^debian-[0-9.]+-amd64-netinst\.iso$|SHA256SUMS SHA512SUMS
debiandvd|Debian (full DVD-1 - offline install)|https://cdimage.debian.org/debian-cd/current/amd64/iso-dvd/|||^debian-[0-9.]+-amd64-DVD-1\.iso$|SHA256SUMS SHA512SUMS
fedora|Fedora Workstation Live (latest)|https://mirrors.kernel.org/fedora/releases/|^[0-9]+$|Workstation/x86_64/iso/|^Fedora-Workstation-Live-.*x86_64\.iso$|*CHECKSUM*
mint|Linux Mint Cinnamon 64-bit (latest)|https://mirrors.kernel.org/linuxmint/stable/|^[0-9]+\.[0-9]+$||^linuxmint-[0-9.]+-cinnamon-64bit\.iso$|sha256sum.txt SHA256SUMS
arch|Arch Linux (rolling, hamesha latest)|https://geo.mirror.pkgbuild.com/iso/latest/|||^archlinux-x86_64\.iso$|sha256sums.txt
kali|Kali Linux (latest)|https://cdimage.kali.org/|^kali-[0-9.]+$||^kali-linux-[0-9.]+-installer-amd64\.iso$|SHA256SUMS
tumbleweed|openSUSE Tumbleweed DVD|https://download.opensuse.org/tumbleweed/iso/|||^openSUSE-Tumbleweed-DVD-x86_64-.*\.iso$|SHA256SUMS
CATALOG_EOF
)

DL_DEFAULT_DIR="${DL_DEFAULT_DIR:-$HOME/Downloads}"

# --------------------------- HTTP helpers -------------------------------------
dl_fetch() {                     # URL -> stdout (text).  3 retries (mirror flakiness ke liye)
    local url=$1 out="" rc=1 i
    for i in 1 2 3; do
        if have curl; then
            out=$(curl -fsSL --max-time 90 --retry 2 "$url" 2>/dev/null); rc=$?
        elif have wget; then
            out=$(wget -qO- --timeout=90 --tries=2 "$url" 2>/dev/null); rc=$?
        else
            return 1
        fi
        if (( rc == 0 )) && [[ -n $out ]]; then
            printf '%s\n' "$out"
            return 0
        fi
        sleep 1
    done
    return 1
}

dl_content_length() {            # URL -> bytes (0 agar pata na chale)
    local url=$1 len
    if have curl;   then len=$(curl -fsSLI --max-time 30 "$url" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} END{print v}')
    elif have wget; then len=$(wget --spider --server-response -S "$url" 2>&1 | awk '/[Cc]ontent-[Ll]ength:/{v=$2} END{print v}')
    else len=0
    fi
    [[ $len =~ ^[0-9]+$ ]] && echo "$len" || echo 0
}

dl_hrefs() {                     # autoindex page ke hrefs -> lines
    local url=$1
    dl_fetch "$url" 2>/dev/null \
      | grep -oE 'href="[^"]+"' \
      | sed -e 's/^href="//' -e 's/"$//' \
      | sed -e 's|^\./||' \
      | grep -vE '^(\.\.|/|[a-zA-Z][a-zA-Z0-9+.-]*:|#|\?|mailto:|[[:space:]]*$)' \
      | sed 's/%20/ /g' \
      | sort -u || true
}

# --------------------------- discovery ----------------------------------------
# $1=root $2=dir_re $3=subpath $4=iso_re  ->  full ISO URL (rc!=1 agar nahi mila)
dl_resolve_iso_url() {
    local root=$1 dre=$2 sub=$3 isore=$4
    local -a cands=()

    if [[ -n $dre ]]; then
        local names
        names=$(dl_hrefs "$root" 2>/dev/null \
                | while IFS= read -r h; do
                      [[ $h == */ ]] || continue
                      local n=${h%/}
                      if [[ $n =~ $dre ]]; then echo "$n"; fi
                  done \
                | sort -rV)
        [[ -z $names ]] && return 1
        while IFS= read -r n; do
            [[ -z $n ]] && continue
            cands+=("${root}${n}/${sub}")
        done <<<"$names"
    else
        cands=("${root}${sub}")
    fi

    local c hit
    for c in "${cands[@]}"; do
        # version-sort: sabse latest (e.g. 24.04.5.1 > 24.04.4 > 24.04.3)
        hit=$(dl_hrefs "$c" 2>/dev/null | grep -E "$isore" | sort -Vr | head -1)
        [[ -z $hit ]] && continue
        # multiple match? sabse chhota (DVD1 jaise numbering me best) — already head -1
        printf '%s%s\n' "$c" "$hit"
        return 0
    done
    return 1
}

dl_url_exists() {                # $1=url -> rc 0 agar available
    local url=$1
    if have curl; then curl -fsIL --max-time 25 -o /dev/null "$url" 2>/dev/null
    else [[ -n $(dl_fetch "$url" 2>/dev/null | head -1) ]]
    fi
}

# $1=iso_url  $2=space separated specs -> checksum URL
# spec tokens:
#   <name>     = exact filename in the same directory
#   *glob*     = glob match against directory listing
# Agar spec se na mile to per-file convention try hota hai:
#   <iso>.sha256 / <iso>.sha512 / <iso>.md5
dl_pick_checksum_url() {
    local isourl=$1 spec=$2
    local dir=${isourl%/*}; dir=${dir%/}    # '.../dir' (bina slash)
    local hrefs
    hrefs=$(dl_hrefs "$dir/" 2>/dev/null)   # fetch ke liye trailing slash
    local s pat hit
    for s in $spec; do
        [[ $s == PERFILE ]] && continue
        if [[ $s == *[\*\?]* ]]; then
            pat=$(printf '%s' "$s" | sed -e 's/\./\\./g' -e 's/\*/.*/g' -e 's/\?/.*/g')
            hit=$(printf '%s\n' "$hrefs" | grep -E "^${pat}$" | head -1)
        else
            hit=$(printf '%s\n' "$hrefs" | grep -Fx -- "$s" | head -1)
        fi
        [[ -n $hit ]] && { printf '%s/%s\n' "$dir" "$hit"; return 0; }
    done

    # per-file convention (openSUSE, openSUSE-like mirrors, aur etc.)
    local c
    for c in .sha256 .sha512 .md5; do
        if dl_url_exists "${isourl}${c}"; then
            printf '%s%s\n' "$isourl" "$c"
            return 0
        fi
    done
    return 1
}

# --------------------------- download -----------------------------------------
dl_skip_if_same() {              # $1=url $2=out  -> 0 agar already complete
    local url=$1 out=$2 remote local_sz
    [[ -f $out ]] || return 1
    remote=$(dl_content_length "$url")
    [[ $remote == 0 ]] && return 1
    local_sz=$(stat -c '%s' "$out")
    [[ $remote == "$local_sz" ]]
}

dl_download() {                  # $1=url $2=out
    local url=$1 out=$2 rc=0
    local sz; sz=$(dl_content_length "$url")

    if dl_skip_if_same "$url" "$out"; then
        info "Already complete: $(basename "$out")"
        return 0
    fi

    info "Downloading: $(basename "$out")   $(human "$sz")"

    # GUI available ho to pulsate dialog kholo (terminal na hone par bhi pata chale)
    local opened=0
    if [[ -n ${GUI_TOOL:-} && ${GUI_PROGRESS:-0} -eq 0 ]]; then
        gui_progress_open "Download" "$(basename "$out")" 1 && opened=1
    fi
    local use_gui=${GUI_PROGRESS:-0}

    if have curl; then
        if (( use_gui )); then
            curl -fL --retry 3 --retry-delay 2 -C - -sS -o "$out" "$url"; rc=$?
        else
            curl -fL --retry 3 --retry-delay 2 -C - --progress-bar -o "$out" "$url"; rc=$?
            echo
        fi
    elif have wget; then
        wget -c -O "$out" "$url"; rc=$?
    else
        (( opened )) && gui_progress_close
        die "curl ya wget chahiye (download ke liye)."
    fi
    (( opened )) && gui_progress_close

    (( rc != 0 )) && { err "Download fail (curl/wget rc=$rc). URL check karo / proxy dekho."; return $rc; }

    local got; got=$(stat -c '%s' "$out")
    if (( sz > 0 && got != sz )); then
        err "Size mismatch: expected $(human "$sz"), got $(human "$got")"
        return 1
    fi
    return 0
}

# --------------------------- checksum verify ----------------------------------
# $1=csumfile  $2=target filename -> hash (ya empty)
# Agar target na mile aur file me exactly 1 hash line ho to wohi chalta hai
# (openSUSE ke per-file .sha256 me filename snapshot ka hota hai, -Current nahi).
dl_extract_hash() {
    awk -v target="$2" '
    {
        line = $0
        sub(/\r$/, "", line)
        if (line ~ /^[0-9a-fA-F]+[ \t]+/) {
            n = split(line, a, /[ \t]+/)
            h = a[1]
            if (length(h) >= 32 && length(h) <= 128 && h ~ /^[0-9a-fA-F]+$/) {
                name = a[2]
                sub(/^\*/, "", name)
                sub(/^\.\//, "", name)
                cnt++; H[cnt] = h; N[cnt] = name
            }
        } else if (index(line, "(") > 0 && index(line, ")") > 0 && index(line, "=") > 0) {
            s = line
            sub(/^[^(]*\(/, "", s)
            nm = s
            sub(/\).*/, "", nm)
            hh = line
            sub(/.*=[ \t]*/, "", hh)
            sub(/[ \t]+$/, "", hh)
            if (nm != "" && length(hh) >= 32 && hh ~ /^[0-9a-fA-F]+$/) {
                cnt++; H[cnt] = hh; N[cnt] = nm
            }
        }
    }
    END {
        for (i = 1; i <= cnt; i++) if (N[i] == target) { print tolower(H[i]); exit }
        if (cnt == 1) print tolower(H[1])
    }' "$1"
}

dl_algo_for() {                  # hash length -> command
    case ${#1} in
        32)  echo md5sum ;;
        40)  echo sha1sum ;;
        64)  echo sha256sum ;;
        128) echo sha512sum ;;
        *)   echo "" ;;
    esac
}

# $1=file  $2=local checksum file  -> 0 ok, 1 mismatch, 2 no csum
dl_verify_file() {
    local f=$1 csum=$2
    local base; base=$(basename "$f")

    [[ -f $csum ]] || { warn "Checksum file nahi mili: $csum"; return 2; }

    local want; want=$(dl_extract_hash "$csum" "$base")
    if [[ -z $want ]]; then
        warn "Checksum file me '$base' entry nahi mili ($csum)"
        return 2
    fi

    local algo; algo=$(dl_algo_for "$want")
    if [[ -z $algo ]]; then
        warn "Unknown hash length (${#want}) -- verify skip."
        return 2
    fi

    info "Verifying ($algo) ... yeh 5-60 sec le sakta hai"
    local got
    got=$($algo "$f" | awk '{print tolower($1)}')

    if [[ $got == "$want" ]]; then
        info "CHECKSUM OK  ($(human "$(stat -c '%s' "$f")"))  $algo=$got"
        return 0
    fi
    err "CHECKSUM MISMATCH!"
    err "  expected: $want"
    err "  got     : $got"
    return 1
}

# $1=file  $2=csum_url  -> 0 ok, 1 mismatch, 2 no csum
dl_verify() {
    local f=$1 url=$2
    ensure_tmpdir
    local tmp="$TMPDIR_P/dl-csum.$$"

    if ! dl_fetch "$url" > "$tmp" 2>/dev/null || [[ ! -s $tmp ]]; then
        rm -f "$tmp"
        warn "Checksum file download nahi hua: $url"
        return 2
    fi

    local rc=0
    dl_verify_file "$f" "$tmp"
    rc=$?
    rm -f "$tmp"
    return $rc
}

# Local folder me checksum file dhoondta hai (pehle se download kiya ISO)
dl_find_local_csum() {           # $1=iso file -> path
    local f=$1
    local dir=${f%/*} base=${f##*/}
    [[ $dir == "$f" ]] && dir=.
    local s
    for s in SHA256SUMS SHA256SUM sha256sum.txt sha256sums.txt SHA512SUMS sha512sum.txt; do
        [[ -f $dir/$s ]] && { printf '%s\n' "$dir/$s"; return 0; }
    done
    [[ -f $f.sha256 ]] && { printf '%s\n' "$f.sha256"; return 0; }
    [[ -f $f.sha512 ]] && { printf '%s\n' "$f.sha512"; return 0; }
    local g
    for g in "$dir"/*CHECKSUM* "$dir"/*-SHA256SUMS; do
        [[ -f $g ]] && { printf '%s\n' "$g"; return 0; }
    done
    return 1
}

# --------------------------- CLI / menu ---------------------------------------
dl_catalog_count() { printf '%s\n' "$ISO_CATALOG" | grep -c . ; }

dl_entry() {                     # $1=id -> line (empty if not found)
    printf '%s\n' "$ISO_CATALOG" | awk -F'|' -v id="$1" '$1==id {print; exit}'
}

dl_menu() {
    local items=() i=1 line id label
    echo
    printf '%s\n' "${C_B}  ISO Download + SHA verify${C_RST}"
    printf '%s\n' "${C_DIM}  ------------------------------------------------------------------------${C_RST}"
    while IFS='|' read -r id label _rest; do
        [[ -z $id ]] && continue
        items+=("$id")
        printf '  %s[%2d]%s  %s\n' "$C_B" "$i" "$C_RST" "$label"
        i=$((i+1))
    done <<< "$ISO_CATALOG"
    printf '  %s[%2d]%s  Custom URL (khud paste karo)\n' "$C_B" "$i" "$C_RST"
    local custom_idx=$i
    printf '%s\n' "${C_DIM}  ------------------------------------------------------------------------${C_RST}"

    local ans
    printf '  Choice (ENTER=cancel): '
    read -r ans || return 1
    [[ -z $ans ]] && return 1
    [[ $ans =~ ^[0-9]+$ ]] || { warn "Ghalat choice."; return 1; }

    local idp="" url="" outdir="$DL_DEFAULT_DIR"
    if (( ans == custom_idx )); then
        printf '  ISO URL paste karo: '
        read -r url || return 1
        [[ -z $url ]] && return 1
    else
        (( ans < 1 || ans > ${#items[@]} )) && { warn "Ghalat choice."; return 1; }
        idp=${items[ans-1]}
    fi

    printf '  Download folder [%s]: ' "$DL_DEFAULT_DIR"
    read -r outdir; outdir=${outdir:-$DL_DEFAULT_DIR}
    mkdir -p "$outdir" || die "Folder nahi bana: $outdir"

    ensure_tmpdir

    if [[ -z $url ]]; then
        local line; line=$(dl_entry "$idp")
        [[ -z $line ]] && die "catalog entry nahi mili: $idp"
        local IFS='|' root dre sub isore cspec
        read -r _id _label root dre sub isore cspec <<<"$line"
        unset IFS
        info "Resolving latest ISO for: $_label"
        url=$(dl_resolve_iso_url "$root" "$dre" "$sub" "$isore") \
            || die "ISO resolve nahi hua (network ya URL change ho gaya).
        -> Custom URL option use karo, ya catalog src/10_downloader.sh me update karo."
        info "URL: $url"
        dl_do_download "$url" "$outdir" "$cspec"
    else
        dl_do_download "$url" "$outdir" "SHA256SUMS SHA256SUM sha256sum.txt SHA512SUMS"
    fi
}

dl_do_download() {               # $1=url $2=outdir $3=csum specs
    local url=$1 outdir=$2 cspec=${3:-}
    local name=${url%%\?*}; name=${name##*/}
    local out="$outdir/$name"

    [[ -f $out ]] && warn "File pehle se hai (resume/skip): $out"

    if ! dl_download "$url" "$out"; then
        return 1
    fi

    # checksum
    local curl_, rc=2
    if [[ -n $cspec ]]; then
        if curl_=$(dl_pick_checksum_url "$url" "$cspec"); then
            dl_verify "$out" "$curl_"
            rc=$?
        else
            warn "Checksum file nahi mili (directory listing me nahi tha)."
            rc=2
        fi
    fi
    unset curl_

    echo
    printf '  %-10s %s\n' "File" "$out"
    printf '  %-10s %s\n' "Size" "$(human "$(stat -c '%s' "$out")")"
    case $rc in
        0) printf '  %-10s %s\n' "Verify" "${C_GRN}PASS${C_RST}" ;;
        1) printf '  %-10s %s\n' "Verify" "${C_RED}FAIL -- file delete karke dobara download karo${C_RST}"; return 1 ;;
        *) printf '  %-10s %s\n' "Verify" "${C_YLW}SKIPPED (checksum nahi mila)${C_RST}" ;;
    esac
    echo
    info "Ab yeh ISO rufus-linux.sh me use kar sakte ho:"
    printf '    sudo %s -i "%s" -d /dev/sdX\n' "$0" "$out"
    ISO="$out"
    return 0
}

# sirf verify (pehle se download kiya hua)
dl_verify_existing() {           # $1=iso file (local)
    local f=$1
    [[ -f $f ]] || die "File nahi mili: $f"
    ensure_tmpdir
    local csum
    if csum=$(dl_find_local_csum "$f"); then
        info "Checksum file: $csum"
        dl_verify_file "$f" "$csum"
        return $?
    fi
    # local me nahi mila -> remote try karo (folder ka listing nahi hota, isliye URL guess)
    warn "Usi folder me checksum file nahi mili."
    warn "  Agar internet hai to '*.sha256' / SHA256SUMS khud download karke"
    warn "  rufus-linux.sh ke saath rakh do, phir dobara chalao."
    return 2
}

# seedha catalog id se download:  sudo ./rufus-linux.sh --download ubuntu26
dl_run_id() {                    # $1=id
    local id=$1
    local line; line=$(dl_entry "$id")
    if [[ -z $line ]]; then
        err "Unknown id: '$id'"
        print_catalog
        exit 1
    fi
    local IFS='|'
    local _id _label root dre sub isore cspec
    read -r _id _label root dre sub isore cspec <<<"$line"
    unset IFS

    ensure_tmpdir
    info "Distro : $_label"
    info "Resolving latest ISO ..."
    local url
    if ! url=$(dl_resolve_iso_url "$root" "$dre" "$sub" "$isore"); then
        die "ISO resolve nahi hua (network problem, ya mirror/layout badal gaya).
     -> 'sudo $0 --download' (menu) try karo, ya khud URL se download karke
        '--verify-iso' se check kar lo."
    fi
    info "URL    : $url"
    mkdir -p "$DL_DEFAULT_DIR" || die "Folder nahi bani: $DL_DEFAULT_DIR"
    dl_do_download "$url" "$DL_DEFAULT_DIR" "$cspec"
}

# ========================== 20_persistence.sh ======================================
# ------------------------------------------------------------------------------
#  MODULE: Persistence partition  (Live USB me changes reboot ke baad bhi rahein)
#
#  Kaise kaam karta hai:
#    * partition+copy mode me 2 partition banate hain:
#        p1 : FAT32   -> boot files (ISO ka content)
#        p2 : ext4    -> persistence data (label casper-rw / persistence)
#    * kernel cmdline me "persistent" add karte hain (boot configs me sed se)
#
#  Support:
#    * Ubuntu / Mint / Kali / Pop!_OS  (casper/  dir)  -> label "casper-rw"
#    * Debian Live                    (live/   dir)   -> label "persistence"
#                                                         + persistence.conf
#    * Fedora / RHEL / Arch           -> SUPPORTED NAHI (warn karta hai)
#
#  NOTE: persistence sirf "Partition & Copy" mode me kaam karta hai.
#        dd / ISO-Hybrid mode me ISO ka apna partition table hota hai, usme
#        doosra partition nahi bana sakte.
# ------------------------------------------------------------------------------

# ISO ki layout dekh kar persistence ka "kind" batata hai:  casper | live | none
persistence_kind() {
    local m=${1:-$ISOMNT}
    [[ -n $m && -d $m ]] || { echo none; return; }
    if   [[ -d $m/casper ]]; then echo casper
    elif [[ -d $m/live && ( -f $m/live/vmlinuz || -f $m/live/initrd.img || -f $m/live/filesystem.squashfs ) ]]; then echo live
    else echo none
    fi
}

# partition ka label jo kernel ko dhoondna hai
persistence_label_for() {        # $1=kind
    case $1 in
        casper) echo "casper-rw" ;;
        live)   echo "persistence" ;;
        *)      echo "" ;;
    esac
}

# kernel cmdline ka extra param
persistence_param_for() {
    case $1 in
        casper|live) echo "persistent" ;;
        *)           echo "" ;;
    esac
}

persistence_is_supported() { [[ $1 == casper || $1 == live ]]; }

# Boot configs ke saare kernel-lines me $1 param add karta hai.
# Handles:  append / linux / linuxefi / linux16 / linuxe / kernel  (syslinux + GRUB)
# Ubuntu ke " ... ---" ending ko respect karta hai (param `---` se pehle jaata hai)
add_boot_param() {               # $1=mountpoint  $2=param
    local mnt=$1 param=$2
    [[ -n $param && -d $mnt ]] || return 0

    local f files=()
    while IFS= read -r f; do files+=("$f"); done < <(
        find "$mnt" -type f \( -name '*.cfg' -o -name '*.conf' \) 2>/dev/null
    )
    (( ${#files[@]} )) || { warn "Koi boot config (.cfg) nahi mili -- param add nahi ho paya."; return 1; }

    local changed=0
    for f in "${files[@]}"; do
        grep -qE '^[[:space:]]*(append|linux|linuxefi|linux16|linuxe|kernel)[[:space:]]' "$f" 2>/dev/null || continue
        grep -qE "(^|[[:space:]])${param}([[:space:]]|\$)" "$f" 2>/dev/null && continue   # pehle se hai

        # syslinux/isolinux me `kernel` + `append` alag hote hain -> sirf `append`
        # badlo (warna param do baar chala jaata). GRUB me `linux ...` single
        # line hoti hai -> wahi badlo.
        local pat='^[ \t]*(append|linux|linuxefi|linux16|linuxe|kernel)[ \t]'
        if grep -qE '^[[:space:]]*append[[:space:]]' "$f" 2>/dev/null; then
            pat='^[ \t]*append[ \t]'
        fi

        # awk portable hai (sed ka `t` branch GNU-specific hai)
        local tmp="$f.rufustmp"
        awk -v p="$param" -v pat="$pat" '
            {
                if ($0 ~ pat) {
                    line = $0
                    if (line ~ /[ \t]---[ \t]*$/) {
                        sub(/[ \t]*---[ \t]*$/, " " p " ---", line)
                    } else {
                        line = line " " p
                    }
                    print line
                    done = 1
                } else {
                    print
                }
            }
            END { exit (done ? 0 : 1) }
        ' "$f" > "$tmp" && { mv -f "$tmp" "$f"; changed=$((changed+1)); } || rm -f "$tmp"
    done

    if (( changed )); then
        info "Boot config update: '$param' add hua ($changed file)"
        return 0
    fi
    warn "'$param' kisi boot config me add nahi ho paya (config pattern alag ho sakta hai)."
    return 1
}

# Partition plan: boot partition ka end MB decide karta hai
#   $1=isosize bytes   $2=device size bytes  ->  boot_end_mb (stdout)
persistence_boot_end_mb() {
    local isosz=$1 devsz=$2
    local mb=1048576
    local need=$(( (isosz * 115) / 100 ))          # 15% slack
    need=$(( need + 64 * mb ))                      # filesystem overhead
    local end=$(( need / mb ))
    local devmb=$(( devsz / mb ))
    (( end > devmb - 64 )) && end=$(( devmb - 64 ))
    (( end < 64 )) && end=64
    echo "$end"
}

# 2-partition layout banata hai.  stdout: boot partition path.  PERSIST_PART set.
make_partition_persist() {       # $1=dev  $2=label(fs naam ke liye)  $3=fs  $4=persist_mb  $5=isosz  $6=devsz
    local dev=$1 fslab=$2 fs=$3 pmb=$4 isosz=$5 devsz=$6
    local boot_end
    boot_end=$(persistence_boot_end_mb "$isosz" "$devsz")

    local boot_mb=$(( isosz / 1048576 ))
    local avail=$(( devsz / 1048576 - boot_end - 1 ))
    if (( pmb > avail )); then
        warn "Persistence size $pmb MB > available $avail MB -- $avail MB kar diya."
        pmb=$avail
    fi
    (( pmb < 256 )) && die "Persistence ke liye jagah nahi bachi (device chhoti hai)."

    unmount_target "$dev"
    wipefs -af "$dev" >/dev/null 2>&1 || true

    if ! have parted; then
        die "Persistence ke liye 'parted' chahiye."
    fi
    parted -s "$dev" mklabel msdos || die "mklabel fail"
    parted -s "$dev" mkpart primary fat32 1MiB "${boot_end}MiB" || die "mkpart boot fail"
    parted -s "$dev" set 1 boot on || true
    parted -s "$dev" mkpart primary ext4 "${boot_end}MiB" 100% || die "mkpart persist fail"

    blockdev --rereadpt "$dev" 2>/dev/null || true
    partprobe "$dev" 2>/dev/null || true
    udevadm settle 2>/dev/null || sleep 1

    local p1 p2
    if [[ ${dev##*/} =~ [0-9]$ ]]; then p1="${dev}p1"; p2="${dev}p2"; else p1="${dev}1"; p2="${dev}2"; fi

    local i
    for i in $(seq 1 40); do [[ -b $p1 && -b $p2 ]] && break; sleep 0.25; done
    [[ -b $p1 ]] || die "$p1 nahi bana."
    [[ -b $p2 ]] || die "$p2 nahi bana."

    mkfs.vfat -F 32 -n "$fslab" "$p1" >/dev/null || die "mkfs.vfat fail"

    local lbl; lbl=$(persistence_label_for "${PERSIST_KIND:-}")
    mkfs.ext4 -F -L "$lbl" "$p2" >/dev/null || die "mkfs.ext4 (persistence) fail"

    PERSIST_PART="$p2"
    PERSIST_SIZE_MB=$pmb

    info "Partitions: p1 FAT32 boot (${boot_end}MiB) + p2 ext4 persistence ($pmb MB, label=$lbl)"
    printf '%s\n' "$p1"
}

# persistence partition par final touches (jaise Debian ka persistence.conf)
persistence_finish() {           # $1=persist partition
    local part=$1
    [[ -n ${PERSIST_PART:-} && -b $part ]] || return 0
    local pm="$TMPDIR_P/persistmnt"
    mkdir -p "$pm"
    if mount "$part" "$pm" 2>/dev/null; then
        if [[ ${PERSIST_KIND:-} == live ]]; then
            printf '/ union\n' > "$pm/persistence.conf"
            info "persistence.conf likha ('/ union')"
        fi
        # ek marker taaki user baad me pehchan sake
        printf 'Created by rufus-linux.sh  (%s, %s MB)\n' "${PERSIST_KIND:-?}" "${PERSIST_SIZE_MB:-?}" \
            > "$pm/.rufus-persistence"
        sync
        umount "$pm" 2>/dev/null || true
    else
        warn "persistence partition mount nahi hua (final touch skip)."
    fi
}

persistence_reset() {
    PERSIST_MB=0
    PERSIST_KIND=""
    PERSIST_PART=""
    PERSIST_SIZE_MB=0
}

persistence_status_text() {
    if (( ${PERSIST_MB:-0} > 0 )); then
        printf '%s MB ext4 (label: %s)' "$PERSIST_MB" "$(persistence_label_for "${PERSIST_KIND:-}")"
    else
        printf 'OFF'
    fi
}

# Interactive prompt -- do_start se pehle call hota hai (jab mode=part)
persistence_ask() {
    (( ASSUME_YES )) && return 0
    local kind
    kind=$(persistence_kind "$ISOMNT")
    if ! persistence_is_supported "$kind"; then
        warn "ISO layout '${kind}' -- persistence supported nahi hai (Ubuntu/Mint/Debian Live chahiye)."
        persistence_reset
        return 0
    fi
    if (( ${PERSIST_MB:-0} > 0 )); then return 0; fi   # pehle se set (CLI)

    echo
    printf '  Persistence partition banana hai? (Live USB me files reboot ke baad rehengi)\n'
    printf '  ISO type: %s  ->  label will be "%s"\n' "$kind" "$(persistence_label_for "$kind")"
    printf '  Size in MB (ENTER = skip, suggest 4096): '
    local ans; read -r ans || ans=""
    if [[ -z $ans ]]; then
        persistence_reset
        return 0
    fi
    [[ $ans =~ ^[0-9]+$ ]] || { warn "Ghalat number -- persistence skip."; persistence_reset; return 0; }
    PERSIST_MB=$ans
    PERSIST_KIND=$kind
}

# ========================== 30_ventoy.sh ======================================
# ------------------------------------------------------------------------------
#  MODULE: Ventoy-style multi-ISO USB  (ek USB par bahut saari ISO + GRUB menu)
#
#  Layout:
#    MBR :  p1 FAT32  (512MiB, label RUFUSBOOT)  <- GRUB (BIOS + UEFI)
#           p2 ext4   (baaki,     label RUFUSISO) <- saari .iso files
#    GPT :  p1 1MiB bios_grub
#           p2 FAT32 (512MiB, RUFUSBOOT, ESP)
#           p3 ext4  (baaki, RUFUSISO)
#
#  GRUB boot kaise karta hai:
#    har ISO ko loopback se mount karke uska apna kernel/initrd chalata hai,
#    aur "iso-scan/filename=" (ya family-specific param) deta hai taaki
#    initramfs dobara ISO file dhoond sake.
#
#  IMPORTANT: grub.cfg **generate** hota hai (tool chalakar). Naya ISO daalne
#  par menu [Rescan] zaroor chalao -- isse sabse reliable rehta hai ki har
#  ISO ka sahi kernel path + params detect ho jaaye.
#
#  Honesty note: Debian/Ubuntu family ke liye ye bahut reliable hai. Fedora,
#  Arch, openSUSE ke params best-effort hain (inke upstream boot params badalte
#  rehte hain). Agar koi ISO boot na ho to grub.cfg khud edit kar lo --
#  usme har entry ke upar comment me path likha hota hai.
# ------------------------------------------------------------------------------

VY_BOOT_LABEL="RUFUSBOOT"
VY_ISO_LABEL="RUFUSISO"
VY_BOOT_MB=512
VY_ISODIR="isos"
VY_MARKER=".rufus-isopart"

grub_install_bin() { command -v grub-install 2>/dev/null || command -v grub2-install 2>/dev/null; }

ventoy_check_deps() {
    if ! grub_install_bin >/dev/null; then
        err "grub-install nahi mila -- multi-ISO ke liye GRUB chahiye."
        err "  Debian/Ubuntu: sudo apt install grub-pc-bin grub-efi-amd64-bin grub-common"
        err "  Fedora       : sudo dnf install grub2-pc grub2-efi-x64 grub2-common"
        err "  Arch         : sudo pacman -S grub"
        return 1
    fi
    return 0
}

# --------------------------- partitioning -------------------------------------
ventoy_part_name() {             # dev -> partition path helper (p1/p2/p3)
    local dev=$1 n=$2
    if [[ ${dev##*/} =~ [0-9]$ ]]; then printf '%sp%s' "$dev" "$n"; else printf '%s%s' "$dev" "$n"; fi
}

ventoy_prepare() {               # $1=dev  $2=scheme(mbr|gpt)  $3=storage fs(ext4|ntfs)
    local dev=$1 scheme=$2 sfs=$3
    ventoy_check_deps || return 1

    local devsz; devsz=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
    local devmb=$(( devsz / 1048576 ))
    (( devmb < 1024 )) && die "Device bahut chhoti hai ($devmb MB) -- multi-ISO ke liye kam se kam 1GB chahiye."

    unmount_target "$dev"
    wipefs -af "$dev" >/dev/null 2>&1 || true

    local boot_end
    if [[ $scheme == gpt ]]; then
        boot_end=$(( VY_BOOT_MB + 3 ))
        parted -s "$dev" mklabel gpt || die "mklabel gpt fail"
        parted -s "$dev" mkpart bios_grub 1MiB 3MiB || die "mkpart bios_grub fail"
        parted -s "$dev" set 1 bios_grub on || true
        parted -s "$dev" mkpart esp fat32 3MiB "${boot_end}MiB" || die "mkpart esp fail"
        parted -s "$dev" set 2 esp on || true
        parted -s "$dev" mkpart isos "$sfs" "${boot_end}MiB" 100% || die "mkpart isos fail"
        VENTOY_BOOT_PART=$(ventoy_part_name "$dev" 2)
        VENTOY_ISO_PART=$(ventoy_part_name "$dev" 3)
    else
        boot_end=$(( VY_BOOT_MB + 1 ))
        parted -s "$dev" mklabel msdos || die "mklabel msdos fail"
        parted -s "$dev" mkpart primary fat32 1MiB "${boot_end}MiB" || die "mkpart boot fail"
        parted -s "$dev" set 1 boot on || true
        parted -s "$dev" mkpart primary "$sfs" "${boot_end}MiB" 100% || die "mkpart isos fail"
        VENTOY_BOOT_PART=$(ventoy_part_name "$dev" 1)
        VENTOY_ISO_PART=$(ventoy_part_name "$dev" 2)
    fi

    blockdev --rereadpt "$dev" 2>/dev/null || true
    partprobe "$dev" 2>/dev/null || true
    udevadm settle 2>/dev/null || sleep 1

    local i
    for i in $(seq 1 40); do [[ -b $VENTOY_BOOT_PART && -b $VENTOY_ISO_PART ]] && break; sleep 0.25; done
    [[ -b $VENTOY_BOOT_PART ]] || die "$VENTOY_BOOT_PART nahi bana."
    [[ -b $VENTOY_ISO_PART  ]] || die "$VENTOY_ISO_PART nahi bana."

    mkfs.vfat -F 32 -n "$VY_BOOT_LABEL" "$VENTOY_BOOT_PART" >/dev/null || die "mkfs.vfat fail"
    case $sfs in
        ntfs) mkfs.ntfs -f -L "$VY_ISO_LABEL" "$VENTOY_ISO_PART" >/dev/null || die "mkfs.ntfs fail" ;;
        *)    mkfs.ext4 -F -L "$VY_ISO_LABEL" "$VENTOY_ISO_PART"  >/dev/null || die "mkfs.ext4 fail" ;;
    esac
    info "Partition ready: boot=$VENTOY_BOOT_PART  iso=$VENTOY_ISO_PART ($sfs)"

    VENTOY_STORAGE_FS=$sfs
    ventoy_mount "$dev" || return 1
    ventoy_install_grub "$dev" || { ventoy_umount; return 1; }
    ventoy_regenerate
    ventoy_umount
    info "Multi-ISO USB ready. Ab 'Add ISO' se images daalo."
}

ventoy_mount() {                 # $1=dev (ya "" = auto-detect)
    local dev=${1:-}
    ensure_tmpdir
    if [[ -z $VENTOY_BOOT_PART || -z $VENTOY_ISO_PART || ! -b $VENTOY_BOOT_PART ]]; then
        ventoy_autodetect || { err "RUFUSBOOT / RUFUSISO labelled partitions nahi mile."; return 1; }
    fi
    mkdir -p "$TMPDIR_P/vboot" "$TMPDIR_P/viso"
    mountpoint -q "$TMPDIR_P/vboot" || mount "$VENTOY_BOOT_PART" "$TMPDIR_P/vboot" 2>/dev/null || {
        err "$VENTOY_BOOT_PART mount fail"; return 1; }
    mountpoint -q "$TMPDIR_P/viso"  || mount "$VENTOY_ISO_PART"  "$TMPDIR_P/viso"  2>/dev/null || {
        err "$VENTOY_ISO_PART mount fail"; return 1; }
    return 0
}

ventoy_umount() {
    mountpoint -q "$TMPDIR_P/vboot" 2>/dev/null && umount "$TMPDIR_P/vboot" 2>/dev/null
    mountpoint -q "$TMPDIR_P/viso"  2>/dev/null && umount "$TMPDIR_P/viso"  2>/dev/null
    return 0
}

ventoy_autodetect() {
    local iso boot
    iso=$(lsblk -ln -p -o NAME,LABEL 2>/dev/null | awk -v l="$VY_ISO_LABEL" '$2==l {print $1; exit}')
    boot=$(lsblk -ln -p -o NAME,LABEL 2>/dev/null | awk -v l="$VY_BOOT_LABEL" '$2==l {print $1; exit}')
    [[ -b $iso ]] || return 1
    VENTOY_ISO_PART=$iso
    VENTOY_BOOT_PART=${boot:-}
    # GPT me boot part alag label; agar na mile to partition 1/2 guess karo
    if [[ ! -b $VENTOY_BOOT_PART ]]; then
        local parent; parent=$(lsblk -ndo PKNAME "$iso" 2>/dev/null | head -1)
        [[ -n $parent ]] && VENTOY_BOOT_PART="/dev/$parent$( [[ $parent =~ [0-9]$ ]] && echo p || echo )1"
        [[ $iso == *p[0-9]* ]] && VENTOY_BOOT_PART="${iso%[0-9]*}p1" || true
        [[ -b $VENTOY_BOOT_PART ]] || VENTOY_BOOT_PART=""
    fi
    [[ -b $VENTOY_BOOT_PART ]]
}

# --------------------------- GRUB install -------------------------------------
ventoy_install_grub() {          # $1=dev
    local dev=$1 gi
    gi=$(grub_install_bin) || return 1
    local bootdir="$TMPDIR_P/vboot"

    info "GRUB (BIOS / i386-pc) install kar raha hoon..."
    if ! "$gi" --target=i386-pc --boot-directory="$bootdir/boot" --recheck "$dev" >"$TMPDIR_P/grub-bios.log" 2>&1; then
        warn "BIOS GRUB install fail (UEFI phir bhi chalega). Log: $TMPDIR_P/grub-bios.log"
        tail -3 "$TMPDIR_P/grub-bios.log" 2>/dev/null | sed 's/^/      /'
    else
        info "BIOS GRUB OK"
    fi

    info "GRUB (UEFI / x86_64-efi, removable) install kar raha hoon..."
    if ! "$gi" --target=x86_64-efi --efi-directory="$bootdir" --boot-directory="$bootdir/boot" \
              --removable --no-nvram --recheck >"$TMPDIR_P/grub-uefi.log" 2>&1; then
        warn "UEFI GRUB install fail. Log: $TMPDIR_P/grub-uefi.log"
        tail -3 "$TMPDIR_P/grub-uefi.log" 2>/dev/null | sed 's/^/      /'
        return 1
    fi
    info "UEFI GRUB OK -> EFI/BOOT/BOOTX64.EFI"

    if [[ ! -f $bootdir/EFI/BOOT/BOOTX64.EFI && ! -f $bootdir/EFI/BOOT/bootx64.efi ]]; then
        warn "EFI/BOOT/BOOTX64.EFI nahi bani."
    fi
    return 0
}

# --------------------------- ISO family detection -----------------------------
# stdout:  family|linux_path|initrd_path|extra_params
# (paths ISO ke andar hote hain, '/' se shuru)
detect_iso_family() {            # $1=iso file
    local iso=$1
    local m="$TMPDIR_P/probe.$$"
    mkdir -p "$m"
    if ! mount -o loop,ro "$iso" "$m" 2>/dev/null; then
        rmdir "$m" 2>/dev/null
        echo "unknown|||"
        return 1
    fi

    local fam="" k="" i="" extra=""
    local base="/isos/${iso##*/}"

    if [[ -d $m/casper ]]; then
        fam=debian
        k=/casper/vmlinuz
        for c in /casper/initrd /casper/initrd.lz /casper/initrd.gz; do [[ -f $m$c ]] && { i=$c; break; }; done
        extra="boot=casper iso-scan/filename=$base findiso=$base noeject noprompt"
    elif [[ -d $m/live && ( -f $m/live/vmlinuz || -f $m/live/filesystem.squashfs || -f $m/live/filesystem.tar ) ]]; then
        fam=debian-live
        k=/live/vmlinuz
        for c in /live/initrd.img /live/initrd /live/initrd1; do [[ -f $m$c ]] && { i=$c; break; }; done
        extra="boot=live findiso=$base components"
    elif [[ -f $m/images/pxeboot/vmlinuz ]]; then
        fam=fedora
        k=/images/pxeboot/vmlinuz
        i=/images/pxeboot/initrd.img
        extra="root=live:iso-scan/filename=$base rd.live.image=1"
    elif [[ -d $m/arch/boot ]]; then
        fam=arch
        for c in /arch/boot/vmlinuz-linux /arch/boot/vmlinuz-linux-lts; do [[ -f $m$c ]] && { k=$c; break; }; done
        for c in /arch/boot/initramfs-linux.img /arch/boot/initramfs-linux-lts.img; do [[ -f $m$c ]] && { i=$c; break; }; done
        extra="img_dev=LABEL=$VY_ISO_LABEL img_loop=$base archisobasedir=arch"
    elif [[ -d $m/boot/x86_64/loader ]]; then
        fam=opensuse
        k=/boot/x86_64/loader/linux
        i=/boot/x86_64/loader/initrd
        extra="isofrom_device=LABEL=$VY_ISO_LABEL isofrom=$base"
    else
        # generic probe
        local kk
        kk=$(find "$m" -maxdepth 3 -type f \( -name 'vmlinuz*' -o -name 'linux' -o -name 'bzImage*' \) 2>/dev/null | head -1)
        if [[ -n $kk ]]; then
            fam=generic
            k=${kk#"$m"}
            local idir; idir=$(dirname "$k")
            i=$(find "$m$idir" -maxdepth 1 -type f \( -name 'initr*' -o -name 'initramfs*' -o -name 'initrd*' \) 2>/dev/null | head -1)
            i=${i#"$m"}
            extra="root=live:iso-scan/filename=$base findiso=$base"
        else
            fam=unknown
        fi
    fi

    umount "$m" 2>/dev/null || true
    rmdir "$m" 2>/dev/null || true
    printf '%s|%s|%s|%s\n' "$fam" "$k" "$i" "$extra"
}

# --------------------------- grub.cfg generation ------------------------------
ventoy_regenerate() {            # $TMPDIR_P/vboot aur viso mounted hone chahiye
    local bootm="$TMPDIR_P/vboot" isom="$TMPDIR_P/viso"
    local cfgdir="$bootm/boot/grub"
    mkdir -p "$cfgdir" "$isom/$VY_ISODIR"
    touch "$isom/$VY_ISODIR/$VY_MARKER"

    local cfg="$cfgdir/grub.cfg"
    local n=0

    {
        cat <<EOF
# ===========================================================================
#  rufus-linux.sh  --  multi-ISO GRUB menu   (AUTO-GENERATED -- DO NOT EDIT)
#
#  Naya ISO add/remove karne ke baad is file ko dobara generate karo:
#      sudo $0 ventoy-rescan
#  (Ya menu -> Multi-ISO -> "Rescan / rebuild menu")
#
#  ISO partition ka marker: /$VY_ISODIR/$VY_MARKER
#  ISOs rakhne ka folder :  /$VY_ISODIR/
# ===========================================================================
set timeout=10
set default=0

insmod part_gpt
insmod part_msdos
insmod fat
insmod ext2
insmod ntfs
insmod loopback
insmod linux
insmod gzio

# ISO partition ko marker file se dhoondho (label rename karne par bhi kaam karega)
search --no-floppy --file --set=isoroot /$VY_ISODIR/$VY_MARKER
if [ -z "\$isoroot" ]; then
    search --no-floppy --label --set=isoroot $VY_ISO_LABEL
fi
if [ -n "\$isoroot" ]; then
    set root=\$isoroot
fi

# ---------------- ISO entries (auto) ----------------
EOF

        local f base probe fam k i extra title class
        shopt -s nullglob
        for f in "$isom/$VY_ISODIR"/*.iso "$isom/$VY_ISODIR"/*.ISO; do
            base=$(basename "$f")
            probe=$(detect_iso_family "$f")
            IFS='|' read -r fam k i extra <<<"$probe"
            if [[ $fam == unknown || -z $k || -z $i ]]; then
                printf '# SKIP: "%s" -- kernel/initrd detect nahi hua (family=%s)\n' "$base" "$fam"
                printf '#   -> is ISO ke andar khud dekho (vmlinuz/initrd ka path) aur entry add karo.\n'
                continue
            fi
            title=${base%.iso}; title=${title%.ISO}
            printf '\n# --- %s (family: %s) ---\n' "$base" "$fam"
            printf 'menuentry "%s" --class gnu-linux {\n' "${title//\"/}"
            printf '    loopback loop /%s/%s\n' "$VY_ISODIR" "$base"
            printf '    linux  (loop)%s %s\n' "$k" "$extra"
            printf '    initrd (loop)%s\n' "$i"
            printf '}\n'
            n=$((n+1))
        done
        shopt -u nullglob

        cat <<EOF

# ---------------- utility ----------------
if [ -n "\$fw_path" ]; then
    menuentry "UEFI Firmware Settings" {
        fwsetup
    }
fi
menuentry "Reboot" {
    reboot
}
menuentry "Power Off" {
    halt
}
EOF
    } > "$cfg"

    local listed
    listed=$(grep -c '^menuentry ' "$cfg" 2>/dev/null || echo 0)
    info "grub.cfg regenerate: $listed boot entries ($n ISO)"
    if (( n == 0 )); then
        warn "Koi ISO nahi mili. '$VY_ISODIR' folder me .iso copy karo, phir Rescan chalao."
    fi
}

# --------------------------- user operations ----------------------------------
ventoy_free_bytes() { df -B1 --output=avail "$TMPDIR_P/viso" 2>/dev/null | tail -1 | tr -dc '0-9'; }

ventoy_add_iso() {               # $1=dev(optional) $2=iso file
    local dev=${1:-} iso=$2
    [[ -f $iso ]] || die "ISO nahi mili: $iso"
    ventoy_mount "$dev" || exit 1

    local sz; sz=$(stat -c '%s' "$iso")
    local free; free=$(ventoy_free_bytes)
    if [[ -z $free || $free == 0 || $sz -gt $free ]]; then
        ventoy_umount
        die "Jagah nahi: need $(human "$sz"), free $(human "${free:-0}")"
    fi

    local name=${iso##*/}
    mkdir -p "$TMPDIR_P/viso/$VY_ISODIR"
    info "Copying: $name  ($(human "$sz"))"
    if have rsync; then
        rsync -a --info=progress2 "$iso" "$TMPDIR_P/viso/$VY_ISODIR/"
    else
        cp -f "$iso" "$TMPDIR_P/viso/$VY_ISODIR/"
    fi
    sync

    ventoy_regenerate
    ventoy_umount
    info "Added: $name"
}

ventoy_remove_iso() {            # $1=dev(optional)  (menu driven)
    ventoy_mount "$1" || exit 1
    local -a files=()
    local f
    shopt -s nullglob
    for f in "$TMPDIR_P/viso/$VY_ISODIR"/*.iso "$TMPDIR_P/viso/$VY_ISODIR"/*.ISO; do files+=("$f"); done
    shopt -u nullglob
    if (( ${#files[@]} == 0 )); then
        warn "Koi ISO nahi hai."
        ventoy_umount; return 0
    fi
    local i=1
    for f in "${files[@]}"; do printf '  [%2d] %-60s %s\n' "$i" "$(basename "$f")" "$(human "$(stat -c '%s' "$f")")"; i=$((i+1)); done
    printf '  Delete karne ki number (ENTER=cancel): '
    local a; read -r a || { ventoy_umount; return 0; }
    [[ -z $a ]] && { ventoy_umount; return 0; }
    [[ $a =~ ^[0-9]+$ ]] && (( a>=1 && a<=${#files[@]} )) || { warn "Ghalat choice."; ventoy_umount; return 1; }
    rm -f "${files[$((a-1))]}"
    sync
    ventoy_regenerate
    ventoy_umount
    info "Deleted."
}

ventoy_list() {
    ventoy_mount "$1" || exit 1
    echo
    printf '  %-60s %10s   %s\n' "ISO" "SIZE" "FAMILY"
    printf '  %s\n' "----------------------------------------------------------------------"
    local f probe fam k i extra
    shopt -s nullglob
    for f in "$TMPDIR_P/viso/$VY_ISODIR"/*.iso "$TMPDIR_P/viso/$VY_ISODIR"/*.ISO; do
        probe=$(detect_iso_family "$f")
        IFS='|' read -r fam k i extra <<<"$probe"
        printf '  %-60s %10s   %s\n' "$(basename "$f")" "$(human "$(stat -c '%s' "$f")")" "$fam"
    done
    shopt -u nullglob
    ventoy_umount
}

ventoy_rescan() {
    ventoy_mount "$1" || exit 1
    ventoy_regenerate
    ventoy_umount
}

# --------------------------- interactive menu ---------------------------------
ventoy_menu() {
    local c
    while true; do
        [[ -t 1 ]] && printf '\033[H\033[2J'
        banner
        printf '%s\n' "  MULTI-ISO USB  (Ventoy-style, GRUB2 menu)"
        printf '%s\n' "${C_DIM}  ------------------------------------------------------------------------${C_RST}"
        printf '  %s[1]%s  Nayi multi-ISO USB banao      (format + GRUB install)\n' "$C_B" "$C_RST"
        printf '  %s[2]%s  ISO add karo                  (USB par copy + menu update)\n' "$C_B" "$C_RST"
        printf '  %s[3]%s  ISO remove karo\n' "$C_B" "$C_RST"
        printf '  %s[4]%s  Rescan / menu rebuild karo\n' "$C_B" "$C_RST"
        printf '  %s[5]%s  ISO list dekho\n' "$C_B" "$C_RST"
        printf '  %s[6]%s  Wapas main menu\n' "$C_B" "$C_RST"
        printf '%s\n' "${C_DIM}  ------------------------------------------------------------------------${C_RST}"
        printf '  Choice: '
        read -r c || return 0
        case $c in
            1)
                pick_device || continue
                local sch=mbr sfs=ext4 a b conf
                printf '  Partition scheme [1=MBR BIOS+UEFI, 2=GPT UEFI-only] (ENTER=1): '
                read -r a; sch=mbr; [[ $a == 2 ]] && sch=gpt
                printf '  Storage FS [1=ext4, 2=ntfs] (ENTER=1): '
                read -r b; sfs=ext4; [[ $b == 2 ]] && sfs=ntfs
                printf '\n  %s!! %s will be ERASED !!%s\n' "${C_YLW}${C_B}" "$DEV" "$C_RST"
                printf '  Type device name to confirm [%s]: ' "${DEV##*/}"
                read -r conf; [[ $conf == "${DEV##*/}" ]] || { warn "Cancel."; continue; }
                assert_safe_device
                ensure_tmpdir
                ventoy_prepare "$DEV" "$sch" "$sfs" || warn "Setup fail."
                printf '\n  Press ENTER...'; read -r _
                ;;
            2)
                local isop=""
                ventoy_autodetect || { warn "Multi-ISO USB detect nahi hua (pehle [1] chalao)."; printf '  ENTER...'; read -r _; continue; }
                printf '  ISO file ka path: '; read -r isop
                isop=${isop//\~/~}; isop=${isop%\"}; isop=${isop#\"}
                [[ -f $isop ]] || { warn "File nahi mili: $isop"; printf '  ENTER...'; read -r _; continue; }
                ventoy_add_iso "" "$isop"
                printf '\n  Press ENTER...'; read -r _
                ;;
            3) ventoy_remove_iso "";    printf '\n  Press ENTER...'; read -r _ ;;
            4) ventoy_rescan "";        printf '\n  Press ENTER...'; read -r _ ;;
            5) ventoy_list "";          printf '\n  Press ENTER...'; read -r _ ;;
            6|q|Q) return 0 ;;
        esac
    done
}

# ========================== 40_health.sh ======================================
# ------------------------------------------------------------------------------
#  MODULE: Drive health, speed test, aur QEMU boot test
#
#  1) Info        -- model, serial, transport, size, removable kya hai
#  2) SMART       -- smartctl se health (PASSED/FAILED), reallocated sectors,
#                    temperature, power-on hours
#  3) Read speed  -- 256MB padh kar MB/s (SAFE, kuch bigadta nahi)
#  4) Write speed -- 128MB likh kar MB/s (DESTRUCTIVE -- confirm maangta hai)
#  5) Bad blocks  -- badblocks read-only scan (slow but SAFE)
#  6) Boot test   -- QEMU me USB ko boot karke dekhna (BIOS / UEFI)
# ------------------------------------------------------------------------------

health_find_ovmf() {
    local c
    for c in \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/edk2/ovmf/OVMF_CODE.fd \
        /usr/share/edk2-ovmf/OVMF_CODE.fd \
        /usr/share/edk2/ovmf/OVMF_CODE_4M.fd \
        /usr/share/qemu/ovmf-x86_64-code.bin \
        /usr/share/edk2/x64/OVMF_CODE.4m.fd
    do
        [[ -f $c ]] && { echo "$c"; return 0; }
    done
    return 1
}

# --------------------------- info ---------------------------------------------
health_info() {                  # $1=dev
    local dev=$1
    echo
    printf '%s\n' "${C_B}  -------- Drive info --------${C_RST}"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,MODEL,SERIAL,TRAN,RM,HOTPLUG "$dev" 2>/dev/null | sed 's/^/  /'
    echo
    printf '  %-16s %s\n' "Block size"  "$(blockdev --getbsz "$dev" 2>/dev/null || echo '?') bytes"
    printf '  %-16s %s\n' "Total bytes" "$(blockdev --getsize64 "$dev" 2>/dev/null || echo '?')"
    printf '  %-16s %s\n' "Removable"   "$(cat "/sys/block/${dev##*/}/removable" 2>/dev/null || echo '?')"
    printf '  %-16s %s\n' "USB?"        "$(is_usb_like "${dev##*/}" && echo yes || echo no)"
    local ro=$(cat "/sys/block/${dev##*/}/ro" 2>/dev/null || echo '?')
    printf '  %-16s %s\n' "Read-only"   "$ro"
    local st
    st=$(smartctl -i -d sat "$dev" 2>/dev/null | grep -iE 'Serial Number|Device Model|Model Number|Firmware Version' | sed 's/^/    /')
    [[ -n $st ]] && { echo; printf '  %sIdentify:%s\n' "$C_DIM" "$C_RST"; echo "$st"; }
    echo
}

# --------------------------- SMART --------------------------------------------
health_smart() {                 # $1=dev
    local dev=$1
    if ! have smartctl; then
        warn "smartctl nahi mila. Install:  sudo apt install smartmontools  (ya dnf/pacman)"
        return 1
    fi
    echo
    printf '%s\n' "${C_B}  -------- SMART health --------${C_RST}"

    local out="" rc=0
    # USB drives ke liye aksar '-d sat' chahiye; fail ho to plain try karo
    out=$(smartctl -a -d sat "$dev" 2>&1); rc=$?
    if (( rc & 1 )) || grep -qiE 'Permission denied|Unknown USB|try without' <<<"$out"; then
        out=$(smartctl -a "$dev" 2>&1); rc=$?
    fi

    if (( rc & 1 )) && ! grep -qiE 'SMART support is available|SMART overall-health' <<<"$out"; then
        warn "SMART data nahi mila (kai USB pen drives SMART support nahi karti)."
        grep -iE 'error|denied|unknown|available' <<<"$out" | sed 's/^/    /' | head -4
        return 1
    fi

    local result
    result=$(grep -iE 'SMART overall-health self-assessment test result' <<<"$out" | head -1 | sed 's/.*: *//')
    if [[ -n $result ]]; then
        case ${result^^} in
            PASSED|OK) printf '  Health      : %s%s%s\n' "$C_GRN" "$result" "$C_RST" ;;
            *)         printf '  Health      : %s%s%s\n' "$C_RED" "$result" "$C_RST" ;;
        esac
    else
        printf '  Health      : %s(pata nahi chala)%s\n' "$C_YLW" "$C_RST"
    fi

    local kv
    for kv in "Reallocated_Sector_Ct" "Current_Pending_Sector" "Offline_Uncorrectable" \
              "Reallocated_Event_Ct" "Percentage Used" "Wear_Leveling_Count" \
              "Power_On_Hours" "Temperature_Celsius" "Temperature:" "Media_Wearout_Indicator"; do
        local line
        line=$(grep -E "^[[:space:]]*${kv}[[:space:]]" <<<"$out" | head -1)
        [[ -z $line ]] && line=$(grep -iE "^[[:space:]]*${kv//:/}[[:space:]]*:" <<<"$out" | head -1)
        [[ -z $line ]] && continue
        printf '  %s\n' "$(echo "$line" | sed -E 's/[[:space:]]+/ /g; s/^ //')"
    done

    # khaas warnings
    local realloc pending
    realloc=$(grep -E 'Reallocated_Sector_Ct' <<<"$out" | head -1 | awk '{print $(NF-1)}')
    pending=$(grep -E 'Current_Pending_Sector' <<<"$out" | head -1 | awk '{print $(NF-1)}')
    [[ $realloc =~ ^[0-9]+$ && $realloc -gt 0 ]] && \
        warn "Reallocated sectors = $realloc  ->  drive murjhha rahi hai. Data mat rakho isme."
    [[ $pending =~ ^[0-9]+$ && $pending -gt 0 ]] && \
        warn "Pending sectors = $pending  ->  bad blocks hain. Drive badal do."
    echo
}

# --------------------------- speed --------------------------------------------
_health_speed_dd() {             # $1=dev $2=read|write $3=count_mb
    local dev=$1 dir=$2 mb=$3
    local bytes=$(( mb * 1048576 ))
    local t0 t1 ns bps

    sync
    t0=$(date +%s%N)
    if [[ $dir == read ]]; then
        dd if="$dev" of=/dev/null bs=1M count="$mb" iflag=direct status=none 2>/dev/null \
        || dd if="$dev" of=/dev/null bs=1M count="$mb" status=none 2>/dev/null
    else
        dd if=/dev/zero of="$dev" bs=1M count="$mb" conv=fsync status=none 2>/dev/null
    fi
    local rc=$?
    t1=$(date +%s%N)
    (( rc != 0 )) && return $rc

    ns=$(( t1 - t0 ))
    (( ns <= 0 )) && ns=1
    bps=$(( bytes * 1000000000 / ns ))
    local kbs=$(( bps / 1024 ))
    printf '  %-6s %s MB in %.2fs  ->  %s\n' "$dir" "$mb" "$(awk -v n="$ns" 'BEGIN{printf "%.2f", n/1e9}')" \
        "$(human "$bps")/s  (${kbs} KB/s)"
}

health_read_speed() {            # $1=dev
    echo
    printf '%s\n' "${C_B}  -------- Read speed (safe) --------${C_RST}"
    _health_speed_dd "$1" read 256 || warn "Read test fail."
}

health_write_speed() {           # $1=dev  -- DESTRUCTIVE
    local dev=$1
    echo
    printf '%s\n' "${C_YLW}${C_B}  -------- Write speed (DESTRUCTIVE!) --------${C_RST}"
    warn "Is test me device ke shuru ke 128 MB PAR likha jayega."
    warn "Agar USB pe bootable data hai to WO KHRAB ho jayega."
    if (( ! ASSUME_YES )); then
        printf '%s' "  Phir bhi chalana hai? type karo 'yes': "
        local a; read -r a || return 1
        [[ $a == yes ]] || { warn "Skip."; return 1; }
    fi
    _health_speed_dd "$dev" write 128 || warn "Write test fail."
}

health_badblocks() {             # $1=dev  -- read-only, SLOW
    local dev=$1
    echo
    printf '%s\n' "${C_B}  -------- Bad blocks (read-only scan) --------${C_RST}"
    if ! have badblocks; then
        warn "badblocks nahi mila: sudo apt install e2fsprogs"
        return 1
    fi
    local szmb=$(( $(blockdev --getsize64 "$dev" 2>/dev/null || echo 0) / 1048576 ))
    warn "Ye scan SLOW ho sakta hai (device size: ${szmb} MB)."
    warn "Read-only hai -- kuch delete nahi hoga, lekin pura device padhna padega."
    if (( ! ASSUME_YES )); then
        printf '%s' "  Chalana hai? [y/N]: "
        local a; read -r a || return 1
        [[ $a == y || $a == Y ]] || { warn "Skip."; return 1; }
    fi
    echo
    if badblocks -sv "$dev"; then
        info "Scan complete -- koi bad block nahi mila (ya upar list hai)."
    else
        local rc=$?
        err "badblocks ne problems dikhayin (rc=$rc). Neeche 'x' wale blocks = kharab."
        return $rc
    fi
}

# --------------------------- QEMU boot test -----------------------------------
health_boot_test() {             # $1=dev
    local dev=$1
    echo
    printf '%s\n' "${C_B}  -------- QEMU boot test --------${C_RST}"

    if ! have qemu-system-x86_64; then
        warn "qemu-system-x86_64 nahi mila."
        err "  Debian/Ubuntu: sudo apt install qemu-system-x86 qemu-utils"
        err "  Fedora       : sudo dnf install qemu-system-x86"
        err "  Arch         : sudo pacman -S qemu-system-x86"
        return 1
    fi
    if [[ -z ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]]; then
        warn "Display nahi mila ($DISPLAY/$WAYLAND_DISPLAY) -- graphical boot test nahi chal sakta."
        warn "Graphical session me chalao, ya seedhe real machine par test karo."
        return 1
    fi

    local kopt=""
    if [[ -r /dev/kvm ]]; then kopt="-enable-kvm"; info "KVM: haan (fast)"; else info "KVM: nahi (software emulation -- dheere chalega)"; fi

    local mode
    printf '  Mode [1=BIOS/SeaBIOS, 2=UEFI/OVMF] (ENTER=1): '
    read -r mode; mode=${mode:-1}

    local biosopt=()
    if [[ $mode == 2 ]]; then
        local ovmf; ovmf=$(health_find_ovmf) || {
            warn "OVMF (UEFI firmware) nahi mila."
            err "  Debian/Ubuntu: sudo apt install ovmf     (Fedora: edk2-ovmf, Arch: edk2-ovmf)"
            return 1
        }
        info "UEFI firmware: $ovmf"
        biosopt=(-bios "$ovmf")
    fi

    info "QEMU window khul raha hai... USB boot karke dekho. Band karne ke liye window band karo."
    printf '  Command: qemu-system-x86_64 ...\n\n'

    # shellcheck disable=SC2086
    qemu-system-x86_64 \
        -m 2048 \
        $kopt \
        "${biosopt[@]}" \
        -drive "file=$dev,format=raw,if=ide,index=0,media=disk" \
        -boot order=c,menu=on \
        -rtc base=localtime \
        -name "rufus-linux boot test" \
        &
    local qpid=$!
    printf '  QEMU PID %s -- window band karne par test khatam.\n' "$qpid"
    wait "$qpid" 2>/dev/null
    info "Boot test khatam."
}

# --------------------------- menu ---------------------------------------------
health_menu() {
    local c
    while true; do
        [[ -t 1 ]] && printf '\033[H\033[2J'
        banner
        printf '%s\n' "  DRIVE HEALTH + BOOT TEST"
        printf '%s\n' "${C_DIM}  ------------------------------------------------------------------------${C_RST}"
        printf '  Target device : %s\n' "${DEV:-<none -- pehle device chuno>}"
        printf '%s\n' "${C_DIM}  ------------------------------------------------------------------------${C_RST}"
        printf '  %s[1]%s  Device select karo\n' "$C_B" "$C_RST"
        printf '  %s[2]%s  Drive info\n' "$C_B" "$C_RST"
        printf '  %s[3]%s  SMART health check\n' "$C_B" "$C_RST"
        printf '  %s[4]%s  Read speed test   (safe)\n' "$C_B" "$C_RST"
        printf '  %s[5]%s  Write speed test  (%sDESTRUCTIVE%s)\n' "$C_B" "$C_RST" "$C_RED" "$C_RST"
        printf '  %s[6]%s  Bad blocks scan   (read-only, slow)\n' "$C_B" "$C_RST"
        printf '  %s[7]%s  QEMU boot test    (USB ko emulator me boot karo)\n' "$C_B" "$C_RST"
        printf '  %s[8]%s  Sab kuch chalao   (info + SMART + read speed)\n' "$C_B" "$C_RST"
        printf '  %s[9]%s  Wapas main menu\n' "$C_B" "$C_RST"
        printf '%s\n' "${C_DIM}  ------------------------------------------------------------------------${C_RST}"
        printf '  Choice: '
        read -r c || return 0
        case $c in
            1) pick_device || true; printf '  ENTER...'; read -r _ ;;
            2) [[ -n ${DEV:-} ]] && health_info "$DEV"   || warn "pehle device chuno"; printf '  ENTER...'; read -r _ ;;
            3) [[ -n ${DEV:-} ]] && health_smart "$DEV"  || warn "pehle device chuno"; printf '  ENTER...'; read -r _ ;;
            4) [[ -n ${DEV:-} ]] && health_read_speed "$DEV"  || warn "pehle device chuno"; printf '  ENTER...'; read -r _ ;;
            5) [[ -n ${DEV:-} ]] && health_write_speed "$DEV" || warn "pehle device chuno"; printf '  ENTER...'; read -r _ ;;
            6) [[ -n ${DEV:-} ]] && health_badblocks "$DEV"   || warn "pehle device chuno"; printf '  ENTER...'; read -r _ ;;
            7) [[ -n ${DEV:-} ]] && health_boot_test "$DEV"   || warn "pehle device chuno"; printf '  ENTER...'; read -r _ ;;
            8)
                [[ -z ${DEV:-} ]] && { warn "pehle device chuno"; printf '  ENTER...'; read -r _; continue; }
                health_info "$DEV"; health_smart "$DEV"; health_read_speed "$DEV"
                printf '  ENTER...'; read -r _
                ;;
            9|q|Q) return 0 ;;
        esac
    done
}

# ========================== 50_gui.sh ======================================
# ------------------------------------------------------------------------------
#  MODULE: GUI wizard  (yad ya zenity -- mouse se chalne wala Rufus jaisa)
#
#  Auto-detect: DISPLAY/WAYLAND_DISPLAY + (yad ya zenity) available ho to
#  menu me "GUI wizard" option aata hai. `--gui` flag se seedha khulta hai.
#
#  Progress bar: FIFO ke through zenity/yad ko percentage bhejta hai, to
#  dd write ka live % GUI window me dikhega.
# ------------------------------------------------------------------------------

gui_detect() {
    [[ -n ${GUI_TOOL:-} ]] && return 0
    [[ -n ${DISPLAY:-} || -n ${WAYLAND_DISPLAY:-} ]] || return 1
    if have yad;       then GUI_TOOL=yad
    elif have zenity;  then GUI_TOOL=zenity
    else GUI_TOOL=""; return 1
    fi
    return 0
}

gui_hint_install() {
    err "GUI ke liye 'yad' ya 'zenity' chahiye + graphical session."
    err "  Debian/Ubuntu: sudo apt install yad        (ya: zenity)"
    err "  Fedora       : sudo dnf install yad        (ya: zenity)"
    err "  Arch         : sudo pacman -S yad          (ya: zenity)"
}

# --------------------------- simple dialogs -----------------------------------
gui_msg() {                      # $1=text
    gui_detect || return 1
    if [[ $GUI_TOOL == yad ]]; then yad --info --title="rufus-linux" --text="$1" --width=460 >/dev/null 2>&1
    else zenity --info --title="rufus-linux" --text="$1" --width=460 >/dev/null 2>&1
    fi
}

gui_warn() {
    gui_detect || return 1
    if [[ $GUI_TOOL == yad ]]; then yad --warning --title="rufus-linux" --text="$1" --width=460 >/dev/null 2>&1
    else zenity --warning --title="rufus-linux" --text="$1" --width=460 >/dev/null 2>&1
    fi
}

gui_error() {
    gui_detect || return 1
    if [[ $GUI_TOOL == yad ]]; then yad --error --title="rufus-linux" --text="$1" --width=520 >/dev/null 2>&1
    else zenity --error --title="rufus-linux" --text="$1" --width=520 >/dev/null 2>&1
    fi
}

gui_confirm() {                  # $1=text -> 0 agar YES
    gui_detect || return 1
    if [[ $GUI_TOOL == yad ]]; then
        yad --question --title="Confirm" --text="$1" --width=520 \
            --ok-label="Haan, continue" --cancel-label="Cancel" >/dev/null 2>&1
    else
        zenity --question --title="Confirm" --text="$1" --width=520 \
            --ok-label="Haan, continue" --cancel-label="Cancel" >/dev/null 2>&1
    fi
}

# --------------------------- pickers ------------------------------------------
gui_pick_iso() {                 # -> stdout path (rc!=0 agar cancel)
    gui_detect || return 1
    local out
    local dflt; dflt=$(gui_start_dir)      # sudo ke baad bhi sahi jagah khule
    if [[ $GUI_TOOL == yad ]]; then
        out=$(yad --file --title="ISO image select karo" --filename="$dflt" \
                  --file-filter='ISO images | *.iso *.ISO *.img *.IMG' \
                  --file-filter='All files | *' 2>/dev/null)
    else
        out=$(zenity --file-selection --title="ISO image select karo" \
                     --filename="$dflt" \
                     --file-filter='ISO images | *.iso *.ISO *.img' \
                     --file-filter='All files | *' 2>/dev/null)
    fi
    [[ -n $out && -f $out ]] || return 1
    printf '%s\n' "$out"
}

gui_pick_device() {              # -> stdout /dev/xxx
    gui_detect || return 1
    local -a names=() sizes=() models=() trans=()
    local line name size model tran
    while IFS='|' read -r name size model tran; do
        [[ -z $name ]] && continue
        names+=("/dev/$name"); sizes+=("$size"); models+=("$model"); trans+=("${tran:-n/a}")
    done < <(list_removable_disks)

    if (( ${#names[@]} == 0 )); then
        gui_error "Koi USB/removable disk nahi mili.\nPendrive laga kar dobara try karo."
        return 1
    fi

    local -a args=()
    local i
    for i in "${!names[@]}"; do
        args+=(TRUE "${names[$i]}" "${sizes[$i]}" "${models[$i]}" "${trans[$i]}")
    done

    local out
    if [[ $GUI_TOOL == yad ]]; then
        out=$(yad --list --radiolist --title="USB device select karo" \
                  --text="Apni pendrive chuno (ye ERASE hogi):" \
                  --column="" --column="Device" --column="Size" --column="Model" --column="Bus" \
                  --print-column=2 --separator="" --width=640 --height=360 \
                  --button="gtk-cancel:1" --button="gtk-ok:0" \
                  "${args[@]}" 2>/dev/null)
    else
        out=$(zenity --list --radiolist --title="USB device select karo" \
                     --text="Apni pendrive chuno (ye ERASE hogi):" \
                     --column=" " --column="Device" --column="Size" --column="Model" --column="Bus" \
                     --print-column=2 --width=640 --height=360 \
                     "${args[@]}" 2>/dev/null)
    fi
    [[ -n $out ]] || return 1
    out=${out%|*}
    printf '%s\n' "$out"
}

gui_pick_mode() {               # -> stdout auto|dd|part  (rc!=0 cancel)
    gui_detect || return 1
    local out
    if [[ $GUI_TOOL == yad ]]; then
        out=$(yad --list --radiolist --title="Write mode" \
                  --column="" --column="Mode" --column="Kya karta hai" \
                  --print-column=2 --separator="" --width=620 --height=300 \
                  --button="gtk-cancel:1" --button="gtk-ok:0" \
                  TRUE  auto      "Auto (recommended: hybrid? dd : partition)" \
                  FALSE dd        "ISO-Hybrid / dd (Linux ISOs ke liye best)" \
                  FALSE part      "Partition & Copy (+ persistence, Windows)" \
                  2>/dev/null)
    else
        out=$(zenity --list --radiolist --title="Write mode" \
                     --column=" " --column="Mode" --column="Kya karta hai" \
                     --print-column=2 --width=620 --height=300 \
                     TRUE  auto "Auto (recommended)" \
                     FALSE dd   "ISO-Hybrid / dd" \
                     FALSE part "Partition & Copy" \
                     2>/dev/null)
    fi
    [[ -n $out ]] || return 1
    printf '%s\n' "$out"
}

# --------------------------- progress bar -------------------------------------
gui_progress_open() {            # $1=title  $2=text  $3=pulsate(0|1)
    local title=$1 text=$2 pulsate=${3:-0}
    gui_detect || return 1
    ensure_tmpdir
    GUI_FIFO="$TMPDIR_P/gui.fifo"
    rm -f "$GUI_FIFO"
    mkfifo "$GUI_FIFO" || { warn "fifo nahi bani"; return 1; }

    local -a flags=()
    [[ $pulsate == 1 ]] && flags+=(--pulsate)

    if [[ $GUI_TOOL == yad ]]; then
        yad --progress --title="$title" --text="$text" --percentage=0 \
            --auto-close --auto-kill "${flags[@]}" \
            < "$GUI_FIFO" >/dev/null 2>&1 &
    else
        zenity --progress --title="$title" --text="$text" --percentage=0 \
            --auto-close --auto-kill "${flags[@]}" \
            < "$GUI_FIFO" >/dev/null 2>&1 &
    fi
    GUI_PID=$!

    if ! exec 3>"$GUI_FIFO"; then
        warn "GUI progress open fail"
        GUI_PID=""
        return 1
    fi
    GUI_PROGRESS=1
    return 0
}

gui_progress_set() {             # $1=pct(0-100)  $2=text
    (( ${GUI_PROGRESS:-0} )) || return 0
    { printf '%s\n' "$1"; printf '# %s\n' "${2:-}"; } >&3 2>/dev/null || true
}

gui_progress_pulse() {           # $1=text (pulsate dialog ke liye)
    (( ${GUI_PROGRESS:-0} )) || return 0
    printf '# %s\n' "${1:-}" >&3 2>/dev/null || true
}

gui_progress_close() {
    (( ${GUI_PROGRESS:-0} )) || return 0
    { printf '100\n'; } >&3 2>/dev/null || true
    exec 3>&- 2>/dev/null || true
    if [[ -n ${GUI_PID:-} ]]; then
        wait "$GUI_PID" 2>/dev/null
        GUI_PID=""
    fi
    GUI_PROGRESS=0
    return 0
}

# Non-root hone par write step ROOT chahiye -> pkexec se dobara chalate hain.
# pkexec ko ek polkit AUTH AGENT chahiye (gnome/KDE me hota hai). Agar agent na
# ho / user cancel kare to seedha "sudo ... --gui" wala hint dikhate hain.
gui_escalate_write() {
    local -a args=(--gui -i "$ISO" -d "$DEV" -m "$MODE" -y -p "$SCHEME" -f "$FS")
    [[ -n ${VOLLBL:-} ]] && args+=(-L "$VOLLBL")
    (( ${DO_VERIFY:-0} )) && args+=(--verify)
    (( ${PERSIST_MB:-0} )) && args+=(--persist "$PERSIST_MB")

    if have pkexec; then
        gui_msg "Root access chahiye.

Agle step me polkit password dialog aayega --
wahan apna USER password daalo."
        local rc=0
        timeout 180 pkexec env \
            DISPLAY="${DISPLAY:-}" \
            WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
            XAUTHORITY="${XAUTHORITY:-}" \
            XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" \
            RUFUS_ESCALATED=1 \
            "$SELF" "${args[@]}"
        rc=$?
        (( rc == 0 )) && return 0
        (( rc == 124 )) && gui_warn "Polkit dialog ka jawab nahi aaya (timeout)."
    fi

    gui_error "Write ke liye ROOT chahiye.

Koi polkit auth agent nahi mila (ya aapne cancel kiya).

Terminal me chalao:
  sudo -E ${SELF} --gui"
    return 1
}

# File-chooser kahan se start ho?  `sudo` ke baad HOME=/root ho jata hai, jisse
# picker /root me khulta hai -- aur /root me sab kuch DOTFILE folders hain
# (.config/.cache/...) jo GTK file chooser by default chhupata hai, isliye screen
# khali dikhti hai.  Isliye asli user ka ghar nikaal kar wahan se start karte hain.
gui_start_dir() {
    local d="${HOME:-${PWD:-/}}"
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        local u=${SUDO_USER:-} uh
        if [[ -n $u && $u != root ]]; then
            uh=$(getent passwd "$u" 2>/dev/null | cut -d: -f6)
            [[ -n $uh && -d $uh ]] && d=$uh
        fi
    fi
    if   [[ -d $d/Downloads ]]; then d="$d/Downloads"
    elif [[ ! -d $d ]];        then d="${PWD:-/}"
    fi
    printf '%s\n' "$d"
}

# ------------------- Asli GTK window  (Rufus-style + SELECT) ------------------
#  zenity ke --forms me file-browse field hota hi nahi (342.1 me bhi nahi).
#  Isliye Python+GTK3 se asli window banate hain -- usme SELECT button hai.
#  Python script yahin embedded hai, isliye deliverable phir bhi SINGLE file hai.
#
#  rc: 0 = START dabaya (sab settings set), 1 = cancel,
#      2 = GTK available nahi -> fallback (zenity forms / step-by-step chain)
gui_gtk_available() {
    have python3 || return 1
    python3 -c 'import gi; gi.require_version("Gtk","3.0"); from gi.repository import Gtk' \
        >/dev/null 2>&1
}

gui_gtk_window() {
    gui_gtk_available || return 2
    gui_detect || return 2
    ensure_tmpdir

    local py="$TMPDIR_P/rufus-wizard.py"
    cat > "$py" <<'PYEOF'
#!/usr/bin/env python3
# rufus-linux : GTK3 main window (Rufus-style)
#  ISO select ke liye SELECT button, device/scheme/fs/mode dropdowns, START.
#  stdout:  ISO=.. DEV=.. SCHEME=.. FS=.. MODE=.. LABEL=..     (har ek alag line)
#  rc: 0 = START,  1 = cancel/close
import os
import re
import sys

import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk


def env(key, default=''):
    val = os.environ.get(key)
    return default if val is None or val == '' else val


def _idx(values, val):
    """combo index -> value list me nahi mila to 0 (pehla = auto)."""
    try:
        return values.index(val)
    except ValueError:
        return 0


VERSION = env('RF_VERSION', '2.0')

SCHEMES = ['MBR (BIOS + UEFI)', 'GPT (UEFI only)']
FILESYSTEMS = ['Auto (recommended)', 'FAT32', 'NTFS', 'ext4']
MODES = ['Auto (recommended)', 'ISO-Hybrid (dd)', 'Partition & Copy']
# combo index -> asli value
FS_VALUES = ['auto', 'fat32', 'ntfs', 'ext4']
MODE_VALUES = ['auto', 'dd', 'part']


def iso_volume_label(path):
    """ISO9660 Primary Volume Descriptor (sector 16) se asli volume label.
    Mount kiye bina chalta hai -- isliye non-root GUI me bhi kaam karega."""
    try:
        with open(path, 'rb') as f:
            f.seek(32769)
            if f.read(5) != b'CD001':
                return ''
            f.seek(32808)
            raw = f.read(32)
        return raw.replace(b'\x00', b' ').decode('ascii', 'ignore').strip()
    except OSError:
        return ''


def is_hybrid(path):
    """ISO ka apna MBR hai (0x55AA @510) -> dd mode se boot hoga."""
    try:
        with open(path, 'rb') as f:
            f.seek(510)
            return f.read(2) == b'\x55\xaa'
    except OSError:
        return False


def looks_windows(path):
    """Windows ISO? -- filename + PVD label se (koi mount/7z nahi chahiye)."""
    hay = (os.path.basename(path) + ' ' + iso_volume_label(path)).lower()
    return bool(re.search(
        r'windows|win1[01]|win11|win_|server|x64fre|en-us_dv|_dv[0-9]|ccsa|cccoma',
        hay))


def recommend_scheme():
    """Rufus ki tarah: jis machine par chal rahe ho wahi target maano.
    UEFI -> GPT, purana BIOS -> MBR."""
    return 'gpt' if os.path.isdir('/sys/firmware/efi') else 'mbr'


def _visible(path):
    """Folder me koi CHHUPA hua (non-dot) entry hai?  Agar sirf .config/.cache
    jaise dotfiles hon to woh folder file-chooser me KHAAALI dikhega -- aise
    folder ko skip kar dete hain (yahi /root ke saath ho raha tha)."""
    try:
        return any(not n.startswith('.') for n in os.listdir(path))
    except OSError:
        return False


def start_dir():
    """Sabse achhi starting folder chuno (order me pehli jo usable ho)."""
    user = os.environ.get('USER') or os.environ.get('LOGNAME') or ''
    cands = []
    v = os.environ.get('RF_START_DIR')
    if v:
        cands.append(v)
    cands.append(os.path.expanduser('~/Downloads'))
    cands.append(os.path.expanduser('~'))
    if user:
        cands.append('/media/' + user)
        cands.append('/run/media/' + user)
    cands.append('/mnt')
    cands.append(os.getcwd())

    fallback = None
    for c in cands:
        if not c or not os.path.isdir(c):
            continue
        if not os.access(c, os.R_OK | os.X_OK):
            continue
        if fallback is None:
            fallback = c
        if _visible(c):
            return c
    return fallback or '/'

DEVICES = []            # [(path, label)]
for _line in env('RF_DEVICES').splitlines():
    _f = _line.split('|')
    if len(_f) >= 4 and _f[0]:
        _path = '/dev/' + _f[0]
        DEVICES.append((_path, '%s   %s   %s   [%s]'
                        % (_path, _f[1], _f[2], _f[3] or '?')))


class Main(Gtk.Window):
    def __init__(self):
        super().__init__(title='Rufus-Linux  ::  Bootable USB Creator  v' + VERSION)
        self.set_border_width(14)
        self.set_default_size(620, -1)
        self.result = 1

        grid = Gtk.Grid(column_spacing=10, row_spacing=9)
        self.add(grid)

        # user ne khud chhuna ya nahi -- sirf tab tak auto-fill chalta rahega
        # (Rufus bhi yahi karta hai: ISO select = sab auto, manual change = respect)
        self._touched_scheme = False
        self._touched_fs = False
        self._touched_label = False
        self._auto_label = ''
        self._setting_auto = False

        head = Gtk.Label()
        head.set_markup('<span size="x-large"><b>\U0001F427 Rufus-Linux</b></span>')
        head.set_halign(Gtk.Align.START)
        grid.attach(head, 0, 0, 3, 1)

        sub = Gtk.Label(
            label='Bootable USB creator for Linux  --  ISO ke liye SELECT dabao.')
        sub.set_halign(Gtk.Align.START)
        sub.set_opacity(0.70)
        grid.attach(sub, 0, 1, 3, 1)

        # --- Device -------------------------------------------------------
        grid.attach(self._label('Device'), 0, 2, 1, 1)
        self.dev_combo = Gtk.ComboBoxText()
        for path, label in DEVICES:
            self.dev_combo.append(path, label)
        self.dev_combo.set_hexpand(True)
        want = env('RF_DEV')
        idx = 0
        for i, (p, _l) in enumerate(DEVICES):
            if p == want:
                idx = i
                break
        if DEVICES:
            self.dev_combo.set_active(idx)
        grid.attach(self.dev_combo, 1, 2, 2, 1)

        # --- ISO image (SELECT button) ------------------------------------
        grid.attach(self._label('ISO image'), 0, 3, 1, 1)
        self.iso_entry = Gtk.Entry()
        self.iso_entry.set_placeholder_text('ISO file ka path likho, ya SELECT dabao...')
        self.iso_entry.set_hexpand(True)
        cur = env('RF_ISO')
        if cur:
            self.iso_entry.set_text(cur)
        self.iso_entry.connect('changed', self._on_iso_changed)
        grid.attach(self.iso_entry, 1, 3, 1, 1)

        sel = Gtk.Button(label='SELECT')
        sel.connect('clicked', self._on_select)
        grid.attach(sel, 2, 3, 1, 1)

        grid.attach(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL),
                    0, 4, 3, 1)

        # --- Partition scheme ---------------------------------------------
        grid.attach(self._label('Partition scheme'), 0, 5, 1, 1)
        self.sch_combo = Gtk.ComboBoxText()
        for v in SCHEMES:
            self.sch_combo.append_text(v)
        self.sch_combo.set_active(1 if env('RF_SCHEME', 'mbr') == 'gpt' else 0)
        # scheme badalne par Rufus ki tarah file system bhi apne aap theek ho
        self.sch_combo.connect('changed', self._on_scheme_changed)
        grid.attach(self.sch_combo, 1, 5, 2, 1)

        # --- File system ---------------------------------------------------
        grid.attach(self._label('File system'), 0, 6, 1, 1)
        self.fs_combo = Gtk.ComboBoxText()
        for v in FILESYSTEMS:
            self.fs_combo.append_text(v)
        self.fs_combo.set_active(_idx(FS_VALUES, env('RF_FS', 'auto')))
        self.fs_combo.connect('changed', self._on_fs_changed)
        grid.attach(self.fs_combo, 1, 6, 2, 1)

        # --- Write mode ----------------------------------------------------
        grid.attach(self._label('Write mode'), 0, 7, 1, 1)
        self.mode_combo = Gtk.ComboBoxText()
        for v in MODES:
            self.mode_combo.append_text(v)
        self.mode_combo.set_active(_idx(MODE_VALUES, env('RF_MODE', 'auto')))
        grid.attach(self.mode_combo, 1, 7, 2, 1)

        # --- Volume label ---------------------------------------------------
        grid.attach(self._label('Volume label'), 0, 8, 1, 1)
        self.vol_entry = Gtk.Entry()
        self.vol_entry.set_placeholder_text('khaali = auto (ISO ka label)')
        self.vol_entry.set_text(env('RF_LABEL'))
        self.vol_entry.set_hexpand(True)
        self.vol_entry.connect('changed', self._on_label_changed)
        grid.attach(self.vol_entry, 1, 8, 2, 1)

        # --- status + buttons -----------------------------------------------
        self.status = Gtk.Label(halign=Gtk.Align.START)
        self.status.set_line_wrap(True)
        self.status.set_xalign(0.0)
        grid.attach(self.status, 0, 9, 3, 1)

        box = Gtk.Box(spacing=8)
        box.set_halign(Gtk.Align.END)
        cancel = Gtk.Button(label='Cancel')
        cancel.connect('clicked', self._on_cancel)
        start = Gtk.Button(label='START')
        start.get_style_context().add_class('suggested-action')
        start.connect('clicked', self._on_start)
        box.pack_start(cancel, False, False, 0)
        box.pack_start(start, False, False, 0)
        grid.attach(box, 0, 10, 3, 1)

        if not DEVICES:
            self.set_status('Koi USB nahi mili -- pendrive lagao aur dobara kholo.')

    # ---------------- helpers -------------------------------------------
    def _label(self, text):
        lbl = Gtk.Label(label=text, halign=Gtk.Align.START)
        lbl.set_xalign(0.0)
        lbl.set_size_request(140, -1)
        return lbl

    def set_status(self, text):
        self.status.set_text(text)

    # ---------------- AUTO-FILL (Rufus jaisa) ------------------------------
    def predict_fs(self, path, scheme):
        """Write-time pe asli decision bash karega (mount karke) -- yahan sirf
        prediction dikhane ke liye, taaki user ko pata chale kya hone wala hai."""
        if looks_windows(path):
            return 'NTFS' if scheme == 'mbr' else 'FAT32 (install.wim split)'
        return 'FAT32'

    def _autofill(self, path):
        """ISO select hote hi SAB auto -- jaise Rufus me hota hai."""
        label = iso_volume_label(path)
        hybrid = is_hybrid(path)
        win = looks_windows(path)

        # programmatically badal rahe hain -> 'changed' ko user-action mat mano
        self._setting_auto = True
        try:
            # 1) volume label -- ISO ka asli label
            if label and not self._touched_label:
                self.vol_entry.set_text(label)
                self._auto_label = label

            # 2) partition scheme -- machine se (UEFI -> GPT, BIOS -> MBR)
            if not self._touched_scheme:
                self.sch_combo.set_active(1 if recommend_scheme() == 'gpt' else 0)

            # 3) file system -- user ne chhua nahi to wapas AUTO par
            if not self._touched_fs:
                self.fs_combo.set_active(_idx(FS_VALUES, 'auto'))
        finally:
            self._setting_auto = False

        scheme = 'gpt' if self.sch_combo.get_active() == 1 else 'mbr'
        try:
            size = '%.0f MB' % (os.path.getsize(path) / 1048576.0)
        except OSError:
            size = '?'
        info = []
        info.append('hybrid=YES -> dd' if hybrid else 'hybrid=NO -> partition')
        if win:
            info.append('Windows ISO')
        info.append('FS: auto -> %s' % self.predict_fs(path, scheme))
        self.set_status('%s   (%s)   %s'
                        % (os.path.basename(path), size, ' | '.join(info)))

    def _on_scheme_changed(self, _combo):
        if getattr(self, '_setting_auto', False):
            return
        self._touched_scheme = True
        # Rufus: scheme badalo -> target system/file system bhi badal jaate hain
        p = self.iso_entry.get_text().strip()
        if p and os.path.isfile(p) and not self._touched_fs:
            scheme = 'gpt' if self.sch_combo.get_active() == 1 else 'mbr'
            self.set_status('%s   |  Scheme %s  ->  FS (auto) = %s'
                            % (os.path.basename(p), scheme.upper(),
                               self.predict_fs(p, scheme)))

    def _on_fs_changed(self, _combo):
        if getattr(self, '_setting_auto', False):
            return
        self._touched_fs = True

    def _on_label_changed(self, _entry):
        if getattr(self, '_setting_auto', False):
            return
        self._touched_label = True

    def _on_iso_changed(self, _entry):
        p = self.iso_entry.get_text().strip()
        if p and os.path.isfile(p):
            self._autofill(p)

    def err(self, msg):
        d = Gtk.MessageDialog(transient_for=self, modal=True,
                              message_type=Gtk.MessageType.ERROR,
                              buttons=Gtk.ButtonsType.OK, text=msg)
        d.run()
        d.destroy()

    def pick_iso(self):
        d = Gtk.FileChooserDialog(title='ISO image select karo', parent=self,
                                  action=Gtk.FileChooserAction.OPEN)
        d.add_button('_Cancel', Gtk.ResponseType.CANCEL)
        d.add_button('_Open', Gtk.ResponseType.OK)
        f = Gtk.FileFilter()
        f.set_name('ISO images (*.iso / *.img)')
        for pat in ('*.iso', '*.ISO', '*.img', '*.IMG'):
            f.add_pattern(pat)
        d.add_filter(f)
        f2 = Gtk.FileFilter()
        f2.set_name('All files')
        f2.add_pattern('*')
        d.add_filter(f2)
        # folder dikhne layak ho (sirf-dotfiles wala folder KHAALI dikhta hai)
        d.set_current_folder(start_dir())
        path = None
        if d.run() == Gtk.ResponseType.OK:
            path = d.get_filename()
        d.destroy()
        return path

    # ---------------- actions --------------------------------------------
    def _on_select(self, _b):
        path = self.pick_iso()
        if not path:
            return
        # 'changed' signal -> _autofill() sab kuch auto set kar dega
        self.iso_entry.set_text(path)

    def _on_cancel(self, _b):
        self.result = 1
        Gtk.main_quit()

    def on_delete(self, *_args):
        self.result = 1
        Gtk.main_quit()
        return False

    def _on_start(self, _b):
        iso = self.iso_entry.get_text().strip()
        if not iso:
            iso = self.pick_iso()
            if not iso:
                self.set_status('ISO select cancel kiya gaya.')
                return
            self.iso_entry.set_text(iso)
        iso = os.path.abspath(os.path.expanduser(iso))
        if not os.path.isfile(iso):
            self.err('ISO file nahi mili:\n\n' + iso)
            self.set_status('ISO file nahi mili.')
            return
        dev = self.dev_combo.get_active_id()
        if not dev:
            self.err('Koi USB device select nahi hui.\n\n'
                     'Pendrive lagao aur dobara kholo.')
            self.set_status('USB device chahiye.')
            return
        scheme = 'gpt' if self.sch_combo.get_active() == 1 else 'mbr'
        fs = FS_VALUES[self.fs_combo.get_active()]
        mode = MODE_VALUES[self.mode_combo.get_active()]
        label = self.vol_entry.get_text().strip()
        sys.stdout.write('ISO=%s\nDEV=%s\nSCHEME=%s\nFS=%s\nMODE=%s\nLABEL=%s\n'
                         % (iso, dev, scheme, fs, mode, label))
        sys.stdout.flush()
        self.result = 0
        Gtk.main_quit()


win = Main()
win.connect('delete-event', win.on_delete)
win.show_all()
Gtk.main()
sys.exit(win.result)
PYEOF
    [[ -s $py ]] || return 2

    # device list bash se -> env (taaki lsblk logic dobara na likhna pade)
    local devlines="" name size model tran
    while IFS='|' read -r name size model tran; do
        [[ -z $name ]] && continue
        devlines+="$name|$size|$model|$tran"$'\n'
    done < <(list_removable_disks)

    local out rc=0
    out=$(RF_VERSION="$VERSION" \
            RF_START_DIR="$(gui_start_dir)" \
            RF_DEVICES="$devlines" \
            RF_ISO="${ISO:-}" RF_DEV="${DEV:-}" \
            RF_SCHEME="${SCHEME:-mbr}" RF_FS="${FS:-auto}" \
            RF_MODE="${MODE:-auto}" RF_LABEL="${VOLLBL:-}" \
            python3 "$py" 2>"$TMPDIR_P/wizard.err") || rc=$?

    if (( rc != 0 )); then
        (( rc == 1 )) && return 1          # user ne cancel/close kiya
        warn "GTK wizard nahi chala -- fallback use hoga."
        sed 's/^/      /' "$TMPDIR_P/wizard.err" 2>/dev/null | tail -5 >&2
        return 2
    fi

    local k v
    while IFS='=' read -r k v; do
        case $k in
            ISO)    ISO=$v ;;
            DEV)    DEV=$v ;;
            SCHEME) SCHEME=$v ;;
            FS)     FS=$v ;;
            MODE)   MODE=$v ;;
            LABEL)  VOLLBL=$v ;;
        esac
    done <<< "$out"

    [[ -n ${ISO:-} && -n ${DEV:-} ]] || return 2
    return 0
}

# ------------------- Rufus jaisa EK hi main window ----------------------------
#  rc:  0 = START dabaya (ISO/DEV/SCHEME/FS/MODE/VOLLBL set)
#       1 = cancel / koi device nahi
#       2 = is tool ke liye forms supported nahi (fallback: per-step chain)
gui_main_window() {
    gui_detect || return 2

    # ---- device list ----
    local -a dev_labels=()
    local name size model tran
    while IFS='|' read -r name size model tran; do
        [[ -z $name ]] && continue
        dev_labels+=("/dev/$name   $size   ${model:-n/a}   [${tran:-?}]")
    done < <(list_removable_disks)

    if (( ${#dev_labels[@]} == 0 )); then
        # Window tab bhi dikhao -- placeholder rakhenge.  START dabane par
        # neeche "pendrive lagao" wala error aayega.
        dev_labels=("(koi USB nahi -- pendrive lagao)")
    fi

    local dev_values
    dev_values=$(IFS='|'; printf '%s' "${dev_labels[*]}")

    # ---- combo values: current selection ko pehle rakho = default ----
    local sch_vals="MBR (BIOS + UEFI)|GPT (UEFI only)"
    [[ ${SCHEME:-mbr} == gpt ]] && sch_vals="GPT (UEFI only)|MBR (BIOS + UEFI)"

    local fs_vals="Auto (recommended)|FAT32|NTFS|ext4"
    case ${FS:-auto} in
        fat32) fs_vals="FAT32|Auto (recommended)|NTFS|ext4" ;;
        ntfs)  fs_vals="NTFS|Auto (recommended)|FAT32|ext4" ;;
        ext4)  fs_vals="ext4|Auto (recommended)|FAT32|NTFS" ;;
    esac

    local mode_vals="Auto (recommended)|ISO-Hybrid (dd)|Partition & Copy"
    case ${MODE:-auto} in
        dd)   mode_vals="ISO-Hybrid (dd)|Auto (recommended)|Partition & Copy" ;;
        part) mode_vals="Partition & Copy|Auto (recommended)|ISO-Hybrid (dd)" ;;
    esac

    local title="Rufus-Linux  ::  Bootable USB Creator  v${VERSION}"
    local head="ISO chuno, device chuno, options set karo -- phir START dabao."
    local out rc=0

    if [[ $GUI_TOOL == yad ]]; then
        local dsv=$dev_values sv=${sch_vals//|/!} fv=${fs_vals//|/!} mv=${mode_vals//|/!}
        out=$(yad --form --title="$title" --text="$head" --width=600 \
                  --field="ISO image:DIR"            "${ISO:-}" \
                  --field="USB device:CB"            "$dsv" \
                  --field="Partition scheme:CB"      "$sv" \
                  --field="File system:CB"           "$fv" \
                  --field="Write mode:CB"            "$mv" \
                  --field="New volume label"         "${VOLLBL:-}" \
                  --separator=$'\x1f' \
                  --button="gtk-cancel:1" --button="gtk-ok:0" 2>/dev/null) || rc=$?
    elif [[ $GUI_TOOL == zenity ]]; then
        zenity --forms --help >/dev/null 2>&1 || return 2
        out=$(zenity --forms \
                  --title="$title" --text="$head" --width=600 \
                  --add-entry="ISO image path  (khaali = file picker khulega)" \
                  --add-combo="USB device"       --combo-values="$dev_values" \
                  --add-combo="Partition scheme" --combo-values="$sch_vals" \
                  --add-combo="File system"      --combo-values="$fs_vals" \
                  --add-combo="Write mode"       --combo-values="$mode_vals" \
                  --add-entry="New volume label  (khaali = auto)" \
                  --separator=$'\x1f' \
                  --ok-label="START" --cancel-label="Cancel" 2>/dev/null) || rc=$?
    else
        return 2
    fi
    (( rc == 0 )) || return 1

    local f_iso f_dev f_sch f_fs f_mode f_lbl
    IFS=$'\x1f' read -r f_iso f_dev f_sch f_fs f_mode f_lbl <<< "$out"

    # trim (sed taaki path ka content safe rahe)
    f_iso=$(printf '%s' "$f_iso" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    f_lbl=$(printf '%s' "$f_lbl" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

    if [[ -n $f_iso ]]; then
        [[ $f_iso == /* ]] || f_iso="$PWD/$f_iso"
        if [[ -f $f_iso ]]; then ISO=$f_iso
        else
            gui_error "ISO file nahi mili:

$f_iso"
            return 1
        fi
    fi

    if [[ $f_dev == /dev/* ]]; then
        DEV=${f_dev%% *}
    else
        gui_error "Koi USB device select nahi hui.

Pendrive lagao aur dobara kholo."
        return 1
    fi

    case $f_sch in
        GPT*) SCHEME=gpt ;;
        *)    SCHEME=mbr ;;
    esac
    case $f_fs in
        Auto*|auto*) FS=auto ;;
        NTFS*)       FS=ntfs ;;
        ext4*)       FS=ext4 ;;
        *)           FS=fat32 ;;
    esac
    case $f_mode in
        *dd*)        MODE=dd ;;
        *Partition*) MODE=part ;;
        *)           MODE=auto ;;
    esac
    VOLLBL=$f_lbl
    return 0
}

# --------------------------- full wizard --------------------------------------
gui_wizard() {
    gui_detect || { gui_hint_install; return 1; }

    local interactive=0 p rc

    # Rufus jaisa auto-fill: user/CLI ne jo khud set nahi kiya wo yahan se.
    # -- UEFI machine -> GPT, mode -> auto, (ISO milte hi label + FS auto).
    # Window kholne se PEHLE, taaki dropdowns me sahi default dikhe.
    auto_defaults_from_iso

    # ---- 1) pehle KOSHISH karo: asli GTK window (SELECT button ke saath) ----
    #     (sirf tab jab ISO/DEV CLI se na diya ho -- pkexec re-exec me skip)
    if [[ -z ${ISO:-} || -z ${DEV:-} ]]; then
        gui_gtk_window
        rc=$?
        if (( rc == 2 )); then            # GTK nahi -> zenity forms window
            gui_main_window
            rc=$?
        fi
        case $rc in
            0)
                info "Main window se sab set ho gaya."
                # window/user ki values ab authoritative hain -- auto-fill
                # inhe dobara overwrite na kare
                SCHEME_SET=1; FS_SET=1; MODE_SET=1
                [[ -n ${VOLLBL:-} ]] && VOLLBL_SET=1
                ;;
            1) info "User ne cancel kiya (main window)."; return 0 ;;
            *) interactive=1 ;;   # dono unsupported -> step-by-step chain
        esac
    fi

    # ---- 2) fallback: jo reh gaya uske liye per-step pickers ----
    if [[ -z ${ISO:-} ]]; then
        interactive=1
        if ! p=$(gui_pick_iso); then info "Cancel (ISO select)."; return 0; fi
        ISO=$p
    fi
    # ISO mil gayi -> ab label (PVD se) aur FS=auto set ho jayega
    auto_defaults_from_iso
    if is_hybrid_iso; then
        info "ISO: $(basename "$ISO")  [hybrid: YES]"
    else
        info "ISO: $(basename "$ISO")  [hybrid: NO -> partition mode better]"
    fi

    if [[ -z ${DEV:-} ]]; then
        interactive=1
        if ! p=$(gui_pick_device); then info "Cancel (device select)."; return 0; fi
        DEV=$p
    fi

    if (( interactive )); then
        if p=$(gui_pick_mode); then MODE=$p; fi
    fi

    # FS = auto hai to yahin resolve karke confirm dialog me ASLI value dikhao
    # (taaki user ko pata chale kya banne wala hai).  Write bhi yahi lega --
    # root child dobara mount karke exact calculate karega.
    local fs_show=$FS
    if [[ $FS == auto ]]; then
        fs_show=$(resolve_fs_auto "$ISO")
        info "Auto file system -> $fs_show"
    fi

    local mode_show=$MODE
    [[ $MODE == auto ]] && { is_hybrid_iso && mode_show="dd (hybrid)" || mode_show="part"; }

    info "Device: $DEV   Mode: $mode_show   Scheme: $SCHEME   FS: $fs_show"

    # ---- 3) ERASE confirmation (hamesha, jab tak -y na ho) ----
    if (( ASSUME_YES == 0 )); then
        if ! gui_confirm "ISO    : $(basename "$ISO")
Device : $DEV   ($(lsblk -dn -o SIZE "$DEV" 2>/dev/null | xargs)  $(lsblk -dn -o MODEL "$DEV" 2>/dev/null | xargs))
Scheme : $SCHEME    FS: $fs_show    Mode: $mode_show
Label  : $(sanitize_label "${VOLLBL:-}")   (auto)
Size   : $(human "$(stat -c '%s' "$ISO" 2>/dev/null || echo 0)")  ->  $(lsblk -dn -o SIZE "$DEV" 2>/dev/null | xargs)

${DEV##*/} ka SAARA DATA ERASE ho jayega.

Aage badhein?"; then
            info "User ne cancel kiya."
            return 0
        fi
    fi
    ASSUME_YES=1

    # ---- 4) yahan tak sab read-only tha; ab likhna hai -> root chahiye ----
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        gui_escalate_write || return 1
        return 0          # escalated child khud progress + DONE dialog dikhayega
    fi

    ensure_tmpdir
    gui_progress_open "rufus-linux" "Writing $(basename "$ISO") ..." 0 || true

    local rc=0
    do_start || rc=$?

    gui_progress_close

    if (( rc == 0 )); then
        gui_msg "DONE

Bootable USB tayyar hai!
Device : $DEV
Mode   : $MODE

Ab USB laga kar reboot karo."
    else
        gui_error "Write fail ho gaya (code $rc).
Terminal/log me details dekho."
    fi
    return $rc
}

# ========================== 99_main.sh ======================================
if [[ "${RUFUS_LINUX_LIB:-0}" != "1" ]]; then
    main "$@"
fi
