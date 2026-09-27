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
