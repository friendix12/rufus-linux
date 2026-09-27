#!/usr/bin/env bash
# ==============================================================================
#  integration-test.sh  --  rufus-linux.sh ka end-to-end write test
#
#  REAL dd write + partition write chalata hai, lekin kisi bhi asli USB par
#  nahi -- ek loop device (file-backed) par. Isliye koi cheez barbad nahi hoti.
#
#  ROOT CHAHIYE:   sudo ./integration-test.sh
#
#  Kya verify karta hai:
#    1. dd/ISO-Hybrid mode  -> device bytes exactly ISO ke barabar
#    2. Partition mode      -> partition bana, FAT32 format hua, files copy huin
#    3. auto mode           -> hybrid ISO detect karke dd chuna
#    4. verify flag         -> --verify pass hota hai
#    5. safety              -> asli root disk par likhne se REFUSED
# ==============================================================================
set -u
cd "$(dirname "$0")"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "ROOT CHAHIYE:  sudo $0"; exit 1
fi

SCRIPT=./rufus-linux.sh
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

WORK=$(mktemp -d /tmp/rufus-itest.XXXXXX)
LOOPDEV=""
cleanup() {
    mountpoint -q "$WORK/mnt" 2>/dev/null && umount -l "$WORK/mnt" 2>/dev/null
    if [[ -n $LOOPDEV ]]; then
        losetup -d "$LOOPDEV" 2>/dev/null
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# ---- fake ISOs banao ---------------------------------------------------------
# genisoimage se asli ISO9660 banata hai, phir hybrid marker patch karta hai.
SRC="$WORK/isosrc"
mkdir -p "$SRC/EFI/BOOT" "$SRC/boot" "$SRC/casper"
printf 'hello from rufus-linux integration test\n' > "$SRC/README.txt"
# dummy UEFI boot file (ensure_uefi_bootfile() isko dhoondta hai)
printf 'MZ-dummy-efi-binary' > "$SRC/EFI/BOOT/BOOTX64.EFI"
# dummy kernel/initrd
dd if=/dev/urandom of="$SRC/casper/vmlinuz"  bs=1k count=32 status=none
dd if=/dev/urandom of="$SRC/casper/initrd"   bs=1k count=64 status=none
# dummy isolinux dir (install_bios_boot() isko dhoondta hai)
printf 'DEFAULT linux\nLABEL linux\n  KERNEL /casper/vmlinuz\n' > "$SRC/boot/isolinux.cfg"

ISO_PLAIN="$WORK/fake-plain.iso"
ISO="$WORK/fake-hybrid.iso"

mkiso() {
    genisoimage -quiet -R -J -o "$1" "$SRC" 2>"$WORK/geniso.log" || {
        echo "genisoimage fail:"; cat "$WORK/geniso.log"; return 1; }
}
mkiso "$ISO_PLAIN" || { echo "ISO nahi ban paya"; exit 1; }
cp -f "$ISO_PLAIN" "$ISO"
# hybrid marker: MBR signature 0x55AA @ offset 510 (isohybrid wali tarah)
printf '\x55\xaa' | dd of="$ISO" bs=1 seek=510 conv=notrunc status=none
printf 'RUFUS-LINUX-INTEGRATION-PAYLOAD-v1' | dd of="$ISO" bs=1 seek=4096 conv=notrunc status=none

echo "  ISO (hybrid) : $ISO  ($(stat -c %s "$ISO") bytes)"
echo "  ISO (plain)  : $ISO_PLAIN"

new_loop() {  # $1 = size in MB
    local img="$WORK/disk$RANDOM.img"
    truncate -s "$1M" "$img"
    losetup -f --show "$img"
}

echo "=========================================================="
echo "  rufus-linux.sh  ::  INTEGRATION TEST  (loop-backed)"
echo "=========================================================="
echo "  workdir : $WORK"
echo

# ---------------------------------------------------------------- test 1: dd --
echo "== [1] dd mode : ISO -> device raw write =="
LOOPDEV=$(new_loop 16) || { bad "loop device bana"; }
if [[ -n $LOOPDEV ]]; then
    echo "  loop: $LOOPDEV"
    RUFUS_ALLOW_LOOP=1 "$SCRIPT" -i "$ISO" -d "$LOOPDEV" -m dd -y --no-eject \
        >"$WORK/t1.log" 2>&1
    rc=$?
    if (( rc == 0 )); then
        ok "dd mode exit=0"
    else
        bad "dd mode exit=$rc"; tail -5 "$WORK/t1.log" | sed 's/^/        /'
    fi
    if cmp -s -n "$(stat -c %s "$ISO")" "$LOOPDEV" "$ISO"; then
        ok "device bytes == ISO bytes"
    else
        bad "device bytes != ISO bytes"
    fi
    losetup -d "$LOOPDEV" 2>/dev/null; LOOPDEV=""
fi

# ------------------------------------------------------- test 2: partition mode --
echo "== [2] partition mode : MBR + FAT32 + file copy =="
LOOPDEV=$(new_loop 64)
if [[ -n $LOOPDEV ]]; then
    RUFUS_ALLOW_LOOP=1 "$SCRIPT" -i "$ISO_PLAIN" -d "$LOOPDEV" -m part -p mbr -f fat32 \
        -y --no-eject >"$WORK/t2.log" 2>&1
    rc=$?
    if (( rc == 0 )); then ok "partition mode exit=0"; else
        bad "partition mode exit=$rc"; tail -8 "$WORK/t2.log" | sed 's/^/        /'
    fi

    sig=$(dd if="$LOOPDEV" bs=1 skip=510 count=2 status=none | od -An -tx1 | tr -d ' \n')
    [[ $sig == "55aa" ]] && ok "MBR boot signature (55aa) present" \
                         || bad "MBR boot signature missing (got '$sig')"

    ptype=$(lsblk -dn -o PTTYPE "$LOOPDEV" 2>/dev/null)
    [[ $ptype == dos ]] && ok "partition table = msdos ($ptype)" \
                         || bad "partition table msdos nahi (got '$ptype')"

    P1=$(lsblk -ln -o NAME "$LOOPDEV" | sed -n '2p')
    fstype=$(lsblk -ln -o FSTYPE "/dev/$P1" 2>/dev/null)
    [[ ${fstype:-} == vfat ]] && ok "partition formatted vfat" \
                              || bad "vfat nahi (got '${fstype:-none}')"

    # kya asli files copy hui? -> partition mount karke check
    mkdir -p "$WORK/mnt"
    if mount "/dev/$P1" "$WORK/mnt" 2>/dev/null; then
        [[ -f "$WORK/mnt/README.txt" ]] && ok "README.txt partition par copy hua" \
                                        || { bad "README.txt nahi mila"; ls "$WORK/mnt" | sed 's/^/        /'; }
        [[ -f "$WORK/mnt/EFI/BOOT/BOOTX64.EFI" ]] && ok "UEFI boot file copy hui" \
                                                   || bad "EFI/BOOT/BOOTX64.EFI nahi mili"
        [[ -f "$WORK/mnt/casper/vmlinuz" ]] && ok "casper/vmlinuz copy hua" \
                                             || bad "casper/vmlinuz nahi mila"
        # FAT32 label check
        lbl=$(blkid -o value -s LABEL "/dev/$P1" 2>/dev/null)
        echo "        volume label = '${lbl:-<none>}'"
        umount "$WORK/mnt" 2>/dev/null || true
    else
        bad "partition mount nahi hua"
    fi

    if command -v syslinux >/dev/null 2>&1 || [[ -f /usr/lib/syslinux/mbr/mbr.bin ]]; then
        ok "syslinux boot code available (BIOS boot ban payega)"
    else
        printf '  \033[33mNOTE\033[0m  syslinux nahi mila -> is machine par BIOS boot code\n'
        printf '             install nahi hua. (apt install syslinux) -- UEFI boot phir bhi chalega.\n'
    fi
    losetup -d "$LOOPDEV" 2>/dev/null; LOOPDEV=""
fi

# ------------------------------------------------------------- test 3: auto mode --
echo "== [3] auto mode : hybrid vs plain detect =="
LOOPDEV=$(new_loop 16)
if [[ -n $LOOPDEV ]]; then
    RUFUS_ALLOW_LOOP=1 "$SCRIPT" -i "$ISO" -d "$LOOPDEV" -m auto -y --no-eject \
        >"$WORK/t3.log" 2>&1
    rc=$?
    grep -q "ISO-Hybrid (dd) mode" "$WORK/t3.log" \
        && ok "hybrid ISO -> dd mode chuna" \
        || { bad "hybrid ISO -> dd choose nahi"; tail -5 "$WORK/t3.log" | sed 's/^/        /'; }
    (( rc == 0 )) && ok "auto(hybrid) exit=0" || bad "auto(hybrid) exit=$rc"
    losetup -d "$LOOPDEV" 2>/dev/null; LOOPDEV=""
fi
LOOPDEV=$(new_loop 64)
if [[ -n $LOOPDEV ]]; then
    RUFUS_ALLOW_LOOP=1 "$SCRIPT" -i "$ISO_PLAIN" -d "$LOOPDEV" -m auto -y --no-eject \
        >"$WORK/t3b.log" 2>&1
    rc=$?
    grep -q "Partition & Copy mode" "$WORK/t3b.log" \
        && ok "plain ISO -> partition mode chuna" \
        || { bad "plain ISO -> partition choose nahi"; tail -5 "$WORK/t3b.log" | sed 's/^/        /'; }
    (( rc == 0 )) && ok "auto(plain) exit=0" || bad "auto(plain) exit=$rc"
    losetup -d "$LOOPDEV" 2>/dev/null; LOOPDEV=""
fi

# ------------------------------------------------------------ test 4: --verify --
echo "== [4] --verify flag =="
LOOPDEV=$(new_loop 16)
if [[ -n $LOOPDEV ]]; then
    RUFUS_ALLOW_LOOP=1 "$SCRIPT" -i "$ISO" -d "$LOOPDEV" -m dd -y --no-eject --verify \
        >"$WORK/t4.log" 2>&1
    rc=$?
    grep -q "VERIFIED" "$WORK/t4.log" && ok "--verify pass hua" || bad "--verify fail"
    (( rc == 0 )) && ok "verify exit=0" || bad "verify exit=$rc"
    losetup -d "$LOOPDEV" 2>/dev/null; LOOPDEV=""
fi

# ------------------------------------------------------------ test 5: SAFETY ----
echo "== [5] safety : root disk par likhne se REFUSED =="
ROOTDEV=$(findmnt -n -o SOURCE / )
ROOTDISK=$(lsblk -ndo PKNAME "$ROOTDEV" 2>/dev/null | head -1)
ROOTDISK=${ROOTDISK:-$(basename "${ROOTDEV%[0-9]*}")}
out=$(RUFUS_ALLOW_LOOP=1 "$SCRIPT" -i "$ISO" -d "/dev/$ROOTDISK" -m dd -y 2>&1 </dev/null)
rc=$?
if (( rc != 0 )) && grep -qiE "REFUSED|barbad|mount hai" <<<"$out"; then
    ok "root disk /dev/$ROOTDISK ko REFUSED kiya"
else
    bad "root disk ko REFUSE nahi kiya! rc=$rc"
    echo "$out" | tail -3 | sed 's/^/        /'
fi

# ------------------------------------------------- test 6: bad args ------------
echo "== [6] argument validation =="
"$SCRIPT" --mode bogus 2>/dev/null && bad "bogus --mode accept hua" || ok "bogus --mode reject"
"$SCRIPT" --fs bogus    2>/dev/null && bad "bogus --fs accept hua"   || ok "bogus --fs reject"
"$SCRIPT" --part bogus  2>/dev/null && bad "bogus --part accept hua" || ok "bogus --part reject"
"$SCRIPT" -i /nope.iso -d /dev/null -y 2>/dev/null && bad "nonexistent ISO accept" || ok "nonexistent ISO reject"

echo
echo "=========================================================="
echo "  TOTAL: $pass passed, $fail failed"
echo "=========================================================="
exit $(( fail > 0 ))
