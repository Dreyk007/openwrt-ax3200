![OpenWrt logo](include/logo.png)

### English · [Русский](README.ru.md)

# OpenWrt 25.12.6 — Optimized Custom Build for Xiaomi AX3200 / Redmi AX6S

[![Download the latest release](https://img.shields.io/github/v/release/Dreyk007/openwrt-ax3200?style=for-the-badge&label=Download&color=2ea44f)](https://github.com/Dreyk007/openwrt-ax3200/releases/latest) [![Installation](https://img.shields.io/badge/Installation-0969da?style=for-the-badge)](#installation)

**Which file to download:**
* **first installation** from the stock firmware: the file ending in `factory.bin`;
* **upgrade** from OpenWrt 24.10 / 25.12: the file ending in `squashfs-sysupgrade.itb`.

Other cases (OpenWrt 23.05 or older, back to the stock firmware) are described in [Installation](#installation).

This repository (branch **`xq-25.12`**) is a fork of the stable **OpenWrt 25.12.6** release (`Linux 6.12.112`) tailored for the **Xiaomi Router AX3200 (RB01) / Redmi Router AX6S (RB03)** built on the **MediaTek MT7622B + MT7531BE + MT7915E** platform (it also carries the MediaTek changes from the `remittor` tree).

The goal of the build is **line-rate 1 Gbps wired and Wi-Fi 6 throughput, low latency, U-Boot NVRAM anti-brick protection and a complete out-of-the-box home router feature set**, while staying compatible with the official OpenWrt package repository.

> [!WARNING]
> Wi-Fi is **enabled on first boot with the public default password `12345678`** and the web interface has **no root password**. Set both right after flashing (LuCI → *System → Administration* and *Network → Wireless*).

**Contents:** [Highlights](#highlights) · [Installation](#installation) · [Key changes](#key-changes) · [Operating modes](#operating-modes) · [Firmware updates](#firmware-updates) · [SQM or hardware offloading?](#sqm-or-hardware-offloading) · [Wi-Fi 160 MHz and VR](#wi-fi-at-160-mhz-he160-and-vr-streaming) · [Pre-installed packages](#pre-installed-packages) · [Building](BUILDING.md) · [Updating to a new release](UPGRADING.md) · [Research and measurements](RESEARCH.md)

---

## Highlights
* **Line-rate routing with almost no CPU load:** hardware NAT (PPE) and Wi-Fi offloading (WED) are enabled by default, and kernel fixes keep the per-client traffic statistics and the interface graphs correct with them ([section 2](#2-hardware-nat-and-wi-fi-6-acceleration-hfo--wed)). SQM (CAKE) is pre-installed for slower links with bufferbloat ([SQM or hardware offloading?](#sqm-or-hardware-offloading)).
* **Measured for PC VR streaming:** a wired PC reaches a 2×2 HE160 client at 1.25–1.35 Gbit/s, and a 200 Mbit/s VR-like stream gets a 1.7 ms median ping ([Wi-Fi 160 MHz and VR](#wi-fi-at-160-mhz-he160-and-vr-streaming)).
* **Operating modes in LuCI:** one page, *System → Operating mode*, switches between setups measured on this router: balanced (default), maximum wired → Wi-Fi throughput with `bridger`, low latency for VR and gaming over Wi-Fi, and SQM for slow links ([Operating modes](#operating-modes)).
* **More stable Wi-Fi:** 18 driver fixes from mt76 master (kernel crashes around client connects and radio firmware recovery, adaptive 2.4 GHz sensitivity), defaults tuned for both radios and optional 160 MHz on 5 GHz ([section 4](#4-wi-fi-defaults-77_wireless), [HE160](#wi-fi-at-160-mhz-he160-and-vr-streaming)).
* **No "6 reboots → orange LED" soft-brick:** the U-Boot boot flags are checked on every boot ([section 3](#3-nvram-anti-brick-protection-6-reboots--orange-led-fix)).
* **Official packages work:** the kernel is built like the official one, so `kmod-*` packages from the official repository install and load ([section 7](#7-official-package-repository-compatibility-vermagic--apk)).
* **Tuned for the Cortex-A53:** GCC 15, `-O2` with the ARMv8 Crypto and CRC32 instructions, LTO, the `schedutil` frequency governor ([section 1](#1-compiler-and-cpu-arm-cortex-a53)).
* **Updates from the web interface:** the router looks for new releases of this build by itself, shows a notice on the Overview page and installs an update with one button ([Firmware updates](#firmware-updates)).
* **Ready to use:** LuCI in English and Russian with the Footstrap theme, encrypted DNS (DoH), SQM, UPnP, DDNS, Wake-on-LAN, per-client traffic accounting, statistics graphs and a web terminal ([Pre-installed packages](#pre-installed-packages)).
* **Your settings survive upgrades:** the build's defaults are applied once per configuration, not on every flash ([section 6](#6-how-the-defaults-are-applied-99-custom-settings)).
* **Verifiable releases:** built by GitHub Actions from this repository, with a signed build provenance for every file ([Build and release with GitHub Actions](BUILDING.md#build-and-release-with-github-actions)).

---

## Installation

> [!IMPORTANT]
> Read the [OpenWrt wiki page for the Xiaomi AX3200 / Redmi AX6S](https://openwrt.org/toh/xiaomi/ax3200) first. It covers **backing up the flash partitions**, **TFTP and UART recovery** and hardware-revision specific issues that are not repeated here. Flashing third-party firmware is at your own risk.

**Known risks (from the wiki):**
* Some newer units have MTD partitions shifted by `-0x20000` and can brick on sysupgrade; on others even the factory image may fail. AX3200 units produced **after 12/2023** with telnet disabled are reported to be affected. Before the first sysupgrade of a unit installed from `factory.bin`, run the checks from the wiki ("Known Issue #1"): `hexdump /dev/mtd8 | head` must start with `0000000 0dd0 edfe`, and `fw_printenv | grep -e ^flag_try -e ^boot_fw` must show `boot_fw1=run boot_rd_img;bootm`.
* The "6 reboots → orange LED" soft-brick is prevented by this build's `bootcount` once OpenWrt has booted (see [section 3](#3-nvram-anti-brick-protection-6-reboots--orange-led-fix)).

**Fallback:** going back to the stock firmware and installing this build from there works from any state, even when OpenWrt no longer boots; see [section F](#f-back-to-the-stock-firmware-then-xmir-patcher-fallback).

### Firmware Images
Download the images from the [latest release](https://github.com/Dreyk007/openwrt-ax3200/releases/latest) (a local build puts them into `bin/targets/mediatek/mt7622/`):
| File | Purpose |
|---|---|
| `openwrt-mediatek-mt7622-xiaomi_redmi-router-ax6s-factory.bin` | First installation from the stock firmware (or from OpenWrt ≤ 23.05). Contains `ubi-loader` padded to 512 KiB followed by the UBI image. |
| `openwrt-mediatek-mt7622-xiaomi_redmi-router-ax6s-squashfs-sysupgrade.itb` | Regular upgrade from OpenWrt 24.10 / 25.12 (UBI layout). |
| `openwrt-mediatek-mt7622-xiaomi_redmi-router-ax6s-sysupgrade.ubi` | Raw UBI image extracted from `factory.bin` by `build.sh`, for older builds that reject the `.itb` (see below). |
| `openwrt-mediatek-mt7622-xiaomi_redmi-router-ax6s-ubi-loader.itb` | Second-stage U-Boot (`ubi-loader`) alone. |
| `openwrt-mediatek-mt7622-xiaomi_redmi-router-ax6s-initramfs-recovery.itb` | Initramfs recovery image (TFTP). |

**Getting an image onto the router.** Sections B–E put an image into `/tmp` on the router in one of two ways:
* **Download it on the router**, if the router has internet access: the links `https://github.com/Dreyk007/openwrt-ax3200/releases/latest/download/<file>` always point to the latest release, and `sha256sums` from the same place checks the download. The commands are in each section.
* **Copy it from your computer:** download the file from the [latest release](https://github.com/Dreyk007/openwrt-ax3200/releases/latest) and copy it with `scp`, which is built into Linux, macOS and Windows 10/11 (on Windows you can also use WinSCP with the SCP protocol). The `-O` option is needed because OpenWrt has no SFTP server.

Commands on the router are run over SSH: `ssh root@192.168.1.1` (built into Linux, macOS and Windows 10/11), or [PuTTY](https://www.chiark.greenend.org.uk/~sgtatham/putty/) on Windows with host `192.168.1.1` and user `root`. The password is the root password set in LuCI; right after flashing there is none. If your router is not at `192.168.1.1`, use its address instead.

### A. From the Stock Firmware with XMiR-Patcher (recommended)
[XMiR-Patcher](https://github.com/openwrt-xiaomi/xmir-patcher) uses a vulnerability in the stock web interface to get SSH access and flashes the firmware for you. It works on Windows, Linux and macOS.

1. Finish the initial setup of the stock firmware (the web interface password is required) and connect your PC to a **LAN** port of the router. The stock firmware is at `192.168.31.1`.
2. Download XMiR-Patcher (*Code → Download ZIP*) and unpack it.
3. Start it: **Windows** — `run.bat`; **Linux/macOS** — install Python 3.8+ and `openssl`, then `./run.sh`.
4. If the router is not at `192.168.31.1`, choose `1 - Set IP-address`.
5. Choose **`2 - Connect to device (install exploit)`** and enter the web interface password when asked.
6. Choose **`4 - Create full backup`**. The dumps of all flash partitions are saved to the `backups/` folder of XMiR-Patcher — **keep them safe**: they contain the factory calibration data unique to your unit and are needed to return to stock or recover from a brick.
7. Download `openwrt-mediatek-mt7622-xiaomi_redmi-router-ax6s-factory.bin` from the [latest release](https://github.com/Dreyk007/openwrt-ax3200/releases/latest) and copy **only** this file into the `firmware/` folder of XMiR-Patcher (no other images in that folder).
8. Choose **`7 - Install firmware (from directory "firmware")`** and wait until the router reboots.
9. Open `http://192.168.1.1` (user `root`, no password), set a root password and change the Wi-Fi password.

If the exploit does not work with your stock firmware version, see the wiki for the alternatives (stock firmware with telnet, `netmode 4` methods, UART).

### B. Upgrade from OpenWrt 24.10 / 25.12
The settings are kept. From r10 on the router can do this by itself: *System → AX3200 / AX6S build updates* ([Firmware updates](#firmware-updates)).

1. Download `openwrt-mediatek-mt7622-xiaomi_redmi-router-ax6s-squashfs-sysupgrade.itb` from the [latest release](https://github.com/Dreyk007/openwrt-ax3200/releases/latest).
2. In LuCI open *System → Backup / Flash Firmware*, click *Flash image...* under *Flash new firmware image*, choose the file and click *Upload*.
3. Leave *Keep settings and retain the current configuration* checked and click *Continue*. The router writes the image and reboots, which takes a few minutes; do not power it off meanwhile.

Over SSH instead: log in with `ssh root@192.168.1.1`, download the image on the router and check it (the last command must print `OK`), then flash it:
```sh
cd /tmp
F=openwrt-mediatek-mt7622-xiaomi_redmi-router-ax6s-squashfs-sysupgrade.itb
wget -O $F https://github.com/Dreyk007/openwrt-ax3200/releases/latest/download/$F
wget -qO- https://github.com/Dreyk007/openwrt-ax3200/releases/latest/download/sha256sums | grep -- $F | sha256sum -c -
```
```sh
sysupgrade /tmp/openwrt-mediatek-mt7622-xiaomi_redmi-router-ax6s-squashfs-sysupgrade.itb
```

### C. Upgrade from OpenWrt 23.05 or Older (old flash layout)
Since 24.10 this router has a different flash layout: a second-stage bootloader (`ubi-loader`) followed by one UBI partition with the system. `sysupgrade` of OpenWrt 23.05 and older cannot switch to it, so the image is written once by hand with `mtd`. **All settings are reset.** These are the steps of method 1 from the [OpenWrt wiki](https://openwrt.org/toh/xiaomi/ax3200#upgrading_from_2305_and_earlier_to_upcoming_2410_or_snapshot) (section *Upgrading from 23.05 and earlier to upcoming 24.10 or snapshot*), which also describes a method over TFTP. Another way: back to stock, then XMiR-Patcher ([section F](#f-back-to-the-stock-firmware-then-xmir-patcher-fallback)).

1. Back up your settings: LuCI → *System → Backup / Flash Firmware* → *Generate archive*.
2. Put the image into `/tmp` on the router. If the router has internet access, log in with `ssh root@192.168.1.1` and download it there (the last command must print `OK`):
   ```sh
   cd /tmp
   F=openwrt-mediatek-mt7622-xiaomi_redmi-router-ax6s-factory.bin
   wget -O $F https://github.com/Dreyk007/openwrt-ax3200/releases/latest/download/$F
   wget -qO- https://github.com/Dreyk007/openwrt-ax3200/releases/latest/download/sha256sums | grep -- $F | sha256sum -c -
   ```
   Otherwise download the file from the [latest release](https://github.com/Dreyk007/openwrt-ax3200/releases/latest), connect your computer to a LAN port with a cable and copy the file:
   ```sh
   scp -O openwrt-mediatek-mt7622-xiaomi_redmi-router-ax6s-factory.bin root@192.168.1.1:/tmp/
   ```
3. Log in with `ssh root@192.168.1.1` (unless you are logged in already) and run:
   ```sh
   mount -o remount,ro /
   mount -o remount,ro /overlay
   cd /tmp
   F=openwrt-mediatek-mt7622-xiaomi_redmi-router-ax6s-factory.bin
   dd if=$F bs=1M count=4 | mtd write - kernel
   dd if=$F bs=1M skip=4 | mtd -r write - ubi
   ```
   If the first command reports `Resource busy`, ignore it. The router reboots after the last command.
4. Open `http://192.168.1.1` (user `root`, no password). Set a root password and the Wi-Fi password, or restore the archive from step 1: *System → Backup / Flash Firmware* → *Upload archive...*.
5. If you restored the archive, run this over SSH, otherwise the next upgrades (section B) are refused:
   ```sh
   uci set system.@system[0].compat_version="2.0"
   uci commit system
   ```
   The restored settings replace the defaults of this build (HFO, packet steering and others); to apply them on top, see [section 6](#6-how-the-defaults-are-applied-99-custom-settings).

### D. Older Builds That Reject the `.itb` Image
Some older third-party 24.10 builds (already with the new flash layout) refuse `openwrt-mediatek-mt7622-xiaomi_redmi-router-ax6s-squashfs-sysupgrade.itb` with `Cannot find ubinized rootfs in the factory FIT-image`. Flash the raw UBI image instead. **The settings are not kept.**

1. Back up your settings: LuCI → *System → Backup / Flash Firmware* → *Generate archive*.
2. Put the image into `/tmp` on the router. If the router has internet access, log in with `ssh root@192.168.1.1` and download it there (the last command must print `OK`):
   ```sh
   cd /tmp
   F=openwrt-mediatek-mt7622-xiaomi_redmi-router-ax6s-sysupgrade.ubi
   wget -O $F https://github.com/Dreyk007/openwrt-ax3200/releases/latest/download/$F
   wget -qO- https://github.com/Dreyk007/openwrt-ax3200/releases/latest/download/sha256sums | grep -- $F | sha256sum -c -
   ```
   Otherwise download the file from the [latest release](https://github.com/Dreyk007/openwrt-ax3200/releases/latest) and copy it:
   ```sh
   scp -O openwrt-mediatek-mt7622-xiaomi_redmi-router-ax6s-sysupgrade.ubi root@192.168.1.1:/tmp/
   ```
3. Log in with `ssh root@192.168.1.1` (unless you are logged in already) and run:
   ```sh
   sysupgrade -n /tmp/openwrt-mediatek-mt7622-xiaomi_redmi-router-ax6s-sysupgrade.ubi
   ```
4. After the reboot open `http://192.168.1.1` (user `root`, no password) and set the passwords, or restore the archive from step 1 (*Upload archive...*).

### E. Updating `ubi-loader` (optional)
`sysupgrade` does not touch the `ubi-loader` partition: the router keeps the version that came with `factory.bin`. To update it to the version from this build:

1. Put the image into `/tmp` on the router. If the router has internet access, log in with `ssh root@192.168.1.1` and download it there (the last command must print `OK`):
   ```sh
   cd /tmp
   F=openwrt-mediatek-mt7622-xiaomi_redmi-router-ax6s-ubi-loader.itb
   wget -O $F https://github.com/Dreyk007/openwrt-ax3200/releases/latest/download/$F
   wget -qO- https://github.com/Dreyk007/openwrt-ax3200/releases/latest/download/sha256sums | grep -- $F | sha256sum -c -
   ```
   Otherwise download the file from the [latest release](https://github.com/Dreyk007/openwrt-ax3200/releases/latest) and copy it:
   ```sh
   scp -O openwrt-mediatek-mt7622-xiaomi_redmi-router-ax6s-ubi-loader.itb root@192.168.1.1:/tmp/
   ```
2. Log in with `ssh root@192.168.1.1` (unless you are logged in already) and run (do not power the router off while it writes):
   ```sh
   mtd write /tmp/openwrt-mediatek-mt7622-xiaomi_redmi-router-ax6s-ubi-loader.itb ubi-loader
   reboot
   ```

### F. Back to the Stock Firmware, Then XMiR-Patcher (fallback)
The stock bootloader has a recovery mode that installs the stock firmware from a computer over the network (TFTP). It works from any state, even when OpenWrt no longer boots, as long as the bootloader itself is intact. It is also often the simplest way from an old or a third-party build to this one: back to stock, then [section A](#a-from-the-stock-firmware-with-xmir-patcher-recommended). **All settings are reset**; if the router still works, back them up first (LuCI → *System → Backup / Flash Firmware* → *Generate archive*).

1. Download the stock firmware of your model (the router rejects the firmware of the other one):
   * **Xiaomi AX3200 (RB01):** [`miwifi_rb01_firmware_bbc77_1.0.71_INT.bin`](http://cdn.awsde0-fusion.fds.api.mi-img.com/xiaoqiang/rom/rb01/miwifi_rb01_firmware_bbc77_1.0.71_INT.bin) from Xiaomi's server;
   * **Redmi AX6S (RB03):** from [Xiaomi's download page](http://www1.miwifi.com/miwifi_download.html), or version 1.2.7, which the OpenWrt wiki recommends ([mirror](https://github.com/AoThen/AX6S-unlock/raw/master/miwifi_rb03_firmware_stable_1.2.7.bin)).
2. Connect your computer to a LAN port of the router with a cable and start a DHCP and TFTP server on it:
   * **Windows:** Xiaomi's official [MiWiFi Repair Tool](http://bigota.miwifi.com/xiaoqiang/tools/MIWIFIRepairTool.x86.zip) does this for you: choose the firmware file and the network adapter connected to the router.
   * **Manually** (Linux, or [Tftpd64](https://pjo2.github.io/tftpd64/) on Windows with the same settings): give the computer the static address `192.168.31.100` with the netmask `255.255.255.0`, rename the firmware to `C0A81F02.img` and serve its folder, handing out the single address `192.168.31.2` (the router asks for a file named after its address in hex):
     ```sh
     sudo dnsmasq -i <interface> -p 0 -d -z --enable-tftp --tftp-root <folder> --tftp-no-fail --dhcp-range 192.168.31.2,192.168.31.2,255.255.255.0,12h
     ```
3. Unplug the router's power, hold the reset button and plug the power back in. When the orange LED blinks quickly (after about 10 seconds), release the button: the router downloads the firmware and installs it.
4. When the LED blinks blue quickly, the stock firmware is installed: unplug the power and plug it back in. A purple blink means that the firmware was rejected (a wrong file or the other model's firmware); start again from step 3.
5. Install this build as described in [section A](#a-from-the-stock-firmware-with-xmir-patcher-recommended), starting with the initial setup of the stock firmware.

### Backup and Recovery
Backing up the flash partitions, TFTP recovery and UART access are described on the [OpenWrt wiki page](https://openwrt.org/toh/xiaomi/ax3200).

---

## Key Changes

The files of every change are listed in [UPGRADING.md](UPGRADING.md#12-this-builds-commits).

### 1. Compiler and CPU (`ARM Cortex-A53`)
* **OpenWrt GCC 15.3.0 toolchain** (`CONFIG_GCC_USE_VERSION_15=y`) instead of the default GCC 14.3, with better instruction scheduling for the in-order Cortex-A53 pipeline (~241 KB smaller compressed SquashFS).
* **Compiler flags `-O2 -pipe -mcpu=cortex-a53+crypto+crc`:** upstream builds use `-Os`, which disables function/loop/jump alignment. The AX3200 has 128 MB of NAND, so this build trades size for speed with `-O2` and enables the ARMv8 **Crypto Extensions (AES, SHA1/SHA2, GHASH)** and **CRC32** instructions.
* **Link-Time Optimization** (`CONFIG_USE_LTO=y`) and **dead code/data elimination** (`CONFIG_USE_GC_SECTIONS=y`) for userland packages.
* **`FORTIFY_SOURCE=2`** (`CONFIG_PKG_FORTIFY_SOURCE_2=y`) instead of the default level 1. The other hardening options (stack protector for userland and kernel, full RELRO, PIE) and `sstrip -z` binary stripping are OpenWrt defaults and are kept as is.
* **`schedutil` CPU frequency governor** by default (`target/linux/mediatek/mt7622/config-6.12`) instead of `ondemand`. `ondemand` samples the load periodically and ramps up the clock (437.5 MHz → 1.35 GHz) with a delay on traffic bursts; `schedutil` scales the frequency directly from the scheduler. Measured on the device at idle: 3.8 % CPU load with `schedutil` vs 6.0 % with `ondemand`.
* **`performance` governor (optional)** keeps the CPU at 1.35 GHz all the time: it needs 28 % less CPU per Gbit/s for Wi-Fi → LAN bridging and lowers the idle Wi-Fi round-trip time by about 0.2 ms, but the throughput (limited by Wi-Fi) and the latency under load stay the same, and the router runs about 2 °C warmer. `schedutil` therefore stays the default. The *Maximum throughput*, *Low latency* and *SQM* operating modes use `performance`, and it can be set alone under *Advanced* on the same page ([Operating modes](#operating-modes)); the choice is kept across upgrades. Details: [RESEARCH.md](RESEARCH.md#5-cpu-frequency-governor).

### 2. Hardware NAT and Wi-Fi 6 Acceleration (HFO + WED)
* **Hardware Flow Offloading (PPE):** the MediaTek **Packet Processing Engine** (`kmod-nft-offload`, `flow_offloading='1'`, `flow_offloading_hw='1'`) handles routing and NAT of established flows in hardware at line rate with almost no CPU load.
* **Wireless Ethernet Dispatch** (`files/etc/modules.conf`: `options mt7915e wed_enable=Y`): offloaded WAN traffic is forwarded by the PPE directly into the DMA rings of the **MT7915E (5 GHz Wi-Fi 6)** radio, bypassing the CPU. The MT7622 has no WED RX, so only WAN → Wi-Fi traffic bypasses the CPU this way; Wi-Fi → WAN traffic is forwarded by the CPU through the software flow offload path.
* **Wired → Wi-Fi in hardware (`bridger`, off by default):** traffic between the LAN ports and Wi-Fi clients is bridged, not routed, so HFO does not cover it and the CPU forwards it: up to ~1.2–1.3 Gbit/s to a 5 GHz client, with one core at its limit. `bridger` can install a hardware rule for each pair of hosts that exchange traffic, so that the PPE and WED forward wired → 5 GHz traffic past the CPU: the same ~1.3 Gbit/s (the radio link is the limit) at ~8 % CPU instead of ~70 %. It is off by default: like WED for WAN traffic, the hardware path bypasses the airtime scheduling and the queues of mac80211, so the latency is higher (a 200 Mbit/s stream: median ping 3.0–3.7 ms instead of 1.7 ms) and several busy clients share the air less fairly (three clients: 580–630 Mbit/s in total instead of 790–810, one of them nearly starved). The *Maximum throughput* operating mode enables it, for bulk transfers to a single busy client ([Operating modes](#operating-modes)). Details: [RESEARCH.md](RESEARCH.md#11-wi-fi--lan-throughput-and-bridger).
* **Without WED (optional):** with WED off, all traffic to Wi-Fi clients goes through the airtime scheduling of mac80211. In household tests (a TV streaming 4K, a gamer on Wi-Fi pinging at 50/s, a VR-like stream) it made no difference; only while another Wi-Fi client downloaded at full speed was the gamer's p99 ping lower: ~27 ms instead of ~30 ms, at 6–9 points more CPU. On a gigabit plan the CPU may then limit the Wi-Fi speed. WED is off in the *Low latency* operating mode ([Operating modes](#operating-modes)). Details: [RESEARCH.md](RESEARCH.md#12-several-wi-fi-clients-latency-and-wed).
* **Correct traffic statistics with offloading:** offloaded traffic bypasses the CPU, and the per-client statistics (`nlbwmon`) used to miss part of it or jump by ~4 GB, e.g. for connections that close right after a transfer, after a firewall reload or for Wi-Fi downloads. Kernel fixes make them match the real traffic. Details and measurements: [RESEARCH.md](RESEARCH.md#3-traffic-accounting-with-hardware-offloading).
* **Interface graphs with offloading:** the statistics of `wan` and `lan1`–`lan3` (graphs in *Statistics*, LuCI realtime graphs, `ip -s link`) come from the switch port counters (a backport from Linux 6.16), so they show the real traffic. `br-lan` and the Wi-Fi interfaces still show only the traffic handled by the CPU.
* **After a Wi-Fi restart:** after `wifi down`/`up` (e.g. on a schedule) the access point interfaces return to the flowtable automatically, so uploads from wireless clients keep the fast path.
* HFO bypasses the Linux queueing layer, so it cannot be combined with SQM — see [SQM or hardware offloading?](#sqm-or-hardware-offloading).

### 3. NVRAM Anti-Brick Protection ("6 reboots → orange LED" fix)
* **Problem:** newer stock U-Boot versions increment `flag_try_sys1_failed` in `u-boot-env` (`/dev/mtd3`) on every boot. After 6 reboots U-Boot fails over to the secondary firmware slot (`system 1`), which OpenWrt has overwritten with its unified UBI partition — the router soft-bricks with a solid orange LED.
* **Solution** (`target/linux/mediatek/mt7622/base-files/etc/init.d/bootcount`): on every boot the values below are checked and `fw_setenv` is called only for values that differ (no needless NAND writes):
  * `flag_try_sys1_failed=0`, `flag_try_sys2_failed=0`, `flag_boot_rootfs=0`, `flag_boot_success=1`, `flag_last_success=1`, `boot_fw1="run boot_rd_img;bootm"` — the anti-brick part;
  * `boot_wait=on` and `uart_en=1` — keep TFTP recovery and the U-Boot serial console usable. Both require physical access to the router.
  * `ssh_en` (only used by the stock firmware) is not touched.

### 4. Wi-Fi Defaults (`77_wireless`)
* **Reliable 5 GHz detection on first boot:** `77_wireless` runs `/sbin/wifi config` before configuring the radios, so the `mt7915e` PCIe radio is present in `/etc/config/wireless` even if it finished probing late.
* `radio0` is the SoC-integrated **2.4 GHz (802.11n)** radio, `radio1` is the PCIe **5 GHz MT7915E (802.11ax)** radio. Each radio is configured by its `band`:
  * **Regulatory domain:** country `PA` for both radios (`CONFIG_PACKAGE_MAC80211_COUNTRY="PA"`). It allows more channels and higher transmit power than many other domains; set your own country in LuCI if local regulations require it.
  * **2.4 GHz:** `HT20`, channel `1`, WPA2 (`psk2+ccmp`) for the best IoT compatibility.
  * **5 GHz:** `HE80` on the non-DFS channel `36` (no 1–10 minute DFS/CAC radar drop-outs), `noscan='1'` (no fallback to a narrower channel because of neighbouring networks), WPA2/WPA3 mixed mode (`sae-mixed`) with `ocv='0'` (SAE client compatibility), WNM-Sleep Mode (`wnm_sleep_mode='1'`, `wnm_sleep_mode_no_keys='1'`) and `dtim_period='3'`, which let phones sleep longer and save battery.
  * **SSIDs:** `<board>-<band>-<radio><last 4 hex digits of the MAC>`, e.g. `redmi-router-ax6s-2g-0a1b2` and `redmi-router-ax6s-5g-1a1b2`; password **`12345678`**.
* Settings are applied only if the radio has no Wi-Fi key yet, so they never overwrite a restored configuration.
* **Full `wpad-mbedtls`** instead of `wpad-basic-mbedtls`, OpenWrt's default for this router. The basic variant already supports WPA3 (SAE), 802.11r and 802.11k; the full one adds 802.11v (WNM), which the WNM-Sleep Mode of the 5 GHz defaults above needs, as well as WPS, WPA2/WPA3-Enterprise (802.1X, built-in RADIUS server), 802.11s mesh and Wi-Fi Easy Connect (DPP). Fast roaming (802.11k/v/r) stays off, as in stock OpenWrt: it only matters when several access points share one SSID. For such a network enable it in the wireless settings and install `usteer` (`apk add usteer luci-app-usteer`).
* **Wi-Fi driver fixes from mt76 master** (18 fixes on top of the mt76 of OpenWrt 25.12): kernel crashes around client connects and disconnects and around the recovery of the radio firmware, TX aggregation for voice-priority traffic on 5 GHz, correct HE DCM / VHT STBC client capabilities. On 2.4 GHz the adaptive sensitivity (SCS) of the MT7622 works again (a driver bug had kept it at its default since 2022): on the busy 2.4 GHz channel of the test setup it halved the time the radio considered the channel busy (31 → 15 %) and reduced ping loss to the clients. The threshold never goes above the signal of the weakest connected client. Details: [RESEARCH.md](RESEARCH.md#10-wi-fi-driver-fixes-from-mt76-master).

### 5. Network Stack and Memory (256 MB RAM)
* **Packet steering, mode 2** (`packet_steering='2'`, *Enabled (all CPUs)*, `steering_flows='128'`): pins the threaded NAPI workers of the Ethernet (`mtk_eth`) and Wi-Fi (`mt76`) drivers to different CPU cores, spreads RPS over both cores and enables RFS with 128 flows. Compared to mode 1 it gives 6–11 % more wired → Wi-Fi throughput to a client receiving more than ~1.2 Gbit/s and shares the load between the cores more evenly, with the same latency in the household tests ([RESEARCH.md](RESEARCH.md#13-packet-steering-mode-2-and-the-operating-modes)). The *SQM* operating mode uses mode 1, which needs less CPU with CAKE ([RESEARCH.md](RESEARCH.md#9-wan-bufferbloat-and-the-need-for-sqm)). `irqbalance` is not installed: it moves only the IRQs, not the NAPI threads that do the packet processing, so it can split the Ethernet IRQs away from their NAPI CPU, and on the device it brought no gain ([RESEARCH.md](RESEARCH.md#1-irqbalance-vs-packet-steering)). It can still be added with `apk add irqbalance`.
* **Sysctl tuning** (`files/etc/sysctl.d/99-bbr.conf`):
  * **TCP BBR**, `fq_codel` and TCP Fast Open (`tcp_fastopen=3`). They apply to TCP connections terminated on the router itself (LuCI, DoH proxy, `iperf3` server, package downloads), not to traffic forwarded for LAN clients. `fq_codel` is the OpenWrt default qdisc anyway.
  * Larger conntrack table (`nf_conntrack_max=32768`) and adjusted TCP/UDP timeouts for P2P and gaming.
  * Global RFS socket flow table (`net.core.rps_sock_flow_entries=1024`). OpenWrt's packet steering only sets the per-queue flow count (`steering_flows`); without this table RFS stays inactive. It affects only traffic terminated on the router itself.
* **Stealth firewall:** `input`/`forward` policies of the defaults and the `wan` zone are `DROP` instead of `REJECT`, plus `drop_invalid='1'`. SSH (`dropbear`) listens only on the LAN interface (`Interface='lan'`).
* **LAN NTP server** (`system.ntp.enable_server='1'`).
* **`zram-swap` 120 MB with `lz4`** (`CONFIG_KERNEL_ZRAM_DEF_COMP_LZ4=y`) and `vm.swappiness=100`, `vm.page-cluster=0`, `vm.vfs_cache_pressure=50`.
* **Services are restarted indefinitely** after crashes (procd `respawn_retry='0'`); `https-dns-proxy` tolerates WAN reconnects (`conn_loss_time='30'`).
* **Fixes ahead of OpenWrt 25.12.7:**
  * Linux kernel, CVE-2026-98432: a TCP connection to the router itself with crafted IPv4 options could crash it or corrupt kernel memory (the fix of Linux 6.12.113);
  * no kernel panic when a program that handles traffic through NFQUEUE, such as `nfqws` of zapret, re-injects a packet the kernel does not expect: the packet is dropped and the kernel log shows a warning once (the random reboots of [openwrt/openwrt#26151](https://github.com/openwrt/openwrt/issues/26151));
  * the root certificate "emSign ECC Root CA – G3" is no longer trusted: it issued certificates with keys anyone can recover;
  * musl, CVE-2026-107891: integer overflows in regular expressions;
  * dnsmasq: large hosts files, such as ad-blocking lists, load in seconds instead of minutes.

### 6. How the Defaults Are Applied (`99-custom-settings`)
`uci-defaults` scripts run on the first boot after **every** flash, including a sysupgrade that keeps settings. `files/etc/uci-defaults/99-custom-settings` applies the settings from sections 2 and 5 and the DoH, statistics, DDNS autostart and LuCI theme defaults (see [Pre-installed packages](#pre-installed-packages)) **only once per configuration** and stores a marker in `/etc/config/ax3200`. Your own changes (for example HFO disabled in favour of SQM) are therefore preserved across upgrades. Only removing the collectd include of older builds runs on every flash. Two later defaults are also applied once to configurations upgraded from earlier builds: `bridger` off, and packet steering mode 2 instead of mode 1 (unless SQM is on). The list of LuCI themes is brought in line with the installed themes on every boot (`files/etc/init.d/luci-themes`), so this also works after restoring a settings backup made on another firmware. To re-apply the build defaults:
```sh
uci -q delete ax3200.defaults && uci commit ax3200
sh /rom/etc/uci-defaults/99-custom-settings
reboot
```

### 7. Official Package Repository Compatibility (`vermagic` + `apk`)
* `vermagic_update.sh` downloads the kernel `vermagic` of the official OpenWrt 25.12.6 release (`685dcedeed3538a4cc670fc3fd59eac1`) and `scripts/getvermagic.sh` builds the kernel with it, so `kmod-*` packages from the official repository install without `vermagic` mismatch errors.
* **The kernel configuration matches the official one.** A matching `vermagic` is not enough on its own: an official module only works if every kernel structure it uses has the same layout. The official buildbot builds with `CONFIG_ALL_KMODS=y` and without `KALLSYMS`, which changes `struct module`, `net_device`, `struct net` and `sk_buff`. This build does the same (`CONFIG_ALL_KMODS=y`, `# CONFIG_KERNEL_KALLSYMS is not set`), so its kernel `.config` differs from the one in the official SDK only in the GCC version, the `schedutil` default governor and the zram compression backends — none of them affects the module ABI.
* **Verified on the device:** the official `kmod-dummy` and `kmod-wireguard` (with the NEON-accelerated ChaCha20/Poly1305 modules) load and work; a WireGuard tunnel carried ~2 GiB at 530–600 Mbit/s without kernel errors.
* `ALL_KMODS` only builds all kernel modules into `bin/`; the firmware contains just the selected ones. Without `KALLSYMS` the kernel is ~260 KiB smaller in flash and ~0.7 MiB smaller in RAM, and kernel oops traces show addresses instead of function names (as in official images).
* Packages are managed with OpenWrt 25.12's native **`apk`** (`apk-mbedtls`) and `luci-app-package-manager`.

---

## Operating Modes

The best acceleration settings depend on how the router is used. LuCI → *System → Operating mode* (`luci-app-tuning`, a package of this build) sets them together, as modes measured on this router ([RESEARCH.md](RESEARCH.md#13-packet-steering-mode-2-and-the-operating-modes)): the flow offloading type, WED, `bridger`, packet steering, the CPU frequency governor and SQM. Each mode lists whom it suits, its pros and cons with the measured numbers, and its warnings.

| Mode | For | Settings |
|---|---|---|
| **Balanced** (default) | A typical home: phones, a TV, laptops, gaming, a plan up to 1 Gbit/s. | hardware NAT and WED, `bridger` off, packet steering 2, `schedutil` |
| **Maximum throughput** | Large copies from a wired NAS or PC to one Wi-Fi device: ~1.3 Gbit/s at ~8 % CPU instead of ~70 %. Not for VR or gaming: higher latency and less fair sharing of the air. | as Balanced, plus `bridger` and `performance` |
| **Low latency** | VR streaming from a wired PC, gaming over Wi-Fi: slightly lower latency peaks while another device downloads (p99 ~27 instead of ~30 ms). Internet downloads to Wi-Fi need more CPU. | as Balanced, but WED off and `performance` |
| **SQM (slow link)** | Links slower than ~300 Mbit/s whose latency grows a lot under load ([SQM or hardware offloading?](#sqm-or-hardware-offloading)). | software flow offloading, CAKE on the WAN, WED off, packet steering 1, `performance` |
| **Custom** | Any combination of the settings under *Advanced*. | |

* Applying a mode reboots the router: WED can only change at boot.
* The page shows the mode that matches the current settings; after changes on other pages it shows *Custom*.
* The mode is kept across firmware upgrades.

---

## Firmware Updates

From r10 on, the router looks for new releases of this build on GitHub. When a release is out, the Overview page shows a notice. LuCI → *System → AX3200 / AX6S build updates* lists what changed and installs the update with one button, with or without keeping the settings; before installing, the router checks that the file is complete and fits this router. Some releases cannot be installed this way, for example when the flash layout changes: the page then says why and links to the instructions. The check can be turned off or set to another interval on the same page.

This is standard OpenWrt behaviour: an update removes the packages you installed yourself. With **Keep my packages** next to the update button (on by default), the router installs them again once it is online after the update, and repeats replacements of image packages, such as `dnsmasq-full` instead of `dnsmasq`; services you had turned off stay off. Packages installed not from a repository (from a file or by an install script) have to be installed again by hand: the page lists them. After installing them, the router restarts once, so that they start as after a normal boot. An update made another way (*Backup / Flash Firmware*, `sysupgrade`) does not restore packages.

Attended Sysupgrade, OpenWrt's own update tool, is not part of this build. It can be installed separately, and an update through it works, but the router then moves to plain OpenWrt without the advantages of this build.

---

## SQM or Hardware Offloading?

**SQM** (`luci-app-sqm`, CAKE) fights **bufferbloat** — latency spikes when the link is saturated (calls, games and browsing lag while something downloads or uploads). It needs to see every packet. **Hardware flow offloading (HFO)** moves established flows into the PPE, past the Linux queueing layer, so **SQM does nothing while HFO is enabled**. Without HFO, WED does not work either, and all routed and Wi-Fi traffic is handled by the CPU.

| | HFO + WED (default) | SQM (CAKE) |
|---|---|---|
| Max routed throughput | ~1 Gbps, almost no CPU load | CPU-bound: measured ~400 Mbit/s for wired clients and ~230–250 Mbit/s for 5 GHz clients, with one core at its limit ([RESEARCH.md](RESEARCH.md#9-wan-bufferbloat-and-the-need-for-sqm)) |
| Latency under load | depends on the ISP / modem buffers | low and stable |
| Best for | fast links (≳ 500 Mbps), links without bufferbloat | slower or asymmetric links: DSL, LTE/5G, cable, PPPoE below ~300–500 Mbps |

**How to choose:** run a bufferbloat test (e.g. Waveform "Bufferbloat Test") over a wired connection with the default settings. If latency under load stays low (grade A/B), keep HFO. If it grows by tens or hundreds of milliseconds and your plan is below ~300 Mbit/s, switch to SQM.

**Switch to SQM:** LuCI → *System → Operating mode* → **SQM (slow link)**, enter the download and upload rates (~85–95 % of the speeds measured without SQM) and click *Apply*; the router reboots. Then repeat the test. The mode switches hardware offloading to software offloading, which works with SQM on this router at the same speed and latency, and turns on CAKE on the WAN at the entered rates. Further SQM options, such as the link layer overhead of DSL, stay in LuCI → *Network → SQM QoS*.

**Back to HFO:** choose *Balanced*.

The choice is kept across sysupgrades (see [section 6](#6-how-the-defaults-are-applied-99-custom-settings)).

---

## Wi-Fi at 160 MHz (HE160) and VR Streaming

The 5 GHz radio defaults to **HE80 on channel 36** for the widest client compatibility. The MT7915E also supports **160 MHz (HE160)**, which doubles the link rate of the usual 2×2 clients (phones, laptops, VR headsets): up to 2402 Mbit/s instead of 1201 Mbit/s. At 160 MHz the radio uses 2 spatial streams instead of 4, so 3×3/4×4 clients gain less.

With the `PA` regulatory domain the 5470–5725 MHz band (channels 100–128) allows 160 MHz **without DFS**: no 1-minute channel availability check after boot and no channel switches on radar detection.

Trade-offs:
* clients that do not support channels 100–144 will not see the 5 GHz network;
* slightly shorter range at the edge of coverage (the same power is spread over twice the bandwidth);
* outside Panama these channels are usually subject to DFS rules — check your local regulations.

Enable it in LuCI → *Network → Wireless* → 5 GHz radio → *Edit* → *Operating frequency*: mode **AX**, channel **100**, width **160 MHz** → *Save & Apply*, or over SSH:
```sh
uci set wireless.radio1.channel='100'
uci set wireless.radio1.htmode='HE160'
uci commit wireless
wifi reload
```
`iwinfo wl1-ap0 info` then shows `HT Mode: HE160`. To go back to the default, set channel `36` and `HE80`.

**PC VR streaming** (Virtual Desktop, Steam Link, Air Link) benefits most from HE160 — provided the headset supports 160 MHz on 5 GHz (check its specifications; support depends on the model and its firmware):
* connect the PC to a LAN port with a cable, so that there is only one wireless hop;
* keep the headset in the same room as the router, ideally with line of sight;
* connect the headset to the 5 GHz network only;
* use the *Balanced* or the *Low latency* operating mode, not *Maximum throughput*: it raises the latency of the stream ([Operating modes](#operating-modes));
* avoid large downloads to other 5 GHz devices while playing: an ordinary evening (a TV streaming 4K, phones) did not affect the stream, but a full-speed download to another client raised its p99 latency from 6–11 ms to 50–100 ms in every configuration.

Measured with a 2×2 HE160 laptop as the headset about 1 m from the router (link rate 1815–2402 Mbit/s) and a wired PC as the source: a 200 Mbit/s VR-like UDP stream lost 0.01–0.15 % of its packets, ping 1.6–1.8 ms median and 6–11 ms p99, also next to a TV streaming 4K from the internet. Wired → Wi-Fi reaches 1.25–1.35 Gbit/s, Wi-Fi → wired 1.5–1.8 Gbit/s ([RESEARCH.md](RESEARCH.md#12-several-wi-fi-clients-latency-and-wed)).

---

## Pre-installed Packages
* **Web UI:** `luci`, `luci-ssl`, full Russian and English localization (`CONFIG_LUCI_LANG_ru=y`; the language follows the browser). Themes: **Footstrap** (default) — the new LuCI theme with a collapsible sidebar or top bar, light/dark modes, a menu search and an *Appearance* page for colours, density, layout and wallpaper — and the stock **Bootstrap**. After an upgrade from an older build or after restoring a settings backup made on another firmware, Footstrap is listed again and a removed theme (OpenWrt-2020, Material) is replaced with Footstrap automatically.
* **Encrypted DNS (DoH, HTTP/2 & HTTP/3):** `https-dns-proxy` + `luci-app-https-dns-proxy` (Cloudflare and Google out of the box). Clients are not forced to use the router's DNS (`force_dns='0'`), so client-side encrypted DNS such as Android Private DNS (DoT) keeps working.
* **SQM / CAKE QoS:** `luci-app-sqm` (`sqm-scripts`, `kmod-sched-cake`) — installed but **disabled** by default; the *SQM* operating mode sets it up.
* **Home network services:**
  * `luci-app-upnp` (`miniupnpd-nftables`), `luci-app-wol` (`etherwake`), `luci-app-watchcat`, `luci-app-wifischedule`, `luci-app-uhttpd`;
  * `luci-app-ddns`: its autostart is off while no DDNS service is enabled (set up a service, then *Services → Dynamic DNS → Start DDNS*). With a LuCI fix ([openwrt/luci#9154](https://github.com/openwrt/luci/pull/9154)): without internet the DDNS status no longer leaves LuCI's Overview empty for 10 s per service;
  * `luci-app-tuning`: operating modes (*System → Operating mode*), a package of this build in `package/ax3200/`. It replaces `luci-app-cpufreq` of earlier builds: the CPU frequency governor is set on the same page;
  * `luci-app-fwupdate`: firmware updates (*System → AX3200 / AX6S build updates*), a package of this build in `package/ax3200/`;
  * `bridger`: wired → Wi-Fi traffic in hardware, off by default, enabled by the *Maximum throughput* mode ([section 2](#2-hardware-nat-and-wi-fi-6-acceleration-hfo--wed)).
* **Monitoring and diagnostics:** `luci-app-nlbwmon` (per-client traffic accounting), `luci-app-statistics` (`collectd` graphs of CPU load and frequency, RAM, `br-lan`/`wan`, Wi-Fi, conntrack, hardware sensors and the MT7915E temperature; the `wan` graph includes offloaded traffic, see [Interface graphs with offloading](#2-hardware-nat-and-wi-fi-6-acceleration-hfo--wed)), `luci-app-ttyd` (web terminal), CLI tools `htop`, `nano`, `curl`, `iperf3`, `ethtool`, `tcpdump-mini`, `bind-dig`, `mtr-nojson` and the full `ip` command (`ip-full`, which packages such as Steer of Zapret Manager need).

---

## Building

[BUILDING.md](BUILDING.md): `build.sh`, GitHub Actions, a manual build and changing the configuration.

---

## About OpenWrt Project

OpenWrt Project is a Linux operating system targeting embedded devices. Instead
of trying to create a single, static firmware, OpenWrt provides a fully
writable filesystem with package management. This frees you from the
application selection and configuration provided by the vendor and allows you
to customize the device through the use of packages to suit any application.
For developers, OpenWrt is the framework to build an application without having
to build a complete firmware around it; for users this means the ability for
full customization, to use the device in ways never envisioned.

### Support & Documentation

* [Xiaomi AX3200 / Redmi AX6S OpenWrt Wiki](https://openwrt.org/toh/xiaomi/ax3200)
* [XMiR-Patcher](https://github.com/openwrt-xiaomi/xmir-patcher)
* [OpenWrt Firmware Selector](https://firmware-selector.openwrt.org/)
* [Developer Documentation](https://openwrt.org/docs/guide-developer/start)

## License

OpenWrt is licensed under GPL-2.0
