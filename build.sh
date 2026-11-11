#!/usr/bin/env bash
#
# Automated build script for Xiaomi AX3200 / Redmi AX6S OpenWrt firmware
# (MediaTek MT7622, aarch64_cortex-a53, GCC 15.3, musl libc)
#

set -euo pipefail

# Text colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info() { echo -e "${BLUE}${BOLD}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}${BOLD}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}${BOLD}[WARNING]${NC} $*"; }
error() { echo -e "${RED}${BOLD}[ERROR]${NC} $*"; }

# Ensure we run from the repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

INSTALL_DEPS=0
CCACHE=0
JOBS="$(nproc)"

# Parse optional arguments
for arg in "$@"; do
    case "$arg" in
        --install-deps|-i)
            INSTALL_DEPS=1
            ;;
        --ccache)
            CCACHE=1
            ;;
        -j*)
            JOBS="${arg#-j}"
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -i, --install-deps    Install required build dependencies via apt"
            echo "      --ccache          Keep a compiler cache in .ccache, so that later builds only recompile what changed"
            echo "  -j<N>                 Number of parallel compilation jobs (default: $(nproc))"
            echo "  -h, --help            Show this help message"
            exit 0
            ;;
        *)
            warn "Unknown option: $arg"
            ;;
    esac
done

echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD} OpenWrt Firmware Build System — Xiaomi AX3200 / Redmi AX6S   ${NC}"
echo -e "${BOLD} Target: MediaTek MT7622 (ARM64 Cortex-A53)                   ${NC}"
echo -e "${BOLD}================================================================${NC}"

# 1. Install dependencies if requested or if essential build tools are missing
DEPS_PACKAGES=(
    build-essential
    ca-certificates
    clang
    llvm
    flex
    bison
    g++
    gawk
    gcc-multilib
    g++-multilib
    gettext
    git
    libncurses-dev
    libssl-dev
    python3
    python3-dev
    python3-setuptools
    python3-pyelftools
    python3-cryptography
    rsync
    sudo
    swig
    unzip
    zlib1g-dev
    file
    wget
    curl
    time
)

if [ "$INSTALL_DEPS" -eq 1 ]; then
    info "Installing build dependencies via apt..."
    if [ "$(id -u)" -eq 0 ]; then
        apt-get update && apt-get install -y "${DEPS_PACKAGES[@]}"
    elif command -v sudo >/dev/null 2>&1; then
        sudo apt-get update && sudo apt-get install -y "${DEPS_PACKAGES[@]}"
    else
        error "Root or sudo privilege is required to install dependencies."
        exit 1
    fi
    success "Dependencies successfully installed."
else
    # Quick sanity check for essential tools
    MISSING_TOOLS=()
    for tool in gcc g++ make gawk bison flex git rsync swig clang llc; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            MISSING_TOOLS+=("$tool")
        fi
    done
    if [ "${#MISSING_TOOLS[@]}" -gt 0 ]; then
        warn "Missing essential tools: ${MISSING_TOOLS[*]}"
        warn "Run '$0 --install-deps' to install all build prerequisites."
    fi
fi

# Ensure FORCE_UNSAFE_CONFIGURE is exported if running as root
if [ "$(id -u)" -eq 0 ]; then
    warn "Running build as root is not recommended by OpenWrt. Setting FORCE_UNSAFE_CONFIGURE=1."
    export FORCE_UNSAFE_CONFIGURE=1
fi

# 2. Update and install package feeds
info "Updating and installing OpenWrt package feeds..."
./scripts/feeds update -a

