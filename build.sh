#!/usr/bin/env bash
# ==============================================================================
#  build.sh  --  src/*.sh modules ko ek single rufus-linux.sh file me join karta hai
#
#  Kyun?  Kyunki deliverable ek hi self-contained script honi chahiye (pen drive
#         par copy karke le jao, koi dependency nahi). Lekin source rakhna
#         aasan ho isliye code modules me split hai.
#
#  Usage:  ./build.sh
# ==============================================================================
set -euo pipefail
cd "$(dirname "$0")"

OUT="rufus-linux.sh"
TMP=".build.tmp.$$"

# module order lexicographic (00_..., 10_..., ...) -- pahle load, aakhir me main)
mapfile -t PARTS < <(ls -1 src/*.sh | sort)

(( ${#PARTS[@]} )) || { echo "src/*.sh nahi mile"; exit 1; }

{
    # pehla part asli file hona chahiye (shebang wahi se aayega)
    cat "${PARTS[0]}"

    printf '\n# #############################################################################\n'
    printf '#  MODULES below are appended by build.sh -- edit src/*.sh, then run ./build.sh\n'
    printf '# #############################################################################\n\n'

    for p in "${PARTS[@]:1}"; do
        printf '\n# ========================== %s ======================================\n' "$(basename "$p")"
        cat "$p"
    done
} > "$TMP"

chmod +x "$TMP"
bash -n "$TMP" || { echo "SYNTAX ERROR in built file"; rm -f "$TMP"; exit 1; }
mv -f "$TMP" "$OUT"

# ---- summary ----------------------------------------------------------------
echo "built: $OUT"
printf '  modules : %d\n' "${#PARTS[@]}"
printf '  lines   : %s\n' "$(wc -l < "$OUT")"
printf '  size    : %s\n' "$(du -h "$OUT" | cut -f1)"
printf '  syntax  : OK\n'
