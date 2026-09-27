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
