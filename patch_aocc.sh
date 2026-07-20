#!/usr/bin/env bash
set -euo pipefail

ver=$(patchelf --version | grep -oP '\d+\.\d+\.\d+')
if [[ $(printf '%s\n0.17.2' "$ver" | sort -V | head -1) == 0.17.2 ]]; then
  printf "patchelf version OK\n"
else
  printf "patchelf version too low. Please install 0.17.2 or newer.\n" >&2
  exit 1
fi

AOCC_VERSION='5.2.0'
GLIBC_LIB="$HOME/glibc-2.28/install/lib"
# For libstdc++.so.6
GCC_LIB="/home/software/gnu/11.2/lib64"

AOCC_PREFIX=$(spack location -i "aocc@$AOCC_VERSION")
GLIBC_LD="$GLIBC_LIB/ld-linux-x86-64.so.2"

# Patch all the actual AOCC ELF files (many are symlinked, and patchelf will
# overwrite symlinks by default) to use our new glibc to meet AOCC's min 
# version requirement. We can steal the other dependencies from GCC and
# system libraries
find "$AOCC_PREFIX" -type f \( -name "*.so*" -o -perm -u+x \) \
| while read -r f; do
    if file "$f" | grep -q ELF; then
        OLD_RPATH=$(patchelf --print-rpath "$f" 2>/dev/null)

        if [[ -n "$OLD_RPATH" ]]; then
            NEW_RPATH="$GLIBC_LIB:$OLD_RPATH:$GCC_LIB:/usr/lib64:/lib64"
        else
            NEW_RPATH="$GLIBC_LIB:$AOCC_PREFIX/lib:$GCC_LIB:/usr/lib64:/lib64"
        fi

        printf "Patching: %s (rpath: %s)\n" "$f" "$NEW_RPATH"
        patchelf --force-rpath --set-rpath "$NEW_RPATH" "$f"

        if file "$f" | grep -q "executable"; then
            patchelf --set-interpreter "$GLIBC_LD" "$f"
        fi
    fi
done
