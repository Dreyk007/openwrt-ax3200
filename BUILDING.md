### English · [Русский](BUILDING.ru.md)

# Building the Firmware

[← README](README.md)

The repository root contains the seed configuration [`ax3200.config`](ax3200.config) (generated with `./scripts/diffconfig.sh`) and the rootfs overlay [`files/`](files/).

## Automated Build with `build.sh`
[`build.sh`](build.sh) installs the build dependencies (optional, `apt`), updates the feeds, patches feed packages with `feeds-patches/<feed>/*.patch`, applies `ax3200.config`, synchronizes the kernel `vermagic` with the official repository or its mirrors (if no server answers, the list committed for this release is used; without one the build stops), compiles the firmware, checks the `factory.bin` layout and writes `sha256sums`.

Because of `CONFIG_ALL_KMODS=y` (see [README, section 7](README.md#7-official-package-repository-compatibility-vermagic--apk)) all ~1100 kernel module packages are built: the first build takes noticeably longer and `bin/` grows to ~140 MB, while the firmware contains only the selected modules. `kmod-rtl8812au-ct` is excluded because it does not build with GCC 15 (the AX6S has no USB port).

On a fresh Ubuntu 24.04 / 26.04 LTS or Debian system:
```bash
git clone -b xq-25.12 https://github.com/Dreyk007/openwrt-ax3200.git
cd openwrt-ax3200
./build.sh --install-deps
```
Subsequent builds:
```bash
./build.sh        # all CPU threads
./build.sh -j4    # custom number of parallel jobs
./build.sh --ccache   # compiler cache in .ccache: later builds only recompile what changed
```

## Build and Release with GitHub Actions
The workflow [`.github/workflows/build-ax3200.yml`](.github/workflows/build-ax3200.yml) runs `build.sh --install-deps` on a GitHub-hosted runner (Ubuntu 26.04 by default) and publishes the files of `bin/targets/mediatek/mt7622/` — the same images, `sha256sums` and buildinfo files as a local build — as a GitHub release. It only runs on demand: *Actions → Build AX3200 firmware → Run workflow*. Options:
* **Release tag** — empty for the next `v<OpenWrt version>-ax3200-r<N>`;
* **Publish as a pre-release**: routers do not offer pre-releases as updates;
* **Update from LuCI** — `auto`; `reset` if the release can only be installed without keeping the settings; `manual` if it has to be installed by hand (no update button). For `reset` and `manual` the notes (and optionally a link to the instructions) are shown on the router's update page;
* **Runner image** — `ubuntu-26.04`, or `ubuntu-24.04` as a fallback.

A full build takes about two hours on the 4-core runner; the source downloads (`dl/`) and the compiler cache (`.ccache`, `build.sh --ccache`) are kept between runs, so later builds are faster. If the build fails, its log is attached to the run as the `build-log` artifact.

**Verifying a download.** The workflow signs a build provenance attestation for every published file ([`actions/attest`](https://github.com/actions/attest), Sigstore): it ties the file's SHA256 to the workflow run and the commit it was built from, and it is recorded in a public transparency log, so it cannot be produced for a file that this workflow did not build. The releases are immutable, so their files and tags cannot be replaced after publication either. Check a downloaded image with the [GitHub CLI](https://cli.github.com/):
```bash
gh attestation verify openwrt-mediatek-mt7622-xiaomi_redmi-router-ax6s-squashfs-sysupgrade.itb --repo Dreyk007/openwrt-ax3200
gh release verify-asset <release tag> openwrt-mediatek-mt7622-xiaomi_redmi-router-ax6s-squashfs-sysupgrade.itb --repo Dreyk007/openwrt-ax3200
```

> The repository also carries OpenWrt's own CI workflows (`kernel.yml`, `packages.yml`, `toolchain.yml`, `github-release.yml`, …). They are meant for openwrt/openwrt: after enabling Actions in the fork, disable them (*Actions → workflow → ⋯ → Disable workflow*, or `gh workflow disable <file>`), otherwise pushes and `v*` tags trigger them.

## Manual Build
```bash
# 1. Update and install package feeds
./scripts/feeds update -a
./scripts/feeds install -a

# 2. Load the AX3200 seed configuration and expand all dependencies
cp ax3200.config .config
make defconfig

# 3. Fetch the official kernel vermagic (required after switching to a new 25.12.x release)
./vermagic_update.sh mediatek mt7622

# 4. Download sources and compile
make download -j$(nproc)
make -j$(nproc)
```

> **Note:** unlike the Linux kernel, `make defconfig` in OpenWrt does **not** reset `.config` to defaults — it expands the short seed copied to `.config` with all dependent symbols.

## Changing the Configuration
Edit the configuration with `make menuconfig` and save the result back as a seed — do not edit `ax3200.config` by hand. Keep `CONFIG_ALL_KMODS=y` and `# CONFIG_KERNEL_KALLSYMS is not set`: they are required for official kmod compatibility.
```bash
cp ax3200.config .config && make defconfig
make menuconfig
./scripts/diffconfig.sh > ax3200.config
```

## Updating to a New OpenWrt Release
[UPGRADING.md](UPGRADING.md) describes in detail how to merge a new minor release (e.g. 25.12.7) into this branch and how to port the build to a new major release, including the vermagic update, the kernel configuration parity check against the official SDK and the on-device verification.
