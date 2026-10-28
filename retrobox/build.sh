#!/usr/bin/env bash
# Builds the RetroBox QEMU (MESA GL pass-through, SDL on KMS/DRM, no X) and
# the matching Windows XP guest tools from this checkout.
#
# Usage: retrobox/build.sh [--install-deps] [host|guest|all]   (default: all)
#
# Runs on Debian 13 amd64 (the RetroBox host release): in CI, or locally with
#   docker run --rm --platform linux/amd64 -v "$PWD:/src" -w /src \
#       debian:trixie retrobox/build.sh --install-deps
#
# Outputs in retrobox/out/:
#   qemu-retrobox-<qemu>-<rev>-linux-x86_64.tar.gz   unpacks to $PREFIX
#   retrobox-xp-tools-<rev>.iso                      guest DLLs and driver
#   SHA256SUMS
#
# Host and guest must come from the same commit: sign_commit stamps the QEMU
# build with this repository's revision and the wrappers check it.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RB="$ROOT/retrobox"
WORK="$RB/work"
OUT="$RB/out"
PREFIX="${PREFIX:-/opt/qemu-retrobox}"
MINGW=i686-w64-mingw32
JOBS="$(nproc)"

# shellcheck source=qemu.env
. "$RB/qemu.env"

log() { echo "==> $*"; }
die() { echo "error: $*" >&2; exit 1; }

DEPS=(
    build-essential git ninja-build pkg-config python3 python3-venv
    libglib2.0-dev libpixman-1-dev zlib1g-dev libzstd-dev libslirp-dev
    libsdl2-dev libasound2-dev libx11-dev libxxf86vm-dev libgl-dev
    gcc-mingw-w64-i686 binutils-mingw-w64-i686 mingw-w64-tools xxd perl
    xorriso curl ca-certificates
)

install_deps() {
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${DEPS[@]}"
    git config --global --add safe.directory "$ROOT"
}

revision() {
    git -C "$ROOT" rev-parse --short HEAD
}