# Fixes for feed packages: feeds-patches/<feed>/*.patch, applied in name order. A pinned feed is
# not updated once cloned, so first restore the files the patches touch. A patch that does not
# apply, e.g. because the feed already has it, stops the build.
for feed_patches in feeds-patches/*/; do
    [ -d "$feed_patches" ] || continue
    feed_dir="feeds/$(basename "$feed_patches")"
    for patch in "$feed_patches"*.patch; do
        git -C "$feed_dir" apply --numstat "$PWD/$patch" | cut -f3 | xargs -r git -C "$feed_dir" checkout -q --
    done
    for patch in "$feed_patches"*.patch; do
        if ! git -C "$feed_dir" apply "$PWD/$patch"; then
            error "Feed patch $patch does not apply to $feed_dir."
            exit 1
        fi
        info "Applied feed patch $patch"
    done
done

./scripts/feeds install -a
success "Feeds updated and installed."

# 3. Apply target configuration
CONFIG_SEED="ax3200.config"
if [ ! -f "$CONFIG_SEED" ]; then
    error "Configuration seed '$CONFIG_SEED' not found in $(pwd)!"
    exit 1
fi

info "Applying configuration from $CONFIG_SEED..."
cp "$CONFIG_SEED" .config
# The compiler cache is a build option and does not change the firmware; the seed leaves it off
if [ "$CCACHE" = 1 ]; then
    echo "CONFIG_CCACHE=y" >> .config
    info "Compiler cache enabled (.ccache)"
fi
make defconfig
success "Configuration applied successfully."

# 4. Synchronize kernel vermagic with official OpenWrt repository.
# Without a valid vermagic list the firmware silently gets its own vermagic and
# official kmod-* packages can no longer be installed, so a missing list is fatal.
# vermagic_update.sh tries the official mirrors too, and exits with 2 when no
# server answered but the committed list already holds the current kernel.
info "Synchronizing kernel vermagic with official OpenWrt repository (mediatek mt7622)..."
vermagic_rc=0
./vermagic_update.sh mediatek mt7622 || vermagic_rc=$?
case "$vermagic_rc" in
    0)
        success "Kernel vermagic synchronized with official repository."
        ;;
    2)
        warn "The official repository and its mirrors did not answer; using the committed vermagic list of this release."
        ;;
    *)
        error "Cannot synchronize kernel vermagic with the official repository."
        error "Check network access to downloads.openwrt.org and re-run the build."
        exit 1
        ;;
esac

# 5. Pre-download source packages
info "Pre-downloading package sources using $JOBS parallel jobs..."
make download -j"$JOBS"
success "Source downloads complete."

# 6. Compile firmware
# The release of this image and the GitHub repository that publishes it, for the firmware update
# check (luci-app-fwupdate): the GitHub workflow passes both (AX3200_RELEASE, AX3200_REPO); a local
# build has no release and takes the repository from the origin remote.
COMMIT=$(git rev-parse HEAD 2>/dev/null || echo unknown)
git diff --quiet HEAD 2>/dev/null || COMMIT="$COMMIT-dirty"
REPO=${AX3200_REPO:-$(git remote get-url origin 2>/dev/null | sed -nE 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+/[^/]+)$#\2#p' | sed 's/\.git$//' || true)}
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || REPO=""
printf "RELEASE='%s'\nREPO='%s'\nCOMMIT='%s'\n" "${AX3200_RELEASE:-}" "$REPO" "$COMMIT" > files/etc/ax3200_release
info "Release: ${AX3200_RELEASE:-none (local build)}, repository ${REPO:-unknown}, commit $COMMIT"

# Timestamp of the files in the image: the date of this fork's last commit. Otherwise the
# release tag's version.date gives every build of a release the same one, and with it the
# same ?v= that LuCI appends to its scripts and styles (the mtime of /lib/apk/db/installed),
# so a browser can keep using the cached files of another build. A tree with uncommitted
# changes takes the time of the build instead: its builds differ from each other and from
# that commit. It is also the clock a router starts with after a factory reset, until NTP
# sets it.
SDE_ARGS=()
if SDE=$(git log -1 --no-show-signature --format=%ct 2>/dev/null) && [ -n "$SDE" ]; then
    SDE_FROM="the last commit"
    if ! git diff --quiet HEAD 2>/dev/null; then
        SDE=$(date +%s)
        SDE_FROM="the build, the tree has uncommitted changes"
    fi
    SDE_ARGS=("SOURCE_DATE_EPOCH=$SDE")
    info "SOURCE_DATE_EPOCH=$SDE ($(date -u -d "@$SDE" '+%F %T') UTC, $SDE_FROM)"
fi
info "Starting multi-threaded firmware compilation (-j$JOBS)..."
if ! make -j"$JOBS" "${SDE_ARGS[@]}"; then
    warn "Multi-threaded build failed. Retrying in single-thread debug mode (V=s)..."
    make -j1 V=s "${SDE_ARGS[@]}"
fi
success "Firmware compilation finished successfully."

# Hits and misses of this build; the counters are reset afterwards, so that the next build
# (also on GitHub Actions, which keeps .ccache between runs) shows its own
if [ "$CCACHE" = 1 ] && [ -x staging_dir/host/bin/ccache ]; then
    info "Compiler cache of this build:"
    CCACHE_DIR="$SCRIPT_DIR/.ccache" staging_dir/host/bin/ccache --show-stats || true
    CCACHE_DIR="$SCRIPT_DIR/.ccache" staging_dir/host/bin/ccache --zero-stats > /dev/null || true
fi

# 7. Check the factory.bin layout and write sha256sums
TARGET_DIR="bin/targets/mediatek/mt7622"
if [ ! -d "$TARGET_DIR" ]; then
    error "Target build directory '$TARGET_DIR' not found!"
    exit 1
fi

FACTORY_BIN="$(find "$TARGET_DIR" -name "openwrt-*-factory.bin" | head -n 1)"

if [ -n "$FACTORY_BIN" ] && [ -f "$FACTORY_BIN" ]; then
    # factory.bin = ubi-loader FIT padded to 512 KiB (size of the "ubi-loader"
    # partition) + UBI image, see Device/xiaomi_redmi-router-ax6s in mt7622.mk.
    # The README's upgrade from 23.05 (dd count=4 / skip=4 into the old 4 MiB
    # "kernel" partition and "ubi") relies on this layout.
    if [ "$(dd if="$FACTORY_BIN" bs=1 skip=524288 count=4 status=none)" != "UBI#" ]; then
        error "No UBI image at offset 512KB in $FACTORY_BIN (factory.bin layout changed?)"
        exit 1
    fi
else
    warn "factory.bin not found; skipping the factory.bin layout check."
fi

# Generate and verify sha256sums
info "Generating and validating sha256sums in $TARGET_DIR..."
(
    cd "$TARGET_DIR"
    # Select all standard build artifacts
    FILES_TO_HASH=()
    for f in config.buildinfo feeds.buildinfo mt7622-ram-*.bin openwrt-*-factory.bin openwrt-*-recovery.itb openwrt-*-sysupgrade.itb openwrt-*-ubi-loader.itb openwrt-*.manifest profiles.json version.buildinfo; do
        if [ -f "$f" ]; then
            FILES_TO_HASH+=("$f")
        fi
    done
    sha256sum -b "${FILES_TO_HASH[@]}" > sha256sums
    sha256sum -c sha256sums
)
success "sha256sums generated and verified."

# 8. Print build summary
echo ""
echo -e "${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD} Build Completed Successfully!                                 ${NC}"
echo -e "${BOLD} Artifacts location: ${TARGET_DIR}                             ${NC}"
echo -e "${BOLD}================================================================${NC}"
ls -lh "$TARGET_DIR"/openwrt-* "$TARGET_DIR"/sha256sums
echo ""