build_host() {
    local tarball="$WORK/qemu-$QEMU_VERSION.tar.xz"
    local tree="$WORK/qemu-$QEMU_VERSION"
    local build="$WORK/build"
    local stage="$WORK/stage"

    mkdir -p "$WORK" "$OUT"
    if [ ! -f "$tarball" ] || ! echo "$QEMU_SHA256  $tarball" | sha256sum -c --status; then
        log "downloading QEMU $QEMU_VERSION"
        curl -fL --retry 3 -o "$tarball" "https://download.qemu.org/qemu-$QEMU_VERSION.tar.xz"
    fi
    echo "$QEMU_SHA256  $tarball" | sha256sum -c --status || die "QEMU tarball checksum mismatch"

    log "preparing QEMU $QEMU_VERSION with $QEMU3DFX_PATCH and RetroBox patches"
    rm -rf "$tree" "$build" "$stage"
    tar -xf "$tarball" -C "$WORK"
    cp -r "$ROOT/qemu-0/hw/3dfx" "$ROOT/qemu-1/hw/mesa" "$tree/hw/"
    (cd "$tree" && patch -p0 -s -i "$ROOT/$QEMU3DFX_PATCH" && bash "$ROOT/scripts/sign_commit")
    local fix
    for fix in "$RB"/patches/*.patch; do
        log "applying $(basename "$fix")"
        (cd "$tree" && patch -p0 -s -i "$fix")
    done

    log "configuring (prefix $PREFIX)"
    mkdir -p "$build"
    (cd "$build" && "$tree/configure" \
        --prefix="$PREFIX" \
        --target-list=i386-softmmu \
        --enable-kvm \
        --enable-sdl \
        --disable-sdl-image \
        --enable-slirp \
        --audio-drv-list=alsa \
        --disable-gtk \
        --disable-docs \
        --disable-werror)
    make -C "$build" -j"$JOBS"
    make -C "$build" install DESTDIR="$stage"

    local name
    name="qemu-retrobox-$QEMU_VERSION-$(revision)-linux-x86_64.tar.gz"
    tar -C "$stage$PREFIX" -czf "$OUT/$name" .
    log "host package: $OUT/$name"
}

# Kernel32 entry points absent from XP SP3; importing one makes the DLL fail
# to load in the guest. Not exhaustive, but catches toolchain regressions.
XP_MISSING_IMPORTS=(
    InitializeSRWLock AcquireSRWLockExclusive AcquireSRWLockShared
    ReleaseSRWLockExclusive ReleaseSRWLockShared InitializeConditionVariable
    SleepConditionVariableCS SleepConditionVariableSRW WakeConditionVariable
    WakeAllConditionVariable InitOnceExecuteOnce GetTickCount64
    CreateEventExW CreateMutexExW CreateSemaphoreExW FlsAlloc FlsGetValue
    FlsSetValue FlsFree GetLocaleInfoEx CompareStringEx LCMapStringEx
    GetFileInformationByHandleEx GetFinalPathNameByHandleW
    QueryFullProcessImageNameW CancelIoEx GetCurrentProcessorNumber
    GetSystemTimePreciseAsFileTime GetLogicalProcessorInformationEx
)

check_xp_imports() {
    local dir="$1" file imports name failed=0
    for file in "$dir"/*.dll "$dir"/*.exe; do
        imports="$("$MINGW-objdump" -p "$file" | awk '
            /DLL Name:/ { dll = $3; print dll; next }
            dll != "" && /^\t[0-9a-f]+[ \t]+[0-9]+[ \t]+[A-Za-z_]/ { print $3 }
            /^$/ { dll = "" }')"
        if grep -Eiq '^(api-ms-win-|ucrtbase)' <<<"$imports"; then
            echo "$(basename "$file") imports the Universal CRT" >&2
            failed=1
        fi
        for name in "${XP_MISSING_IMPORTS[@]}"; do
            if grep -qx "$name" <<<"$imports"; then
                echo "$(basename "$file") imports $name, missing on XP" >&2
                failed=1
            fi
        done
    done
    [ "$failed" = 0 ] || die "guest binaries are not XP compatible"
    log "XP import check passed"
}

build_guest() {
    mkdir -p "$WORK" "$OUT"

    # The wrapper Makefiles call plain `objdump` on PE files.
    local shim="$WORK/mingw-shim"
    mkdir -p "$shim"
    ln -sf "$(command -v "$MINGW-objdump")" "$shim/objdump"

    local kind dir
    for kind in 3dfx mesa; do
        log "building $kind guest wrappers"
        dir="$ROOT/wrappers/$kind/build"
        rm -rf "$dir"
        mkdir -p "$dir"
        (cd "$dir" && PATH="$shim:$PATH" bash ../../../scripts/conf_wrapper \
            && PATH="$shim:$PATH" make SHELL=/bin/bash \
            && PATH="$shim:$PATH" make SHELL=/bin/bash clean)
    done

    local iso_root="$WORK/xp-tools"
    rm -rf "$iso_root"
    mkdir -p "$iso_root/QEMU3DFX"
    # Glide is out of scope for RetroBox; only the MESA GL path ships.
    cp "$ROOT/wrappers/3dfx/build/"{fxptl.sys,instdrv.exe} \
        "$ROOT/wrappers/mesa/build/opengl32.dll" \
        "$iso_root/QEMU3DFX/"
    cp "$RB/INSTALL.TXT" "$iso_root/QEMU3DFX/"
    check_xp_imports "$iso_root/QEMU3DFX"

    local name
    name="retrobox-xp-tools-$(revision).iso"
    xorriso -as mkisofs -quiet -J -R -V RBXPTOOLS -o "$OUT/$name" "$iso_root"
    log "guest tools ISO: $OUT/$name"
}

target=all
for arg in "$@"; do
    case "$arg" in
        --install-deps) install_deps ;;
        host|guest|all) target="$arg" ;;
        *) die "usage: $0 [--install-deps] [host|guest|all]" ;;
    esac
done

case "$target" in
    host) build_host ;;
    guest) build_guest ;;
    all) build_host; build_guest ;;
esac
(cd "$OUT" && sha256sum -- *.tar.gz *.iso 2>/dev/null >SHA256SUMS || true)
log "done"
