# Research and Measurements

The measurements behind the decisions of this build, taken in October 2026 on a Redmi AX6S running OpenWrt 25.12.6 (`xq-25.12`) with a real home configuration. Each section ends with the decision it led to.

**Contents:** [Test setup](#test-setup) · [1. irqbalance](#1-irqbalance-vs-packet-steering) · [2. Official kmods](#2-official-kmod-compatibility) · [3. Traffic accounting](#3-traffic-accounting-with-hardware-offloading) · [4. Interface counters](#4-interface-counters-with-hardware-offloading) · [5. CPU governor](#5-cpu-frequency-governor) · [6. Latency](#6-latency-and-jitter) · [7. Kernel hardening](#7-cost-of-kernel-hardening) · [8. Extreme build](#8-extreme-build-experiment-dropped) · [9. WAN bufferbloat](#9-wan-bufferbloat-and-the-need-for-sqm) · [10. mt76 fixes](#10-wi-fi-driver-fixes-from-mt76-master) · [11. Wi-Fi ↔ LAN and bridger](#11-wi-fi--lan-throughput-and-bridger) · [12. Several clients, latency, WED](#12-several-wi-fi-clients-latency-and-wed) · [13. Operating modes](#13-packet-steering-mode-2-and-the-operating-modes) · [14. zapret](#14-zapret-and-flow-offloading) · [15. PPPoE](#15-pppoe-through-the-router-lab)

## Test setup

* **Router:** HFO + WED on, 5 GHz HE160 on channel 100, 2.4 GHz HT20, packet steering, LuCI, statistics, nlbwmon, DoH, UPnP, watchcat.
* **Wi-Fi client:** a laptop with Intel Wi-Fi 6 (2×2, HE160, −42 dBm), or a VM on it behind NAT. **Wired:** a PC on `lan1` (1 Gbit/s).
* **Tools:** `iperf3` (15 s per run), `irtt` (UDP probes every 10 ms for 25 s), router CPU from `/proc/stat` during each run (the share of both cores, so 100 % means both are busy), `nlbw -c csv` deltas for accounting.
* **Pitfalls of the method:**
  * The Wi-Fi link changes after every reconnect (e.g. HE-MCS 3 vs 9 after a router reflash), so firmwares or settings are compared only in interleaved runs on one connection.
  * The client's Wi-Fi power save adds latency spikes of tens of ms: switch it off for latency tests (`iw dev <wlan> set power_save off`).
  * nlbwmon zeroes the conntrack counters on every dump: measure accounting through `nlbw` deltas after more than 30 s (its refresh interval), never through `/proc/net/nf_conntrack`.
  * CPU per Gbit/s is only comparable at similar throughput: when Wi-Fi throughput drops, the CPU load stays about the same and the ratio inflates.
  * Some public test servers block a client after heavy use (proof.ovh.net did after ~12 GB). Spread the load.
  * Do not ping the ISP gateway at a high rate: it rate-limits ICMP (64 % loss at 50 pings/s) and then also holds back transit ICMP for ~0.9 s, which looks like a stall of the whole connection. Ping external hosts instead (1.1.1.1, 8.8.8.8: no stalls at 100 pings/s).

## 1. irqbalance vs packet steering

A/B with `irqbalance` and with packet steering only (both directions, 4 streams, 20 s):

| | with `irqbalance` | packet steering only |
|---|---|---|
| Wi-Fi throughput | 1301 / 902 Mbit/s | 1228 / 925 Mbit/s (Wi-Fi noise) |
| Wired throughput | ~933 Mbit/s | ~933 Mbit/s |
| CPU load | equal within 1.5 % | equal within 1.5 % |
| IPIs per GB | — | 33–39 % fewer |

`irqbalance` always moves the RX interrupt of `mtk_eth` to CPU1, while packet steering pins both `napi/mtk_eth-*` threads to CPU0, which causes cross-core wakeups and gains nothing. **Decision:** no `irqbalance`.

## 2. Official kmod compatibility

* With the official vermagic, official kmods installed but were rejected by the kernel: `struct module` was 704 bytes here and 640 in the official build, which disables `KALLSYMS`.
* Disabling `KALLSYMS` alone was not enough: the kernel configuration differed from the official SDK in 1333 symbols, many of them changing `net_device`, `struct net` or `sk_buff`, so modules would load and corrupt memory.
* With `CONFIG_ALL_KMODS=y` and `KALLSYMS` off, 14 differences remain, none affecting the ABI (GCC version strings, `schedutil`, zram backends). The kernel shrank by 259 KiB of flash and 764 KiB of RAM.
* Verified on the router: official `kmod-dummy` and `kmod-wireguard` load; a WireGuard tunnel carried 2.1 GiB at 528 / 602 Mbit/s without kernel errors.

**Decision:** keep `ALL_KMODS` and `KALLSYMS` off as long as the vermagic is the official one; re-check after every kernel update ([UPGRADING.md](UPGRADING.md#appendix-b-kernel-configuration-parity-check)).

## 3. Traffic accounting with hardware offloading

nlbwmon counts the conntrack counters, which for offloaded flows come from the PPE. Six bugs were found and fixed:

1. **Phantom jumps of ~4 GB (2³²):** the PPE flow counters went backwards on unbind/rebind, and `nf_ct_acct_add()` truncated the negative delta to 32 bits. About 10 jumps per hour before the fix; none in 43- and 62-minute load tests after it (patch `970`).
2. **Lost tail of every closed connection:** the flowtable polls the counters only every ~3 s and removed the hardware entry after a TCP FIN without a final poll (patch `971`).
3. **Lost tail even with a final poll:** the PPE unbinds an entry by itself after a TCP FIN, and the driver then folded only its software copy of the counters, not the hardware MIB counter (second part of patch `970`).
4. **A neighbour in the same PPE bucket stopped counting:** on the MT7622 a bucket of the PPE hash table has two slots. When a second flow bound to the other slot, the driver detached the first one, although it stayed bound in hardware: its counters stopped while it kept sending, and after the flowtable removed it, its PPE entry stayed bound and kept forwarding. Patch `970` now detaches only the entry naming the slot being bound, as proposed in [openwrt/openwrt#26107](https://github.com/openwrt/openwrt/pull/26107).
5. **A firewall reload dropped the offloaded flows:** fw4 replaces the flowtable on every reload, and its block callbacks were unbound before the flows were freed, so the driver never removed their PPE entries. The flows stopped counting, were never offloaded again (their driver entries blocked the new ones), and kept forwarding in hardware until they ended. Fixed by patches `972` and `973` from the SmartRG tree ([target-cascade](https://github.com/cmonroe/target-cascade)).
6. **Flows with one direction on the CPU were polled late:** the flowtable polls the hardware counters only when a tenth of the flow timeout has passed since the timeout was last refreshed, and every packet of the CPU direction refreshes it. On the MT7622 Wi-Fi → WAN always takes the CPU (no WED RX), so the counts of a Wi-Fi download reached conntrack only when it paused, and `nf_ct_acct_add()` truncated a poll of 4 GiB or more to 32 bits. Patches `975` and `974`, found in the code of 6.12.

| Test (nlbwmon count / payload) | before | patch `971` only | `970` + `971` |
|---|---|---|---|
| 300 MiB, connection closed at once | 69–84 % | 70–86 %; 50–59 % on another server | **105.0 %** (5 of 5) |
| 30 × 10 MiB, each on its own connection | — | **4.0 %** | **105.1 %** |
| 300 MiB, connection idle 10 s before closing | 105 % | 105 % | 105 % |
| iperf3 TCP upload / download, 10 s | — | 105 % / 108 % | 105 % / 108 % |
| HTTP/3 (QUIC, UDP) | — | 108 % | 108 % |
| 1-hour mixed load, share of the payload | 90.7 % | — | **105.0 %** |
| All clients vs the WAN port hardware counter | 86.9 % | — | **100.0 %** |

105 % is the payload plus TCP/IP headers.

**Bucket test (bug 4):** three 5 Mbit/s UDP flows from a PC to an iperf3 server, with source ports chosen with the driver's hash function (`mtk_ppe_hash_entry()`) so that flow B lands in the bucket of flow A (slots `0x2fce` and `0x2fcf` in `/sys/kernel/debug/ppe0/bind`) and flow C in another bucket. B starts 45 s after A. Conntrack bytes against what iperf3 sent:

| Flow | sent (with headers) | before | after |
|---|---|---|---|
| A, first in the bucket | 64.5 MB | **29.1 MB**, stopped when B bound; its PPE entry outlived the flow | 64.5 MB |
| B, its neighbour | 35.5 MB | 35.5 MB | 35.5 MB |
| C, another bucket | 48.4 MB | 48.4 MB | 48.4 MB |

After the fix all three are counted to within 600 bytes (the PPE counts the 18 bytes of L2 headers per packet too), no PPE entry outlives its flow, and a 145 MB download closed at once is still counted at 105.2 % (2 of 2).

**Firewall reload test (bug 5):** one 5 Mbit/s UDP flow, `/etc/init.d/firewall reload` after 30 s, conntrack bytes against what iperf3 sent (58.04 MB with headers): before, 18.6 MB, the flow was never offloaded again, and its PPE entry kept forwarding until the flow ended; after, 58.04 MB, the flow stayed offloaded and its PPE entry went away with it. The bucket test and the download test give the same results as above.

**Wi-Fi download (bug 6):** one HTTPS connection from a 5 GHz client for 90 s, conntrack sampled every 2 s. With `975` the download direction (WAN → Wi-Fi, PPE + WED) reached conntrack every 3–4 s during the transfer, and 5.18 GB of payload on that one connection were counted as 5.55 GB (107 %, as for Wi-Fi before), more than 4 GiB without loss. Without the patches the whole download would have come in one poll at the end, truncated to 32 bits (about 1.25 GB); the old firmware was not measured.

**openwrt/openwrt#26107 in place of our patch (2026-10-29).** `736-06` of [openwrt/openwrt#26107](https://github.com/openwrt/openwrt/pull/26107) (Alexander Goodkind) carries the counter saving of our `970` together with two changes from Chad Monroe's tree. First, it checks the whole bucket before it binds the matching flow. Our version bound it at once, and the bind resets the slot counters, so an entry naming the same slot further down the list lost its last counters. Second, it takes the stats snapshot under `ppe_lock`: a rebind on another CPU between the snapshot and the update could count the same traffic twice. Same tests, wired client (a PC):

| Test | our `970` (r92) | #26107 alone (`970`–`976` removed) | #26107 + `971`–`976` |
|---|---|---|---|
| 145.6 MB download closed at once, 5 runs | 105.4 % | 105.4 % | 105.4 % |
| 30 × 10 MiB, each on its own connection | 105.7 % | 105.8 % | 105.8 % |
| Bucket test, three UDP flows | all in full | all in full | all in full |
| Firewall reload during a UDP flow | in full (above) | 31.6 % | in full |
| One keep-alive HTTPS connection, ranged requests with 10–25 s pauses (the PPE ages the idle entry out after ~20 s, the next request binds it again) | — | 45 min, ~100 rebinds: 105.6 %, no jump | 20 min, 22 rebinds: 105.7 %, no jump |
| All hosts against the WAN port counters during that run | — | 99.6 % | 100.3 % |

"In full" means conntrack holds what iperf3 sent plus the 18 bytes of L2 header per packet that the PPE counts too (101.2 %). Without `972`/`973` a firewall reload still loses the flow, as before; Pablo Neira Ayuso's "netfilter: flowtable: perform unbind callback on hook release" (netfilter-devel, 2026-10-28) targets the same problem.

**Decision:** patches `970` (since 2026-10-29 `736-06` of openwrt/openwrt#26107, unchanged) and `971` (see [UPGRADING.md](UPGRADING.md), checklist items 11–12). Drop `970` once the release carries #26107.

## 4. Interface counters with hardware offloading

The software counters of the network interfaces never see offloaded traffic. During a 210 MB download the `wan` counter grew by 0.1 MB, the switch port's hardware counter by 220 MB. A collectd `ethstat` graph of the hardware counter was a first workaround.

The backport of the upstream `mt7530` `.get_stats64` series (Linux 6.16) and its fix (7.1) makes the hardware counters the statistics of `wan` and `lan1`–`lan3`: `wan` +220.9 MB and `lan1` +220.2 MB for the same download, the `wan` graph showed 36.3 MB/s over 30 s for a 1 GB download, and 200 consecutive reads of `/proc/net/dev` logged no kernel errors. `br-lan` and the Wi-Fi interfaces still count only CPU-handled traffic. **Decision:** keep the backport, drop `ethstat`.

## 5. CPU frequency governor

| | `schedutil` | `performance` |
|---|---|---|
| CPU per Gbit/s, Wi-Fi → LAN bridge | 89 % | 64.5 % |
| CPU per Gbit/s, LAN → Wi-Fi bridge | 65 %¹ | 55.7 % |
| CPU, LAN → WAN (offloaded) | ~6 % | ~1 % |
| Wi-Fi round-trip at idle (median) | 1.60 ms | 1.42 ms |
| Latency under load | same | same |
| Throughput | same (limited by Wi-Fi) | same |
| WAN up after power-on | 20.6–21.0 s | 20.7–21.0 s |
| Router temperature at idle | 57 °C | 59–59.5 °C |

¹ No run above 880 Mbit/s; average of all runs. The `performance` column: runs at ≥ 880 Mbit/s.

At a fixed 1.35 GHz the same work takes a smaller share of time than at the lower clocks `schedutil` picks. During a transfer the clock stays near 1.35 GHz anyway. Much of the extra busy time is the governor's own thread `sugov:0`. In the transfers of 2026-10-29 it took 7–15 % of a core, and ~22 % with bridger, where the load is lighter and more uneven. The clock changed 400–600 times per second (`stats/total_trans`): the MT7622 driver reports no transition latency, so `rate_limit_us` defaults to 1 ms; the CPU is not the bottleneck either way (50–60 % busy at ~900 Mbit/s over the bridge). Earlier, at idle: 3.8 % CPU with `schedutil` vs 6.0 % with `ondemand`. **`rate_limit_us` of `schedutil` (2026-10-29).** It sets how often the governor may change the clock, up or down; the kernel's default here is 1 ms. Two interleaved rounds per value, *Balanced* mode, laptop on 5 GHz with Wi-Fi power save off, a PC wired (`tests/scripts/rl/` outside the repository):

| `rate_limit_us` | 1 ms | 4 ms | 10 ms | 20 ms |
|---|---|---|---|---|
| `sugov:0` during LAN ↔ Wi-Fi transfers, share of a core | 7–15 % | 2–5 % | 1.4–3.5 % | 0.6–1.9 % |
| clock changes per second during transfers | 418–625 | 76–216 | 51–89 | 31–49 |
| idle: `sugov:0` / CPU0 busy / mean clock | 3–4 % / 7–8 % / ~500 MHz | 2.5 % / 5–6 % / ~540 MHz | 2 % / 4 % / ~595 MHz | 1.5 % / 4 % / ~650 MHz |
| idle ping PC → laptop, median | 1.48–1.53 ms | 1.47–1.60 ms | 1.49–1.51 ms | 1.43–1.59 ms |

Throughput (812–932 Mbit/s) and the idle temperature (58–59 °C over the 60 s windows) did not depend on the value. A sudden 800 Mbit/s UDP burst from the PC to the laptop after idle (the clock sampled every 2 ms by a ucode loop on the router, which keeps the CPU idle unlike a shell loop): from 437.5 MHz the clock reached 1.35 GHz after ~15–18 ms at 1 ms, ~26 ms at 4 ms and ~58 ms at 20 ms (one clean run each; mostly background traffic had already raised the clock). The loss in the first 100 ms (0–14 %) did not follow the value: the worst runs had the clock at 1.35 GHz throughout, and the 20 ms run that ramped from 437.5 MHz lost nothing. The CPU uses the lowest and the highest of its seven steps most of the time (437.5 MHz at 1.00 V to 1.35 GHz at 1.31 V); the five between them took ~7 % of the time.

**Decision:** `schedutil` stays the default; the operating modes for throughput, low latency and SQM use `performance`, and it can also be set alone ([section 13](#13-packet-steering-mode-2-and-the-operating-modes)). `rate_limit_us` is 10 ms (`cpufreq.settings.rate_limit_us`, applied by `/etc/init.d/cpufreq`): most of the gain of 20 ms at a lower idle clock and a faster ramp.

## 6. Latency and jitter

`irtt` probes every 10 ms from the laptop on Wi-Fi to the wired PC (the path of a PC → VR headset stream), 4 interleaved rounds per setting on one connection. Round-trip median (p99):

| Scenario | `schedutil` | `performance` |
|---|---|---|
| Idle | 1.60 ms (3.0) | 1.42 ms (2.6) |
| UDP 200 Mbit/s towards the Wi-Fi client (VR-like stream) | 1.81 ms (8.5) | 1.83 ms (8.4) |
| TCP at full speed towards the Wi-Fi client | 22 ms (54) | 22 ms (42) |
| TCP at full speed from the Wi-Fi client | 5.3 ms (12.8) | 6.8 ms (12.5) |

Packet loss stayed at or below 0.32 %. The spikes under load come from the Wi-Fi queues (aggregation and airtime scheduling in mt76/mac80211), the same for every firmware and governor: a full-speed download to the same client raises the median to 12–22 ms and p99 to 40–100 ms, depending on the link rate. For VR, avoid saturating the same Wi-Fi during streaming; firmware or CPU settings do not change this.

## 7. Cost of kernel hardening

A/B on the extreme build (below), 8 runs per direction: disabling `RODATA_FULL_DEFAULT_ENABLED`, `ARM64_SW_TTBR0_PAN` (the Cortex-A53 has no hardware PAN), `HARDENED_USERCOPY` and `SLAB_FREELIST_HARDENED/RANDOM`:

| CPU per Gbit/s | hardening on | hardening off |
|---|---|---|
| Wi-Fi → LAN bridge | 66.1 ± 2.8 % | 67.0 ± 2.8 % (no difference, t = −0.7) |
| LAN → Wi-Fi bridge | 54.5 ± 1.2 % | 51.7 ± 1.4 % (−5 %, t = 4.1; 1.3 points of CPU load) |

Same throughput. **Decision:** keep the hardening, which protects the kernel and the Wi-Fi drivers reachable over the air.

## 8. Extreme build experiment (dropped)

A separate branch tested a build without any compatibility concessions:
* no package manager;
* all in-tree drivers built into the kernel: 9 modules instead of 97, only the wireless stack (built outside the kernel tree) and `gpio-button-hotplug`;
* unused kernel exports dropped with `CONFIG_TRIM_UNUSED_KSYMS`: 395 instead of 13 901, plus a whitelist for the out-of-tree modules. OpenWrt's `CONFIG_STRIP_KERNEL_EXPORTS` is marked `BROKEN` since Linux 6.6;
* the `performance` governor;
* only LuCI, statistics, nlbwmon, DoH, UPnP and watchcat.

| | `xq-25.12` | `xq-25.12` + `performance` | extreme |
|---|---|---|---|
| WAN up after power-on | 20.6–21.0 s | 20.7–21.0 s | 17.5–17.9 s |
| `MemAvailable` 5 min after boot | 114 MB | 117 MB | 134 MB |
| Read-only rootfs / `sysupgrade` image | 11.5 / 17.8 MB | same | 6.0 / 11.5 MB |
| Full build from scratch (Ryzen 9 5900X) | 20 min | same | 14 min |
| CPU per Gbit/s, Wi-Fi → LAN bridge | 89 % | 64.5 % | 66.1 % |
| CPU per Gbit/s, LAN → Wi-Fi bridge (≥ 880 Mbit/s) | 65 %¹ | 55.7 % | 54.3 % |
| Latency, idle / VR-like stream (median) | 1.60 / 1.81 ms | 1.42 / 1.83 ms | 1.50 / 1.96 ms |

¹ Average of all runs, none above 880 Mbit/s.

The lower CPU load came from the governor alone; the main build with `performance` needs the same CPU. The latency did not improve either. The only gains of the leaner image itself were 3 s faster boot, 17 MB more free memory (of 242 MB, mostly unused anyway), a smaller image and a faster build. Its costs: no installable packages or official kmods, no PPPoE, SQM or diagnostic tools, and a second branch to maintain. **Decision:** dropped; the branch was deleted.

Findings worth keeping for future work:
* **OpenWrt `CONFIG_KERNEL_*` options win.** A kernel configuration fragment in `env/kernel-config` is merged last into the target configuration, but OpenWrt's `CONFIG_KERNEL_*` options (`DEBUG_FS`, `IO_URING`, the stack protector) are applied after it.
* **mac80211 debugfs selects `KERNEL_DEBUG_FS`.**
* **`wpad-basic-*` breaks the 5 GHz AP of this build:** it rejects the WNM sleep mode options that `77_wireless` sets. Check access points with `ubus list 'hostapd.*'`; `iwinfo` also lists an AP that failed to start.
* **`sysupgrade` keeps settings by the conffiles lists in `/lib/apk/packages`.** They must stay even without a package manager.
* **Built-in drivers can open new kconfig questions:** making `TCP_CONG_BBR` built in opens the `DEFAULT_BBR` choice and stops a non-interactive build. `make listnewconfig` finds such questions.
* **Stripped modules keep their export names only in `__ksymtab_strings`.**

## 9. WAN bufferbloat and the need for SQM

Pings every 20 ms to 1.1.1.1 and 8.8.8.8 from the wired PC, idle and with the ISP link (~550/550 Mbit/s) saturated by 4 parallel downloads or 4 iperf3 upload streams, hardware offloading on, 2 rounds. Round-trip to 1.1.1.1:

| | Throughput | Median (change) | p99 | Max |
|---|---|---|---|---|
| Idle | — | 8.9 ms | 12.9 ms | 19.0 ms |
| Download saturated | 540–556 Mbit/s | 8.9–9.0 ms (+0.1) | 13.2–13.3 ms | 17.1 ms |
| Upload saturated | 513–573 Mbit/s | 8.8–8.9 ms (0) | 15.5–18.1 ms | 21.3 ms |

8.8.8.8 behaves the same; packet loss stays at or below 0.1 %. The ISP link does not bloat under load, so SQM would cost the hardware offloading (and cap the throughput at what the CPU can shape) without improving the latency. **Decision:** keep hardware flow offloading; no SQM or QoS on this link. On a link that does bloat, follow [SQM or hardware offloading?](README.md#sqm-or-hardware-offloading).

**What SQM costs on this router** (2026-10-24; the ISP link now gives ~600/365 Mbit/s). The wired PC, or the laptop on 5 GHz, saturates the link with 4 parallel downloads (dl.google.com) or uploads (speed.cloudflare.com) for 20 s while pinging 1.1.1.1 at 20/s; CAKE (`piece_of_cake.qos`) on `wan`, bridger running, 2 rounds per configuration:
* Without SQM (hardware offloading): 595–608 / 357–371 Mbit/s at 4–6 % CPU, p99 13–14 ms downloading and 21–22 ms uploading (idle p99 13 ms).
* CAKE at 450/340 Mbit/s, more than the CPU can shape: 392–427 / 283–321 Mbit/s with one core at 96–98 % (packet steering mode 1). The latency is not better than without SQM: p99 13.6–21 ms downloading and 30–42 ms uploading with steering mode 1, 36–45 / 13–17 ms with mode 2.
* CAKE at 250/150 Mbit/s: every configuration reaches the set rates with p99 10–17 ms. Downloading takes 46–50 % CPU with steering mode 1 and 51–62 % with mode 2, so mode 1 needs less CPU for the same result. A 5 GHz client downloading at 232 Mbit/s: with mode 1 one core is at 96–98 % (without WED the CPU also sends to the radio), p99 19–25 ms; mode 2 spreads the load to 67–69 % but has a p99 of up to 42 ms.
* Software flow offloading works with SQM: the CAKE counters of `ifb4wan` and `wan` grow by ~200,000 packets per 10 s at 250 Mbit/s while no PPE entry is bound, with the same throughput and latency as without offloading.

* Packet steering mode 0 (no pinning, no RPS) at CAKE 250/150 Mbit/s, interleaved with mode 1 (the laptop now 4–5 m from the router): the same rates, but 10–13 points more CPU (wired downloading 52–55 % instead of 45 %, a 5 GHz client 68–69 % instead of 58 %) and a slightly higher download latency (p99 13.4–13.7 instead of 10.2–12.5 ms wired, 21.9–22.7 instead of 16.7–18.9 ms on Wi-Fi). Modes 0 and 2 both feed the single CAKE instance of each direction from two cores, which only adds lock contention: the shaper itself runs on one core at a time.

So SQM on this router shapes up to ~400 Mbit/s for wired clients and ~230–250 Mbit/s for Wi-Fi clients. The best SQM setup is software flow offloading and packet steering mode 1, the best of the three modes. bridger can be left on either way: it moves wired → Wi-Fi traffic inside the LAN, which SQM does not shape anyway.

## 10. Wi-Fi driver fixes from mt76 master

OpenWrt 25.12 builds mt76 from Git HEAD 2026-03-19 plus the fixes that reached Linux 6.18.55; mac80211 comes from backports 6.18.55. OpenWrt main has mt76 2026-10-08 and mac80211 7.2. The firmware is the same in both (MT7915 20240429, MT7622 WMAC 20220630), so rate control and the RF side do not change.

Of the 387 mt76 commits since our version, 139 touch the code of this board's chips (MT7915E on 5 GHz, the MT7622 WMAC through `mt7615` on 2.4 GHz, the core and `connac` library) and 41 of them are already in 25.12. Every remaining commit that changes a compiled file was checked against the functions our drivers call: most are for MT7925/7927/7928, MT7996, MLO, NAN, or for the mt76 hardware scan and channel contexts, which neither driver uses (both use `mt76_sw_scan` and mac80211's chanctx emulation). 44 commits from `openwrt/mt76` master (18 initially in `0300…0317`, 10 in `0318` and `0320…0328`, plus 16 recovery, RX A-MSDU, PN replay, and `mt7615` fixes in `0330…0344` and `0346` up to `f79250d`) and two local mt76 patches (`0329` from the Archer A5 v4 build and our `0345` for WED v1 RX reordering) apply on top of 25.12's patches (`package/kernel/mt76/patches/0300…0346`, `0319` unused):

* station add/removal races that corrupt memory (`20f0979088`, `b1bc93f953`, `8f69e214f0`, `7ff2f295a6`), a NULL dereference in the 2.4 GHz driver (`bd41e0fbea`), frames to disassociated stations stuck in the queues (`0898393ee0`);
* firmware recovery (SER): RX hang detection (`af601a725f`), stuck TX queues (`130273a947`), the PHY setup that a full restart skipped (`b1f962a838`), out-of-bounds write in the coredump (`fd3dc2614c`; coredump support is built in) and cancelling `mt7615` coredump work on device unregister (`f79250da`); plus the 2026-11-19 full-reset and teardown fixes: draining `sta_poll_list` and `phy->tx_lock`-guarded `tx_list` on reset (`112d59c5`, `2c2df65` adapted to `phy->tx_lock` since our tree lacks `9571590b`), draining `sta_rc_list` and TWT agreements on `mt7915` full reset / station removal (`4d24c73d`, `734f912c`, `22c089bd`), republishing the global wcid after `mt7915` full reset (`de22bbe1`), and restoring the default MCU timeout for `STA_REC_UPDATE` (`bd95a95`);
* TX/RX wcid lifecycle, A-MSDU, WED v1 RX reordering, and PN replay fixes (`6a2f145`, `9a52272`, `331cd72` adapted to `phy->tx_lock` with `mt7996` dropped, `6145ff0`, `aa7fc23`, `06025c1`, our `0345` gating the `mt76_rx_poll_complete()` BA reorder bypass on `mtk_wed_get_rx_capa(&dev->mmio.wed)`, and `0346` / `3115dbc` with refreshed context after `06025c1` to free replayed 802.3 frames) plus `mt7615_mac_sta_poll()` locking (`3684ad4`). Because MT7622 WED v1 handles TX offload only (`mtk_wed_get_rx_capa() == 0`), `0345` restores software `mt76_rx_aggr_reorder()` on MT7622 while keeping the bypass intact on MT7986 (WED v2 with WO) and MT7988/MT7996 (WED v3 with HWRRO); `aa7fc23` checks BA-session PN once at reorder release (`skip_pn_check`, no dependency on `62694ed0b76f`), and both radios hit the non-`8023` radiotap (`6145ff0`) and A-MSDU subframe (`06025c1`) paths;
* the per-station RSSI average (`ed62359710`): since "mt76: improve signal strength reporting" (February 2022) mt76 fed it zeros, so the adaptive sensitivity (SCS) of the MT7622 WMAC always fell back to its default;
* TX aggregation on the VO queue (`f67ffb60cd`), HE DCM and VHT RX STBC peer capabilities (`e593243800`, `41cecc382b`), 4th-chain ACK RSSI (`cdc6c0d07c`), bounds checks and firmware reply validation (`04017929f6`, `1c9854c436`, `2802466a94`, `0318`, `0320…0328`).

Alongside the mt76 port, two `hostapd` fixes from OpenWrt `main` are cherry-picked (`PKG_RELEASE:=8`): `5b24069798` guards freed BSS entries in ucode `set_bss_order()` during radio/TX-power reloads, and `e8e130a85f` (`923`) clears `WLAN_STA_PENDING_DEAUTH_CB` / `WLAN_STA_PENDING_DISASSOC_CB` when the callback runs or is cancelled so a delayed TX status cannot re-remove a reconnected station.

**WED v1 RX reorder bug, A/B + debug counter diagnosis, and fix (`0345` + `0346`, 2026-11-22):**
An earlier test image (`d962f2553d`, carrying `3115dbc` without `0345`) regressed 5 GHz 4-stream `iperf3` uploads from `813.6–840.4 Mbit/s` (`583–822` retransmits on `fbd08ee272`) down to `378.3–593.4 Mbit/s` (`5031–7630` retransmits; reviewer `432–549 Mbit/s`, `5920–7570` retransmits). Module swaps via `rmmod`/`insmod` initially hid the regression (`837.0–853.7 Mbit/s` even with `3115dbc`) because unloading `mt7915e` detaches WED (`mtk_wed_device_active == 0` until reboot), causing `mt76_rx_poll_complete()` (`mac80211.c`) to run `mt76_rx_aggr_reorder()`. On a debug image booted with MT7622 WED v1 active (`wed_active=1`, `wed_rx_capa=0`), `mt76_rx_poll_complete()` skipped `mt76_rx_aggr_reorder()` (`skip_early=48` from `wl0` only), so out-of-order BA frames (`iv < pn` in `dmesg`) hit `mt76_check_ccmp_pn()` unreordered (`mark_8023_single_noskip=2171`, `mark_8023_frag_noskip=5661` out of `228,603` passed frames, `0` 802.11 marks), and `3115dbc` dropped them (`drop_0340_single=2171`, `drop_0340_frag=5661`), collapsing upload to `122.9 / 120.8 / 109.0 Mbit/s` (`6845–7568` retransmits). Round 2 verified the clean workaround (`b0c4823bac`, `3115dbc` temporarily withheld, `0330`–`0344`: DL `829.7–861.6 Mbit/s`, UL `813.0–843.9 Mbit/s`, L1 SER `echo 1 > sys_recovery` `0 s` outage, 10× 5 GHz churn reconnect median `3.086 s` / max `6.850 s`, data-outage median `2.75 s` / max `7.00 s`).
* **Fix and scratch debug verification (`0345` + `0346` + counter, booted with WED v1 active):** gating the bypass on `mtk_wed_get_rx_capa(&dev->mmio.wed)` (`0345`) with `3115dbc` restored (`0346`) reduced `wl1/mt76/pn_replay_stats` marks across `3` uploads + `1` download (`757,567` passed frames, `658,346` frag heads) from `2171`/`5661` to `mark_8023_single_noskip=15 -> 16` (+1 frame) and `mark_8023_frag_noskip=0` (`drop_0340_single=15 -> 16`, `drop_0340_frag=0`), matching the WED-detached baseline (`7–13` single, `0` frag) while delivering `837 / 826 / 840 Mbit/s` upload (`66–139` retr) and `860 Mbit/s` download.
* **Router CPU during `15 s` `-P 4` 5 GHz upload (`/proc/stat` `10 s` steady-state window at `t=3..13 s`):**
  * `b0c4823bac` (WED bypass active, before `0345`): idle `4.6%` (`cpu0 1.8%`, `cpu1 7.5%`); upload run 1 (`900 Mbit/s`, `449` retr) `64.4%` total (`cpu0 55.7%`, `cpu1 73.2%`, `sys 44.1% irq 4.9% sirq 15.4%`); upload run 2 (`841 Mbit/s`, `525` retr) `58.5%` total (`cpu0 53.8%`, `cpu1 63.3%`).
  * `3f4fd452b8` (`0345` + `0346` + counter, software BA reorder active): upload run 1 (`837 Mbit/s`, `66` retr) `55.0%` total (`cpu0 50.4%`, `cpu1 59.4%`, `sys 38.0% irq 4.5% sirq 12.1%`); upload run 2 (`826 Mbit/s`, `139` retr) `56.9%` total (`cpu0 54.9%`, `cpu1 59.0%`). CPU load is comparable/slightly lower while TCP retransmissions drop 6×.
* **Decision:** keep `0345` and `0346` (`0300`–`0346`); submit `0345` upstream to `linux-wireless` (recorded in `TODO.md`).

**Final checks (2026-11-22, final `0300`–`0346` non-debug image `e5cf972862` with MT7622 WED v1 active):**
* **5 GHz `iperf3` (`15 s`, `-P 4`, laptop <-> PC, `HE160` ch `100`, laptop `Power save: on`, `-47 dBm`):**
  * Download (`-R`, receiver / sender): `842` / `850` (`422` retr), `856` / `864` (`299` retr), `828` / `828` (`17` retr) Mbit/s (within 1 % of Round 2's `829.7–861.6 Mbit/s`).
  * Upload (receiver / sender): `837` / `845` (`157` retr), `838` / `845` (`107` retr), `859` / `866` (`107` retr) Mbit/s (slightly above Round 2's `813.0–843.9 Mbit/s`, with ~6× fewer TCP retransmissions).
  * Router CPU (`/proc/stat`, `10 s` at `t=3..13 s` during UL #1 / #2): `56.0%` (`cpu0 50.4%`, `cpu1 61.5%`, `sys 37.9% irq 5.2% sirq 11.8%`) and `54.3%` (`cpu0 44.0%`, `cpu1 64.5%`, `sys 37.9% irq 4.0% sirq 12.3%`), lower than Round 2 `b0c4823bac`'s `64.4%` / `58.5%`.
* **10× 5 GHz churn (`ucode` `hostapd.del_client` + `0.2 s` station poll waiting for `authorized: yes` + `180 s` `iperf3 -i 0.5`):** `10/10` clean (`pre=1`, `saw_absent=1`, `final authorized=1`, zero new `dmesg` or `logread` errors); station reconnect (`1.739..17.200 s`) median `4.175 s` / max `17.200 s`, and `0.00 bits/sec` iperf3 outage runs (`8` runs, `1.5..22.5 s` where kicks #4+#5 and #8+#9 coalesced after 16–17 s client scans) median `5.5 s` / max `22.5 s` (`506 Mbit/s` overall).
* **`dmesg`:** identical to baseline boot aside from build timestamp, UBI erase counter, FIT sizes, and UBIFS UUID (zero new warnings or errors).

**Above 1 Gbit/s, and the latency cost of `0345` (2026-11-22).** The checks above ran through one gigabit port (~940 Mbit/s at most), so a loss above it would not show. Three images were compared at one placement of the laptop, interleaved:
* **A** is `e5cf972862` (`0300`–`0346`);
* **B** is `fbd08ee272` (`0300`–`0329`, before these fixes);
* **C** is `b0c4823bac` (`0300`–`0344` and the hostapd fixes, without `0345` and `3115dbc`).

The setup is that of [section 11](#11-wi-fi--lan-throughput-and-bridger): the laptop on HE160 channel 100, Wi-Fi power save off; two wired iperf3 servers at once (a PC on `lan1`, the mini-server on `lan2`), 4 streams each, 20 s after 2 s left out; *Balanced* mode; 100 pings/s from the laptop to the mini-server meanwhile. The laptop was ~1 m from the router but heard at −50 dBm (−45 dBm in section 11) and sent at HE-MCS 9 (MCS 11 in section 11).

| Order A → B → C → A | A (first / last) | B | C |
|---|---|---|---|
| Wi-Fi → LAN, mean of 3 | 1211 / 1234 Mbit/s | 1208 Mbit/s | 1202 Mbit/s |
| LAN → Wi-Fi, mean of 3 | 1119 / 1124 Mbit/s | 1077 Mbit/s | 1140 Mbit/s |
| TCP retransmissions of an upload | 0 | 300–450 | 320–780 |
| router CPU | 62–70 % | 63–73 % | 62–72 % |

The images give the same throughput. It is lower than in section 11 because of the weaker link: the router CPU at ~65 % is not the limit, and `performance` gave the same numbers.

**Ping at a fixed load**, A against C (order A → C → A, 3 runs each, median of the ping):

| Load | A | C |
|---|---|---|
| idle | 1.3 ms | 1.3 ms |
| upload capped at 400 Mbit/s | 1.9 ms | 2.3 ms |
| upload capped at 800 Mbit/s | 5.1 ms | 4.5 ms |
| download capped at 800 Mbit/s | 5.7 ms | 5.8 ms |
| upload not capped (~1.2 Gbit/s) | 31 ms | 21 ms |

* **Medians below the link capacity are the same.**
* **At full upload A is ~10 ms higher.** The cause is the laptop's TCP. Without the false loss signals of unordered frames, its window grows to ~2.5 MiB per stream instead of ~0.9 MiB, and fills the queue of the laptop's own Wi-Fi card (its mac80211 queue stayed empty). The ping grows with the load: one run on A capped at 1.1 Gbit/s gave 17.5 ms.
* **The tail.** With an upload running, the uploading station's own traffic stalls more often with `0345`. The test sent two pings at once, 1400 each in 14 s, during a capped upload (order A → C → A; 8 runs per load on A, 4 on C):
  * the ordinary ping shares TID 0 with the upload;
  * a ping marked VO uses TID 7 on the laptop.

  | Stalls of 80 ms or more in the ordinary ping | 400 Mbit/s | 800 Mbit/s |
  |---|---|---|
  | A | 1 in 112 s | 49 in 112 s (one per ~2.3 s) |
  | C | 0 in 56 s | 5 in 56 s (one per ~11 s) |

  A stall is a run of pings more than 60 ms above the run's median. The VO ping had none of 80 ms or more on either image. A's stalls peak at about 100 ms (91–111 ms), and the pings behind a stall arrive together. This looked like mt76's reorder timeout (`HZ / 10`, 100–110 ms with `CONFIG_HZ_100`), but a debug build showed that the router does not hold these frames (below).
  * **TCP loses nothing in them.** The capped uploads on A at 800 Mbit/s stalled, yet 12 of 14 runs had no TCP retransmissions (C: 276–641 per run) and no ping was lost. One of the two exceptions is the run with the 1.36 s stall below.
  * **What it is not:** the radio's RX FIFO (`rx_fifo_full_cnt` did not move in a run with 54 stalls), or frames the laptop gave up (`tx failed` 0).
  * **A common tail up to 60–70 ms** is on every image and does not come from `0345`. It comes from the laptop's own background scans.
    * Under a capped upload 9–18 % of the pings take 10–60 ms: in the VO ping on both images and in C's ordinary ping.
    * At idle the p99 is ~40 ms.
    * **The scans:** `wpa_supplicant` on the laptop scans all 2.4, 5 and 6 GHz channels every ~15 s, for 2.5–6 s each time. Who requests them (most likely a desktop network applet) was not checked.
    * **A minute of idle pinging (`iw event -t` alongside):** every ping above 10 ms fell inside a scan, none outside, where the highest was 6.8 ms. During a scan the laptop leaves the channel for ~50 ms at a time, which both pings see.
    * At 400 Mbit/s A differs only in a little more of this tail in the ordinary ping: 7 against 3 per 1000 pings at 60–70 ms.
  * **Every stall of 80 ms or more falls inside a scan.** Checked on the 40 runs at 800 Mbit/s with WED on and off. Without scans there are no stalls.
  * **The router does not hold the frames.** This was checked with a debug build: image A plus counters and event rings in mt76's reorder code, 44 runs at 800 Mbit/s over three laptop connections and one more after a router reboot.
    * **No long holds.** There was no release by the reorder timeout and none by window overflow, in any run.
    * **How holes closed.** 151 514 holes closed within 20 ms (ordinary retransmissions). 756 frames waited 20–60 ms behind a hole, almost all of them during scans.
    * **Stalls without held frames.** 5 runs in which no frame was held for 20 ms or more still had 31 stalls of 80 ms or more; one of them had 12, up to 256 ms.
    * **No other cause matched.** No QoS Null, BlockAckReq, bypassed frame or driver drop matched a hole.
    * **Overhead.** The debug patch cost no measurable CPU or throughput.

    So the stalls come from the laptop. During a scan its ordinary (TID 0) queue waits out each off-channel dwell, and the ping waits behind the upload in that queue; the VO queue is separate.
  * **Why C had fewer of them: the laptop's TCP window.**
    * **The window.** With frames in order the window grows: 7.7–10.7 MiB in total over the 8 streams at 800 Mbit/s on A, against 3.5–5.1 MiB in 3 of 4 runs on C (iperf3's `max_snd_cwnd`). More of the upload then sits in the laptop's queue when a dwell begins.
    * **The test.** On A, in 6 alternating rounds, the same upload was made four ways:

      | Upload at 800 Mbit/s on A | Window, 8 streams | Stalls of 80 ms or more (6 runs) | Per second of scan | TCP retransmissions per run |
      |---|---|---|---|---|
      | TCP, default | 8.7–12.0 MiB | 35 | 1.17 | 0–1 |
      | TCP, `iperf3 -w 512K` | 6.0–6.1 MiB | 21 | 0.60 | 12–92 |
      | TCP, `iperf3 -w 256K` | 3.1–3.5 MiB | 1 | 0.03 | 252–467 |
      | UDP | — | 2 | 0.06 | (0.03 % lost) |

      Every run reached 800 Mbit/s, the time spent scanning was alike, and every stall fell inside a scan.
    * **The result.** The stalls follow the window. With C's window they disappear, and the small window pays instead with losses during the scans, as C did with its false losses.
    * **A separate effect.** Rare freezes of 216–297 ms hit a single TID while the other kept passing: 8 in 24 runs, in every way but UDP. The VO ones each followed one lost VO ping. Their cause is not known.
  * **Without WED the stalls are the same** (`wed_enable=N`, OpenWrt's default, which runs the same reorder code). The image was A throughout, with series alternating W1 → N1 → W2 → N2 → W3, a reboot before each except W1. Each series had 8 runs at 800 Mbit/s:

    | Series | WED | Stalls of 80 ms or more | Full-speed upload |
    |---|---|---|---|
    | W1 (up 3 h) | on | 50 (26/min) | 1369 Mbit/s |
    | N1 | off | 18 (9/min) | 1223 Mbit/s |
    | W2 | on | 18 (9/min) | 1233 Mbit/s |
    | N2 | off | 9 (5/min) | 1236 Mbit/s |
    | W3 | on | 52 (27/min) | 1428 Mbit/s |

    * **The same form.** With WED off the stalls peak at 92–103 ms and fall by ~11 ms per ping, the VO ping is not affected, and 10 of 11 runs with stalls had no TCP retransmissions.
    * **The rate.** Whether WED changes it is not decided. It varies 3× between series with WED on, and the two high series are also the two with the higher full-speed upload, at the same MCS and signal. This looks like a state of the link that changes from boot to boot; both WED-off series landed in the low state, which chance can explain.
      * The scan time was the same in all series, but in the high series the laptop's absences were longer. VO pings of 55 ms or more made 9–14 % of the VO pings above 20 ms, against 2 % in the others.
      * The cause of the state is not known.
  * **Isolated events:**
    * one stall of 1.36 s on A. Its run lost 5 pings and had 6110 TCP retransmissions, so this one did lose data, unlike the ~100 ms stalls. The VO ping was not affected;
    * one of 301 ms on C, also in the ordinary ping only. C has no reorder buffer on the router, so such stalls happen without `0345` as well.
* The idle runs of one series had stalls of ~110 ms that started within a second of the minute's 15th second, when a desktop service on the laptop queries Bluetooth: the laptop's Wi-Fi card shares its radio with Bluetooth.

**Decision:** keep `0345`. With it the throughput is the same, uploads have no false retransmissions, and the replay check of `3115dbc` works: it needs frames in order. The cost: while a heavy uploader scans in the background, its own traffic stalls for ~100 ms more often. At 800 Mbit/s that is about every 2–3 s, against every ~11 s on C; at 400 Mbit/s practically never. The router does not hold these frames; the stalls form in the client's own queue, because its TCP window grows when frames arrive in order (tested with capped windows and UDP). OpenWrt without WED behaves the same.

**Full vs L1 recovery (MT7915):**
* Full recovery (`echo 7 > /sys/kernel/debug/ieee80211/wl1/mt76/sys_recovery`) failed **both** on `fbd08ee272` and `d962f2553d`: `mt7915_mac_restart()` timed out on `PATCH_SEM` (`0x00000010`) and then `MCU_EXT_CMD(FW_LOG_2_HOST)` (`0x000013ed`) across all 10 attempts (`~104 s`), logging `chip full reset failed`, `mac80211` `WARNING` traces, and disabling `wl1-ap0` (`Out of memory` until reboot; `SYS_RESET_COUNT: WM 0, WA 1`). Recorded in `TODO.md`.
* L1 recovery (`echo 1 > /sys/kernel/debug/ieee80211/wl1/mt76/sys_recovery`): tested on `b0c4823bac` (`rc=0`, `SYS_RESET_COUNT: WM 0, WA 0`, `SER_STATUS = 0xfc000000`, `wl1` kept `ENABLED` at `853 Mbit/s` overall upload and `0 s` full outage).

**SCS on the 2.4 GHz radio** (channel 1, 10 clients, weakest at −61 dBm), measured on the new firmware by switching `/sys/kernel/debug/ieee80211/wl0/mt76/scs` at runtime, 2 minutes each, interleaved:

| | SCS off (old behaviour) | SCS on |
|---|---|---|
| Packet detection threshold (OFDM / CCK) | −98 / −110 dBm, fixed | mostly −74 / −78 dBm, back to the default for a moment every ~30 s |
| False CCA (CCK, per interval) | 1000–1700 | 130–490 |
| Channel busy (survey) | 27.1 % / 34.8 % | 14.8 % / 14.5 % |
| Receive time | 44.4 % / 43.3 % | 19.0 % / 19.1 % |
| Transmit time | 2.5 % / 3.1 % | 2.6 % / 2.6 % |
| Ping loss, sum over the 10 clients | 6 % / 13 % | 3 % / 0 % |

The radio no longer counts the noise of the busy 2.4 GHz band as a busy channel, so it waits less before sending. The threshold never goes above the weakest connected client (and −72 dBm); a far device that is not connected yet is only heard while the threshold is back at its default. If such a device has trouble joining the 2.4 GHz network, `echo 0 > /sys/kernel/debug/ieee80211/wl0/mt76/scs` restores the old behaviour until the next reboot.

**Not taken:** the whole mt76 HEAD needs mac80211 7.2 APIs (`ieee80211_txq_aql_pending()`, link-ID template getters) that OpenWrt main only builds on kernel 6.18. From mt76 master up to `41d5d1dd` (2026-11-20), `7474835` ("skip MT_TXD5_TX_STATUS_HOST for group frames") was reported for MT7663e (`!mt7615_firmware_offload()`, whereas MT7622 uses V2 N9 firmware with host PS buffering) and cannot be confirmed on closed MT7622 firmware from code alone; `3c17c4d` ("check the RX PN of CCMP-256, GCMP and GCMP-256 keys") needs the earlier `sta_key_conf` rework (`62694ed0b76f`); and `0241c2bd` ("remove a replayed station from the driver before the add") interacts with OpenWrt 25.12's `0067` `mt76_sta_add()` wcid check and was deferred alongside non-critical `mt7915`/`mt7615`/core commits (`8db5c6ac`, `0b28b7ac`, `55a65064`, `786d7663`, `eab677ba`, `41d5d1dd`, `b1d591bb`, `b2f1c7af`). The power-save buffering for MT7915 (`9a46d8d21d`, `9e613fb007`) is a behaviour change with little effect here: offloaded traffic from the WAN goes through WED past the driver, and only host-path frames to dozing 5 GHz clients would be affected. mac80211 fixes from Linux 6.18.56–58 (e.g. extension frame validation, oversized fragments, PS teardown) arrive with the next mac80211 update of 25.12, which happened every 2–3 months so far.

## 11. Wi-Fi ↔ LAN throughput and bridger

**Setup:** the laptop (Intel Wi-Fi 6, 2×2, HE160 on channel 100) about 1 m from the router at −45 dBm, link rate 1815–2268 Mbit/s to the laptop and 2402 Mbit/s from it. Two wired iperf3 servers, a PC on `lan1` and a mini-server on `lan2`, both at once with 4 streams each for 20 s (the first 2 s left out), so that no single gigabit port caps the sum; wired ↔ wired gives 931–941 Mbit/s. Router CPU per core from `/proc/stat`, the transmit/receive airtime of the station from `/sys/kernel/debug/ieee80211/wl1/netdev:wl1-ap0/stations/<mac>/airtime`. The `performance` governor was set for the comparisons, the configurations were switched at runtime and run interleaved.

**Before:** LAN → Wi-Fi reached ~1.2 Gbit/s with CPU1 at 94–99 % (~30 % softirq) and CPU0 at ~40 %. Packet steering pins the Ethernet NAPI threads to CPU0 and steers the `eth0` RPS to CPU1, where the bridge and the mac80211 transmit path run next to the `mt76-tx` worker and the TX completion NAPI of the 5 GHz radio, which are also pinned to CPU1. Wi-Fi → LAN reached 1.5–1.8 Gbit/s at ~80 % CPU, both cores loaded. One wired source alone gives at most ~940 Mbit/s, so earlier single-source tests could not show this limit.

**Packet steering modes**, without bridger (Mbit/s, two runs of 2 and 3 rounds):

| | mode 1 (default) | mode 2 (RPS to both CPUs) | mode 0 (no pinning, no RPS) |
|---|---|---|---|
| LAN → Wi-Fi | 1193–1298 | 1287–1335 | 1323–1337 |
| Wi-Fi → LAN | 1574–1804 | 1531–1774 | 1602–1754 |

Modes 2 and 0 give LAN → Wi-Fi 6–11 % more, Wi-Fi → LAN does not change. Mode 1 stayed at first, as bridger takes the LAN → Wi-Fi direction off the CPU entirely; after bridger went off by default and a check with several clients, mode 2 became the default ([section 13](#13-packet-steering-mode-2-and-the-operating-modes)).

**bridger** (OpenWrt's bridge accelerator by Felix Fietkau) attaches a BPF program to the bridge ports, learns which pairs of hosts exchange traffic and installs a `tc flower` rule per MAC pair that the `mtk_eth` driver turns into a PPE L2 flow; towards the MT7915E the PPE hands the packets to WED, past the CPU. The version in OpenWrt 25.12 (2025-10-23) offloaded nothing here:
* on a bridge without VLAN filtering the kernel still keeps the default VLAN 1 entry of every port, and the forwarding check looked up VLAN 0 in that table, so no flow was ever created (a temporary `echo 0 > /sys/class/net/br-lan/bridge/default_pvid` worked around it; fixed upstream in `de7e00a`, 2026-03);
* the switch port (`lan1`) refuses the `skip_sw` rule with `EOPNOTSUPP`, but the error callback returned `NL_SKIP` for errors without an extended ACK message, so the refusal looked like a success and the conduit `eth0`, where the PPE takes the very same rule, was never tried (fixed upstream in `7a0d64f` and `2a2d126`, 2026-09). A manual `tc filter add dev eth0 ingress … flower skip_sw indev lan1 … action mirred egress redirect dev wl1-ap0` was offloaded at once: 929 Mbit/s at 6 / 18 % CPU.

The build therefore updates bridger to Git HEAD 2026-09-17. Then a kernel bug showed up: OpenWrt's pending `736-03` clears the parent L2 flow in `mtk_flow_entry_update_l2()` when one of its subflows is no longer bound, instead of that subflow. Test: a long 50 Mbit/s TCP stream between the PC and the laptop, a full-speed transfer between the same hosts, then two more 20 s apart:

| | first transfer | second | third |
|---|---|---|---|
| without the fix | 5 / 17 % CPU, in the PPE | 25 / 69 %, on the CPU | 24 / 71 %, on the CPU |
| with `976` | 4 / 16 % | 6 / 17 % | 6 / 16 % |

Without the fix the hardware byte counter of the rule stopped as well: even the long stream had left the PPE.

**Result** on the test firmware (bridger 2026-09-17 + `976`), 3 interleaved rounds; the UDP row is one 500 Mbit/s stream from the PC to the laptop with 100 pings/s from the laptop to the mini-server meanwhile (Wi-Fi power save of the laptop on):

| | mode 1 | mode 2 | bridger + mode 1 | bridger + mode 2 |
|---|---|---|---|---|
| LAN → Wi-Fi TCP, Mbit/s | 1193–1298 | 1287–1331 | 1174–1323 | 1143–1344 |
| router CPU (both cores) | 67–76 % | 77–79 % | **8–9 %** | **7–8 %** |
| Wi-Fi → LAN TCP, Mbit/s | 1574–1804 | 1531–1709 | 1539–1760 | 1502–1782 |
| router CPU | 78–86 % | 80–83 % | 65–75 % | 68–72 % |
| UDP 500 Mbit/s LAN → Wi-Fi: CPU | 32–33 % | 33–38 % | **10–11 %** | 11–12 % |
| ping meanwhile, median / p99 | 3.3–3.5 / 17–26 ms | 3.1–3.2 / 16–28 ms | 3.5–3.7 / 18–21 ms | 3.7–3.9 / 23–52 ms |

With bridger the LAN → Wi-Fi throughput stays the same: the station's transmit airtime is ~85 %, so the radio link is the limit, not the CPU. Wi-Fi → LAN is unchanged, as expected without WED RX. Latency with a saturating download (one wired PC → laptop, 4 TCP streams, ~937 Mbit/s, 100 pings/s to the mini-server): median / p99 5.6–6.3 / 24–36 ms without bridger, 4.8–5.6 / 22–31 ms with it, so with one client the bypassed mac80211 queues cost nothing in this test. These single-client latency runs had the laptop's Wi-Fi power save on, which adds its own delay; with it off and with several clients the hardware path does cost latency and fairness, see [section 12](#12-several-wi-fi-clients-latency-and-wed). **Decision:** bridger is in the image but off by default.

**Functional checks with bridger** (a UDP stream from the PC to the laptop, the event in the middle):
* client reconnect (hostapd deauthenticates the laptop during a 20 Mbit/s stream): data flows again 1–2 s later, in a new hardware rule; 4 s without bridger. Disconnecting and reconnecting on the laptop (`nmcli device disconnect/connect`): back 5 s later;
* band change of the client (5 → 2.4 → 5 GHz): the rule goes away as the client leaves 5 GHz, the stream continues over the CPU on 2.4 GHz 5 s after the switch (the time to reassociate), and gets a new hardware rule 2 s after the return to 5 GHz;
* `wifi` restart during a transfer: back after ~15 s, again in hardware;
* `/etc/init.d/firewall reload` during a 200 Mbit/s stream: one second at 176 Mbit/s, 0.5 % loss; `/etc/init.d/network reload`: no effect;
* `kill -9` of bridger: procd restarts it after ~5 s, the stream keeps flowing. This showed a bridger bug: the rule of the killed instance stayed on `eth0`, and the new instance did not know it. When the client then moved to 2.4 GHz, the PPE kept sending its stream to `wl1-ap0`: 44 s without traffic until the client came back to 5 GHz. At startup bridger removes the rules an earlier instance left behind, but it attaches a bridge port before it looks up the port's offload device, so `eth0` was never cleaned. `package/network/services/bridger/patches/100-…` looks the offload device up first; with it the new instance replaces the rule within 2 s and the band change works;
* 128 parallel UDP streams from the PC to the laptop (the laptop's iperf3 3.16 crashed with more): ~900 Mbit/s, the port limit, 208 bound PPE entries, CPU 6 / 56 %, so part of the traffic stays on the CPU with that many flows; a WAN download to the laptop meanwhile was counted by nlbwmon at 105 % (headers), as without bridger;
* traffic from the router itself to the laptop (iperf3 server on the router): 855–880 Mbit/s with and without bridger;
* clients on 2.4 GHz (the MT7622 WMAC has no WED) get no hardware rule, their traffic stays on the CPU path; all 10 clients of the 2.4 GHz radio stayed connected and active;
* WAN downloads are not affected (~500 Mbit/s, the ISP limit, at 11 % CPU, PPE entries from the flowtable as before);
* 5 minutes of alternating full-speed LAN ↔ Wi-Fi transfers: no kernel warnings, bridger keeps running.

**bridger `4b63ed4` (2026-10-29).** Git HEAD 2026-10-27 adds `76dbaa8`: when a client's FDB entry goes away or moves to another port, bridger removes the client's BPF redirects and hardware rules at once. Before, they stayed in place until the entry's flows expired. The checks above, repeated with `4b63ed4` + `patches/100-…`:
* client reconnect (hostapd) during a 2-stream TCP transfer to the laptop: the transfer dips only while the client reassociates and continues in a new hardware rule;
* `wifi` restart: back after ~10 s, in hardware;
* `kill -9` of bridger during a 200 Mbit/s UDP stream: no loss beyond normal (0.08 %), the new instance replaces the rule.
* band change of the client (5 → 2.4 → 5 GHz) during a 30 Mbit/s UDP stream: the rule goes away as soon as the client leaves 5 GHz, and the return gets a new hardware rule in the second the client associates, against ~2 s with `2a2d126`. The stream stops only while the laptop is associated with neither radio (~10 s and ~5 s here).

Router CPU per core during a 2-stream TCP transfer from the PC to the laptop (~910–940 Mbit/s), with the governor of the *Maximum throughput* mode (`performance`), 3 interleaved rounds:

| | `4b63ed4` | `2a2d126` | no bridger |
|---|---|---|---|
| CPU0 / CPU1 | 2–3 % / 10–14 % | 3–4 % / 11–14 % | 32–52 % / 53–69 % |

With `schedutil` (the *Balanced* mode, which does not turn bridger on) one core was 44–53 % busy with either version. The network work itself was ~10 % (`napi/phy1`, `mt76-tx`). Most of the rest was the governor's own thread `sugov:0`, ~22 % of a core, see [section 5](#5-cpu-frequency-governor).

**Pitfalls:**
* `iw dev wl1-ap0 station del <mac>` removes the station behind hostapd's back: the client reassociates within 2 s but passes no traffic for about a minute, with or without bridger. Use `ubus call hostapd.wl1-ap0 del_client '{"addr":"<mac>","reason":3,"deauth":true,"ban_time":0}'`.
* sysupgrade keeps services that were disabled before the upgrade disabled (`/etc/uci-defaults/10_disable_services`), so a router that had `bridger` disabled during tests comes up without it: `/etc/init.d/bridger enable; /etc/init.d/bridger start`.
* The fixed-rate UDP test keeps the airtime at ~85 % even at 500 Mbit/s: paced packets leave in short A-MPDUs. Airtime is only a capacity measure when the link is saturated.

## 12. Several Wi-Fi clients, latency and WED

**Setup:** three 5 GHz clients: the laptop as a VR headset (2×2 HE160, ~1 m, Wi-Fi power save off), an Android TV box (Ugoos AM8, Android 14, 2×2 HE80, −48 dBm, link rate 865–907 Mbit/s) and a phone (2×2 HE160). Sources: the mini-server sends to the laptop, a PC to the TV box and the phone. "VR" is a 200 Mbit/s UDP stream to the laptop plus 100 pings/s from the laptop to the mini-server. 3 interleaved rounds per configuration, `schedutil` governor; airtime per station from mac80211's debugfs.

**Bulk TCP to several clients** (the phone's iperf3 app takes one stream, the others four):

| | bridger on | bridger off |
|---|---|---|
| laptop + TV box | 892–930 Mbit/s, CPU 23–25 % | 910–965 Mbit/s, CPU 55–59 % |
| laptop + TV box + phone | 580–630 Mbit/s; phone 61–129; laptop 36–48 % of the airtime | 790–810 Mbit/s; phone 228–270; 24–36 % of the airtime each |

Without bridger mac80211's airtime scheduler shares the air evenly and every client sends large aggregates. On the hardware path the laptop took up to half of the airtime for less throughput, and the single-stream phone was nearly starved.

**VR stream with background traffic** (loss / ping median / p99 / max):

| Background | bridger on | bridger off |
|---|---|---|
| none | 0.02–0.75 % / 3.0–3.7 / 18–33 / 40–74 ms | 0.06–0.15 % / 1.7 / 7–10 / 16–35 ms |
| TV box 40 Mbit/s from the LAN | 0.08–0.27 % / 3.0–3.4 / 25–47 / 69–112 ms | 0.01–0.49 % / 2.1–2.2 / 13–16 / 27–38 ms |
| TV box 48 Mbit/s from the internet (WED) | 0.16–0.35 % / 3.6–3.9 / 33–39 / 59–91 ms | 0.25–0.94 % / 2.0–2.2 / 20–68 / 39–140 ms |
| TV box 200 Mbit/s + phone 30 Mbit/s from the LAN | 0.9–3.8 % / 4.6–5.6 / 22–160 / 38–385 ms | 0.8–2.2 % / 3.5–3.8 / 16–19 / 28–31 ms |
| TV box at full speed from the internet (~300 Mbit/s) | 0.8–4.6 % / 5.5–6.4 / 62–75 / 129–170 ms | 0.8–1.6 % / 5.2–7.8 / 52–102 / 89–385 ms |
| TV box at full speed from the LAN (~600 Mbit/s) | 2.0–3.2 % / 9.0–10.6 / 61–114 / 125–205 ms | 2.2–15 % / 9.0–10.9 / 44–98 / 97–253 ms |

Even alone, the stream on the hardware path had twice the median latency and used 84–85 % of the airtime instead of 69–70 % for the same 200 Mbit/s: frames go to the firmware as they come instead of being aggregated in mac80211's queues. A client downloading at full speed next to the VR stream hurts in every configuration.

**DSCP EF** on the VR stream and the pings (WMM voice), the TV box at full speed from the LAN: the ping p99 fell to 11–16 ms in both modes. Only without bridger did the stream itself get priority: its share of the airtime rose from 17 % to 31–45 % and the TV box yielded. With bridger its share stayed at 20 %, so the hardware path ignores WMM priority, and only the pings, which stay on the CPU path, benefited.

**WED off** (`wed_enable=N`, bridger off), same tests:

| | WED on | WED off |
|---|---|---|
| WAN → laptop, 4 downloads | 571–583 Mbit/s, CPU 17 / 55 % | 578–602 Mbit/s, CPU 24–27 / 70 % |
| VR alone | 0.06–0.15 % / 1.7 / 7–10 / 16–35 ms | 0.01–0.04 % / 1.6–1.7 / 6–7 / 12–20 ms |
| VR + TV box 48 Mbit/s from the internet | 0.25–0.94 % / 2.0–2.2 / 20–68 / 39–140 ms | 0.02–0.13 % / 2.1–2.2 / 21–27 / 36–123 ms |
| VR + TV box at full speed from the internet | 0.8–1.6 % / 5.2–7.8 / 52–102 / 89–385 ms | 0.3–2.4 % / 4.2–4.5 / 32–44 / 55–84 ms |

This comparison was not equal: the WED-on runs were made ~3.5 h after a boot, the WED-off runs right after one. The household runs below alternate WED on → off → on with a reboot before each block, and they show a much smaller difference. The CPU handles the ISP's 600 Mbit/s without WED with headroom; on a gigabit plan it would likely limit the WAN → Wi-Fi speed.

**A household evening:** the laptop as a gamer on Wi-Fi pings 1.1.1.1 at 50/s for 60 s, and the wired PC pings it too. The TV box plays "4K" the way streaming apps do: 10 MB at full speed from the internet every 4 s, ~16 Mbit/s on average. The phone lies asleep. "VR" adds the 200 Mbit/s stream, with the laptop pinging the mini-server. Blocks WED on → off → on, 2 rounds each; gamer p99 / max:

| | WED on | WED off | WED on again |
|---|---|---|---|
| quiet | 12.4–13.4 / 15 ms | 11.4–13.0 / 15 ms | 11.2–12.7 / 15 ms |
| evening (TV box 4K) | 13.9–14.0 / 22–25 ms | 12.9–13.2 / 15–19 ms | 13.6–13.7 / 21 ms |
| TV box downloading at full speed from the internet | 30–42 / 62–88 ms | 26.5–26.9 / 45–46 ms | 30 / 58–59 ms |
| VR evening (headset ping, stream loss) | 7.8–10.6 / 18–42 ms, 0.04 % | 8.4–8.7 / 20–50 ms, 0.04–0.11 % | 6.2–6.9 / 24–26 ms, 0.01–0.11 % |
| CPU during the full-speed download | 31–32 % | 37–40 % | 30–33 % |

An ordinary evening leaves no trace with either setting. WED off only helps while another Wi-Fi client downloads at full speed, and only a little. The wired gamer was unaffected in all runs (p99 10–14 ms). An earlier series of the same test was spoiled by a real phone in use next to it: short videos loading in full-speed bursts raised the gamer's p99 to 45–121 ms in one block.

**Side findings:**
* With `schedutil`, the `sugov:0` thread (frequency changes) takes ~20 % of a core under a steady 200 Mbit/s stream, so light loads show more CPU than with `performance`. In §11, `performance` was set; in this section, `schedutil`.
* TCP to the TV box costs ~46 % of one core even when the data goes through the hardware path. The box's ACKs (Wi-Fi → LAN) take the CPU path, and it acknowledges more often than the Linux laptop.
* The TV box drops off the Wi-Fi for a second now and then by itself (also on the stock firmware); it did not happen during these runs.

**Decision:** bridger is installed but off by default (`99-custom-settings`, once per configuration). It pays off only for bulk transfers to a single busy client (e.g. from a NAS) and costs latency and fairness otherwise. WED stays on: in a household it makes no noticeable difference, and gigabit plans need it. WED off is for those who want the last few milliseconds next to big downloads. These choices became the operating modes of [section 13](#13-packet-steering-mode-2-and-the-operating-modes).

## 13. Packet steering mode 2 and the operating modes

**Setup:** mode 2 gave more LAN → Wi-Fi throughput in §11, but its latency had been measured with one client only and with the laptop's power save on. So it was checked again with the household tests of §12 and two busy clients: the laptop 4–5 m from the router (line of sight, −52 dBm, HE-MCS 10/11, power save off), the TV box, the phone off the Wi-Fi; bridger off, WED on, `schedutil`. The modes were switched at runtime, one round each.

| | mode 1 | mode 2 |
|---|---|---|
| quiet: Wi-Fi gamer p99 / max | 12.8 / 17 ms | 11.9 / 14 ms |
| evening (TV box 4K) | 13.7 / 21 ms | 13.6 / 22 ms |
| TV box downloading at full speed from the internet | 33 / 70 ms | 32 / 85 ms |
| VR evening: headset ping p99 / max, stream loss | 12.5 / 77 ms, 0.15 % | 9.7 / 34 ms, 0.03 % |
| VR alone: stream loss, ping median / p99 | 0.37 %, 1.5 / 6.8 ms | 0.07 %, 1.6 / 9.4 ms |
| bulk TCP to the laptop and the TV box, per-core CPU | 1013 Mbit/s, 36 / 85 % | 979 Mbit/s, 51 / 72 % |
| VR next to the TV box at full speed from the LAN: stream loss, ping p99 | 3.3 %, 156 ms | 4.9 %, 58 ms |

Mode 2 is no worse: the differences are within the spread of single runs, and the load is shared more evenly between the cores. With SQM mode 1 is the best of the three (§9).

**Decision:** packet steering mode 2 is the default except with SQM. The settings that depend on how the router is used are combined into operating modes: LuCI → *System → Operating mode* (`luci-app-tuning`) or the `tuning` command.

| Mode | Flow offloading | WED | bridger | Packet steering | Governor | SQM | Based on |
|---|---|---|---|---|---|---|---|
| Balanced (default) | hardware | on | off | 2 | `schedutil` | off | §12: a household evening looks the same with every setting; §5: `schedutil` saves energy |
| Maximum throughput | hardware | on | on | 2 | `performance` | off | §11: wired → 5 GHz at ~8 % CPU instead of ~70 % |
| Low latency | hardware | off | off | 2 | `performance` | off | §12: lower p99 next to full-speed downloads; §5: lower idle latency |
| SQM | software | off | off | 1 | `performance` | on | §9: software offloading and mode 1 are the best SQM setup; WED is unused without hardware offloading, and bridger needs WED |

The page applies a mode with a reboot: WED is a module parameter anyway, and one rule is simpler than settings that apply at different times. The `tuning` command applies everything but WED at once and reports when a reboot is needed.

## 14. zapret and flow offloading

**Setup:** users of the build run [zapret](https://github.com/bol-van/zapret) to get around DPI blocking, mostly through Zapret Manager, which installs the packages of [remittor/zapret-openwrt](https://github.com/remittor/zapret-openwrt). Tested on r13 (25.12.6, Linux 6.12.112) with zapret v72.20260307 and its default settings: nftables, hostlist mode, `FLOWOFFLOAD=none`; the first 9 packets of each TCP connection to port 443 go to `nfqws` through a queue in the postrouting hook (`ct original packets 1-9`); for `discord.com` the strategy sends a fake ClientHello for `rzd.ru` (`hostfakesplit`) before the split real one.

**Method:** the provider of the test setup blocks nothing, so the question was whether `nfqws` gets to modify the ClientHello, not whether a site opens. One HTTPS request to `discord.com` (pinned to 162.159.137.232) per run; `tcpdump` on `wan`, filtered to that address, counts the fakes with `rzd.ru` (two per processed connection). Clients: the laptop on 5 GHz Wi-Fi and a PC on `lan1`. Three runs per cell; the firewall was reloaded after each change.

| Flow offloading | fw4 offload rule | Wi-Fi client | Wired client |
|---|---|---|---|
| hardware (*Balanced*, *Maximum throughput*, *Low latency*) | as shipped | 3/3 | **0/3** |
| software (*SQM*) | as shipped | **0/3** | — |
| none | — | 3/3 | 3/3 |
| software | `ct original packets ge 30 flow offload @ft` | 3/3 | 3/3 |
| hardware | `ct original packets ge 30 flow offload @ft` | 3/3 | 3/3 |

* With flow offloading, fw4 adds a connection to the flowtable once its handshake is done, and the packets of a connection in the flowtable no longer pass the postrouting hook where zapret queues them. The ClientHello of a Wi-Fi client still got through with hardware offloading (its fast path starts later; not investigated further), that of a wired client did not.
* With the rule changed to offload a connection only after its first 30 packets (the change Zapret Manager makes by itself), zapret processed every connection, and bulk traffic stayed in the hardware: a wired 1 GiB download ran at ~450 Mbit/s with the CPU 90 % idle and bound PPE entries.
* Switching the operating modes with `tuning set` (throughput, sqm, lowlatency, balanced) kept zapret running: its rules are in their own table `inet zapret`, which the firewall reload does not touch; only the software offloading of the *SQM* mode stopped the ClientHello from reaching `nfqws`.
* Zapret Manager 5.004 (installer `ZapretManager_LuCI.sh`, zapret installed with its panel action) installed `unzip` from the repository and zapret with its dependencies, and changed the fw4 rule to the 30-packet form by itself. With its strategy v7 (fakes carrying `stun.bin` for every HTTPS host not excluded) zapret processed the ClientHello for wired and Wi-Fi clients in all four modes, 2/2 each; only the first connection within a second of switching to *Maximum throughput* (bridger starting) went unprocessed, the following ones were processed.
* A real update with *Keep my packages* (`fwupdate-packages request` and `sysupgrade` of the r13 release, as the update button does) kept `/etc/config/zapret`, the zapret lists under `/opt/zapret`, the backups of Zapret Manager (its `/lib/upgrade/keep.d` entry) and its cron jobs, which then call a missing script until it is installed again. The restore installed `unzip` again and listed `zapret` and `luci-app-zapret` as packages to install by hand. Zapret Manager and zapret then installed again without problems, the fw4 rule was changed again, and zapret worked for both clients; Zapret Manager set its base strategy again.
* The kernel did not log the `pskb_expand_head()` warning of patch `978` during these tests.
* Steer of Zapret Manager (its own proxy engine) did not install: `steer-core` depends on `ip-full`, and the image had `ip-tiny` in its world (pulled in by `sqm-scripts` and `ddns-scripts`), so apk refused the swap. `apk add ip-full '!ip-tiny'` fixes it; with `ip-full` in the seed, `make defconfig` drops `ip-tiny` and keeps both dependants. The AmneziaWG module that Steer adds for WARP matches the kernel of the build (same `kernel=` dependency and vermagic).

**Decision:** hardware offloading stays the default. The README gets a section for zapret users with the 30-packet rule (Zapret Manager applies it itself), and the seed selects `ip-full` instead of `ip-tiny` (+77 KiB package). Changing the fw4 rule for everybody was not done: it would send the first 30 packets of every connection through the CPU on routers without zapret.

## 15. PPPoE through the router (lab)

**Setup:** the owner's WAN is DHCP, so PPPoE ran on a lab link: a PC as PPPoE server (rp-pppoe `pppoe-server -k`, Debian pppd 2.5.5) in a container whose only interface is a macvlan of its NIC, so the server address 10.99.0.1 exists only behind the session. On the router a temporary interface `ppptest` (proto pppoe on `br-lan`, its own masquerading zone, forwarding from `lan`); the PC's LAN side is the client, so every packet crosses the router's NAT and the PPPoE session. Image of 2026-11-21 (`pppoe/backports`: kernel `979`–`987`, ppp 2.5.5, `ppp6-up`, the netifd patches), *Balanced* mode, `schedutil`. The PPPoE frames go through the bridge to `lan1`, not through the `wan` port, so the PPE path is close to, not the same as, a PPPoE WAN.

**Results:**

| Test | Result |
|---|---|
| Login with PAP, CHAP, MS-CHAP, MS-CHAPv2 (pppd 2.5.5 on both sides) | all four up |
| iperf3 download / upload, hardware offloading | 891 / 929 Mbit/s, router CPU 5–10 %, the flow `[HW_OFFLOAD]` |
| iperf3 download / upload, software offloading | 880 / 752 Mbit/s, CPU about 50 % |
| iperf3 download / upload, no offloading | 767 / 883 Mbit/s, CPU 45–75 % |
| 8 parallel HTTP clients for 180 s (1 MiB per connection) with the server ending the session with PADT every 15 s | 15,859 connections (88/s, ~740 Mbit/s); the ~75 failures fell into the 10 reconnects; a ping from the router every second missed one second per reconnect and nothing else; no kernel message |
| Server link down for 12 s | "No response to 5 echo-requests" after 5 s (default keepalive `5 1`), new session as soon as the link was back |
| sysupgrade with the session up, r15's netifd | no Terminate-Request, no PADT: the router fell silent |
| sysupgrade with the session up, with the netifd patches | Terminate-Request 4 s after the start, Term-Ack, PADT |
| Path MTU and MSS through the session (`mtu_fix` on the zone) | 1492-byte packets with DF pass, 1493 get "Frag needed (mtu 1492)" from the router; the server sees MSS 1452 in both SYNs |
| `ipv6 auto`, then `ipv6 auto` plus an own dhcpv6 interface on `@ppptest` | `ppptest_6` added; with the own interface `ppp6-up` logs "not adding ppptest_6" and one odhcp6c runs on the link. While the `ppptest_6` of the first run was still up, adding the own interface looped ("ubus error: Invalid argument") for about a second, until the session reconnected |
| SQM (CAKE, 100/100 Mbit/s) on `pppoe-ppptest`, software and no offloading | both directions shaped to 96 Mbit/s in both modes, the download through `ifb4pppoe-ppptest`, although the connection was `[OFFLOAD]` |

The SQM result did not carry over to a PPPoE WAN: the flowtable has `br-lan` and `wan` as devices, and here the PPPoE frames arrive through the bridge, where the fast path did not take the download, while on a PPPoE WAN they arrive on `wan` itself (see the bench below).

On the same image with the owner's DHCP WAN and hardware offloading, nothing else changed against r15: an official kmod (`kmod-dummy`) loads, a 100 MiB download through the PPE counts 104.99 MiB in nlbwmon on both (headers included), and PPE entries go away as before. Closed connections now stay `[OFFLOAD]` in conntrack for about 30 s and then CLOSE (10 s), where r15 put them in TIME_WAIT (120 s) at once: that is the CLOSING state of `986`.

**PPPoE WAN on the `wan` port (bench):**
- **Setup.** A PC sits in line between the ONT and the router:
  - the ISP's DHCP on a USB 3.0 NIC (ASIX AX88179) that carries the router's WAN MAC, and NAT;
  - accel-ppp (git `7054287`) in a container on its onboard NIC, cabled to the router's `wan`, with CHAP, an IPv4 pool, and IPv6 prefixes delegated from a ULA /40.
- **The router.** `wan` is PPPoE with `ipv6 auto` and `wan6` as dhcpv6 on the device `wan`, the layout of the 4PDA report of 2026-11-20. It runs the same image.
- **Clients.** A laptop on 5 GHz, with an iperf3 and an HTTP server behind the session at 10.99.0.1. The home network's own traffic went through the bench too.

| Test | Result |
|---|---|
| Operating modes, iperf3 download / upload for 12 s | *Balanced* 711 / 633 Mbit/s, *Throughput* 760 / 741, *Low latency* 802 / 857. The flows are `[HW_OFFLOAD]` and bound in the PPE. CPU idle during the download: 90 / 85 / 50 %; during the upload 21–30 % (it comes in over Wi-Fi). After the reboot that *Low latency* needs for WED, the session came back by itself |
| nlbwmon accounting: a 1 GiB HTTPS download from the internet through the PPE | 1,141,925,753 bytes counted (106 % of the payload, headers included), one bound PPE entry, CPU 85 % idle |
| *SQM* mode, CAKE 200/100 Mbit/s, SQM on `pppoe-wan` (before the fix) | download 763 Mbit/s: `ifb4pppoe-wan` saw 27 packets, because the fast path took the offloaded download at the netfilter ingress of `wan`, before `pppoe-wan`. Upload 85.5 Mbit/s |
| The same with SQM on `wan` (`network.wan.device`) | download 170 Mbit/s, upload 91.3, connections still `[OFFLOAD]`: tc ingress of `wan` runs before the flowtable hook. `luci-app-tuning` now does this |
| Path MTU | 1492-byte packets with DF pass; 1493 get "Frag needed (mtu 1492)" from the router |
| 10 reconnects (server PADT every 15 s) under 8 parallel HTTP clients | about 78,000 connections, 80 failed (one per client and reconnect). A probe every second failed for about 3 s per reconnect. A new address each time |
| 5 more reconnects, PPE checked every second | the 6 entries of the old address were gone 1 s after the session dropped; none was left after the new session came up |
| IP traffic dropped by the server for 3 and for 7 minutes, LCP still answered | pppd and `wan` stayed up, as in the 4PDA report. Ping and DNS came back within 4 s of the traffic, without restarting `wan`. During the 7 minutes https-dns-proxy exited 50 times with the c-ares error in TODO.md, and procd restarted it each time (`retry 0`). A cached name resolved for the first 4 minutes |
| `ipv6 auto`, `wan6` on `wan` | `wan_6` up, /56 delegated, the LAN got a /60 from it, the laptop got addresses and the route by RA. A client's IPv6 traffic through the session was not tested: the lab prefixes are ULA, and odhcpd then announces no default route |
| `wan6` moved to `@wan` | `ppp6-up` logs "interface wan6 runs DHCPv6 on this link, not adding wan_6"; one odhcp6c runs on `pppoe-wan`; no new ubus errors in 10 s; a new /56 is delegated |
| The server's link drops the session frames from the router (PPPoE ethertype) for 15 s, three times | "No response to 5 echo-requests" after 11–13 s: with adaptive echo pppd waits while frames still arrive from the server. The new session came up 4–5 s after the link was back, 21–22 s without internet in all. No PPE entry of the old address was left, no kernel message |
| The same for 70 s | The server dropped the stale session itself after 30 s. The router had its new session 1 s after the link was back (72 s without internet) |
| sysupgrade, server with `single-session=deny` that drops a silent session after 30 s (LCP echo 10 s x 3) | With the netifd patches: Terminate-Request and PADT 3.6–4.2 s after the start, no rejected login after the boot, WAN up after 59–68 s. r15 sent nothing, but the server had dropped the session before the router's first PADI, so the 30 s server hides the difference |
| The same, server drops a silent session after 150 s (LCP echo 30 s x 5) | **r15 → r15:** 46 logins rejected ("second session denied") over 153 s, WAN up after 215 s. **r15 → test image** (r15's netifd runs the sysupgrade): 38 over 127 s, 191 s. **Test image → r15 or test image:** Terminate-Request and PADT after about 4 s, no rejection, 60–68 s. This is the "PPPoE authentication error after updating" of r10 |
| IPv6 of a client (the laptop routed to the server's ULA by hand) | 658 Mbit/s up, 600 down, `[HW_OFFLOAD]`, bound IPv6 PPE entries |
| Internet through the router, to a speedtest server about 10 ms away (`speedtest-go` 1.7.10, 12–16 connections) | download from the laptop 509–588 Mbit/s, from the PC directly 566–586, from the router itself 546–585 (36–83 % idle): the tariff of about 600 at two servers. The upload figures of `speedtest-go` contradicted each other and are left out |
| Internet to a CDN 10 ms away, 8 and 1 TCP streams, PPPoE and DHCP WAN in the same hour | laptop 395–464 Mbit/s (PPPoE) and 394–477 (DHCP) with 8 streams, 188–281 with one; the PC directly 590 and 518. The router 64–100 % idle with all flows in the PPE |
| Where the TCP streams lose: netem on the server, counters on every hop | 1 stream 651 → 257 → 125 Mbit/s at 0, 10 and 40 ms, 8 streams 710 → 410 → 265. No drop on the PC, on the router's `wan`, `eth0` (ethtool), `softnet_stat` or the Wi-Fi qdisc. 0.6–1 % of the packets got lost between the router's `wan` and the laptop's Wi-Fi (4,451–5,379 per 12 s, as many as the server retransmitted), along with 92–111k `tx failed` of the 5 GHz station |

**zapret2 over the PPPoE WAN.** Zapret Manager 5.089 with `zapret2` 1.0.7 and its defaults:
- **The 30-packet rule** of section 14 is applied by Zapret Manager itself.
- **The defaults** are `MODE_FILTER=none` and `POSTNAT=1`, and they queue TCP 80, 443, 853, 1024–65535 and UDP 53, 80, 88, 443, 1024–65535.
- **Strategies on by default.** `games_tcp` and `games_udp` are among them. `games_udp` sends 10 fake STUN packets for each of the first packets of every UDP flow to almost any port above 1024.
- **Targets.** The bench server got an address outside zapret's `nozapret` set (RFC 1918 and link-local) for these tests.

| Test | Without zapret2 | With zapret2 |
|---|---|---|
| 8 HTTP clients, 1 MiB per connection, 120 s | 76 connections/s, router 60–78 % idle | 70/s, 20–52 % idle, `nfqws2` 0–5 %, no queue drop |
| iperf3, 3 runs back to back | 580–715 / 329–798 Mbit/s | 549–678 / 363–772 Mbit/s, flows `[HW_OFFLOAD]` |
| New UDP flows, 3 packets each, 200/s | 593 packets/s on `wan`, ping max 26 ms | 6,484 packets/s (x10.9), ping max 103 ms |
| The same, 500/s | 1,472 packets/s, 65–69 % idle, ping max 28 ms | 16,107 packets/s, 13–60 % idle, `nfqws2` 20–35 %, ping max 113 ms |
| The same, 1,000/s | 2,942 packets/s, conntrack full (32,768) | 25,662 packets/s, `nfqws2` 43–48 % (one core) and 56 MB, 1,343 packets waiting in its queue, conntrack full |

Bulk traffic does not suffer. Many new UDP flows, as with torrents, multiply the packets on the WAN and add latency.

**Decision:** the PPPoE backports and the SQM fix go into the next release.
- The sysupgrade fix belongs in netifd, not in stage2: procd stops every service, netifd included, before stage2 runs.
- On this bench the router passes the tariff over PPPoE, the same as over DHCP. What limits single TCP streams over 10 ms and more is a loss of 0.6–1 % on the 5 GHz link (TODO.md).
- Still to test: a real ISP ([TODO.md](TODO.md)).

## 16. Automatic channel selection, on-demand L2TP, and update-check limits (from the A5 v4 build)

**Ported on 2026-11-22** from [openwrt-archer-a5v4-c50v4](https://github.com/Dreyk007/openwrt-archer-a5v4-c50v4/blob/a5v4-25.12/RESEARCH.md) (see its sections 12, 17, and 19 for the long measurements on MT7628/MT7612E):

- **ACS fixes and presets:** `mt76` `0329` (`mt76_sw_scan()` calls `mt76_update_survey(phy)` under `dev->mutex` and zeroes `main_chandef.chan`'s `chan_state` under `dev->cc_lock`), `hostapd` `471` and `472`, LuCI feed patch `0003` (DFS and channels 12–13 checkboxes, hiding the DFS box at 160/320 MHz while keeping stored values via `retain = true`), `99-custom-settings` (`ax3200.defaults.acs`: 2.4 GHz `channels '1-11'`, `acs_chan_bias '1:0.6 6:0.6 11:0.6'`, `acs_num_scans=2`; 5 GHz `acs_exclude_dfs '1'`, `acs_num_scans=1`, `min_tx_power=15` skipped when `min_tx_power` or `hostapd_options` `min_tx_power=` is already set), and `wifi-scripts` (`hostapd.uc`: drops `acs_exclude_dfs` for `VHT160`/`HE160`/`EHT160`/`EHT320`).
- **On-demand L2TP:** `xl2tpd` feed patch `0004` (`boot() { return 0; }`) and `AUTOLOAD` removed from `kmod-l2tp` and `kmod-pppol2tp` in `netsupport.mk`.
- **Update check limits (`luci-app-fwupdate`):** wall-clock deadline (`DOWNLOAD_TIME = 840` s < `STALE = 900` s) and `uclient-fetch` failure logging (`fetch_detail`).

**Setup on the router** (Redmi AX6S, 256 MB, `mt7615e` `wl0-ap0` + `mt7915e` `wl1-ap0`, `wpad-mbedtls`, default country `PA`, baseline channels `1` `HT20` and `100` `HE160`; L2TP LNS in Docker and HTTP test server on a PC):

1. **Flash keeping settings:** `ax3200.defaults.acs='1'` was set; fixed channels (`1` `HT20`, `100` `HE160`) stayed untouched while presets were added to `radio0` and `radio1`. Both radios came up, `pidof xl2tpd` was empty, and `lsmod` showed no `l2tp_*` modules.
2. **ACS (`0329`, `471`, `wifi-scripts`, presets):**

| Run | Chosen channel | Scan time (`ACS-STARTED` → `ACS-COMPLETED`) | Downtime (`AP-DISABLED` → `AP-ENABLED`) | `ACS:` log line | Operating-channel survey (`iw dev … survey dump`) before → after |
|---|---|---|---|---|---|
| 2.4 GHz `auto` (`1a`, from ch 1) | 11 (`2462 MHz`, `HT20`) | 2.72 s | 4.03 s | `no noise floor in 6 of 26 surveys, assumed -95 dBm` | ch 1 `active 163201 ms` / `busy 28077 ms` → ch 11 `1878 ms` / `566 ms` |
| 2.4 GHz `auto` restart (`1b`, on ch 11) | 11 (`2462 MHz`, `HT20`) | 2.71 s | 3.56 s | `no noise floor in 7 of 26 surveys, assumed -95 dBm` | ch 11 `active 6903 ms` / `busy 1970 ms` → `1658 ms` / `441 ms` |
| 5 GHz `auto`, `HE80` (`2a`, `PA`, from ch 100) | 52 (`5260 MHz`, `HE80`) | 3.18 s | 4.79 s | `no noise floor in 25 of 25 surveys, assumed -95 dBm` | ch 100 `active 144459 ms` / `busy 2971 ms` → ch 52 `1399 ms` / `7 ms` |
| 5 GHz `auto`, `HE80` restart (`2b`, on ch 52) | 52 (`5260 MHz`, `HE80`) | 3.21 s | 4.69 s | `no noise floor in 25 of 25 surveys, assumed -95 dBm` | ch 52 `active 6433 ms` / `busy 164 ms` → `1463 ms` / `10 ms` |
| 5 GHz `auto`, `HE160`, `acs_exclude_dfs=1` (`PA`) | 100 (`5500 MHz`, `HE160`) | 3.18 s | 4.36 s | `no noise floor in 25 of 25 surveys, assumed -95 dBm` | — |
| 5 GHz `auto`, `HE160`, `acs_exclude_dfs=0` (`PA`) | 100 (`5500 MHz`, `HE160`) | 3.18 s | 4.38 s | `no noise floor in 25 of 25 surveys, assumed -95 dBm` | — |
| 5 GHz `auto`, `HE160`, `acs_exclude_dfs=1` (`DE`) | failed in 0.55 s (`AP-DISABLED`) | — | — | `no noise floor in 27 of 27 surveys`; `ACS: Failed to compute ideal channel` | — |
| 5 GHz `auto`, `HE160`, old `wifi-scripts` (`US`) | failed in 1 s (`AP-DISABLED`) | — | — | `no noise floor in 25 of 25 surveys`; `ACS: Failed to compute ideal channel` | — |
| 5 GHz `auto`, `HE160`, new `wifi-scripts` (`US`) | 100 (`5500 MHz`, `HE160`) | 3 s (`05:19:04` → `05:19:07`) | 68 s (`05:19:03` → `05:20:11`, incl. 63 s CAC `05:19:07` → `05:20:10`) | `no noise floor in 25 of 25 surveys, assumed -95 dBm` (`acs_exclude_dfs` omitted from `hostapd-wl1.conf`) | — |
| 5 GHz `auto`, `HE80`, new `wifi-scripts` (`US`) | 149 (`5745 MHz`, `HE80`, non-DFS) | 2 s (`05:20:14` → `05:20:16`) | 3 s (`05:20:13` → `05:20:16`) | `no noise floor in 25 of 25 surveys, assumed -95 dBm` (`acs_exclude_dfs=1` in `hostapd-wl1.conf`) | — |

- **`min_tx_power=15` on MT7915:** `iw phy wl1` reports a 27.0 dBm cap on 5 GHz under `PA` (all channels `36`–`165` ≥ 27 dBm, so 0 channels removed). Under `DE`, `36`–`48` are 23 dBm, `52`–`140` are 20–26 dBm with `radar detection`, and `149`–`173` are 13 dBm (25 mW SRD), so `min_tx_power=15` removes only the 25 mW channels, matching A5 v4.
- **`HE160` with `acs_exclude_dfs=1` (`wireless-regdb-2026.09.03` check):** Checked `db.txt` across all 182 countries for the three 160 MHz blocks in hostapd's `bw_160[]` (`5180–5320`, `5500–5640`, `5745–5885`), checking whether all 8 20 MHz sub-channels are allowed without `NO-IR` and whether any needs `DFS`. Result: **0** countries have both a DFS-free 160 MHz block and a DFS 160 MHz block; 4 have only DFS-free blocks (`GT`, `ID`, `PA`, `RU`), 169 have only DFS blocks (including `DE`, `US`, `UA`, `BY`, `KZ`), and 9 have none (`5745–5885` is unusable everywhere). Dropping `acs_exclude_dfs` in `hostapd.uc` (`wifi-scripts`) for 160/320 MHz therefore loses no valid exclusion while fixing `auto` + `HE160` in DFS countries (tested under `US`).
- **Survey `noise:` absence after `0329` reset (polled every 100 ms via `ucode` after `iw dev … scan trigger ap-force`):**
  - `wl0-ap0` (`2.4 GHz`, `mt7615e`, ch 1 `2412 MHz`): `noise: -86 dBm` before scan (`active 2684551 ms`); after reset, the first `mt76_update_survey()` (`mt76_get_survey()` at `idx == 0` / `mt7615_mac_work` every `100 ms`) restored `noise: -91 dBm` by `t = 4 ms` on ch 1 (stays absent only while off-channel during a scan).
  - `wl1-ap0` (`5 GHz`, `mt7915e`, ch 100 `5500 MHz`): `noise:` is already absent at rest (`active 11433 ms` and `2117375 ms`) and across `9 s` post-scan because `mt7915_phy_get_nf()` returns `0`.
- **Fresh install:** `package/base-files/files/etc/init.d/boot` runs `/sbin/wifi config` at line 48 before `kmodloader` (line 50) has loaded `mt7615e` and `mt7915e`, leaving an empty `/etc/config/wireless`. On first boot `77_wireless` runs `/sbin/wifi config` synchronously before `99-custom-settings` (`uci_apply_defaults`), so `radio0` and `radio1` already exist when `99-custom-settings` applies the ACS presets; guarding on `=wifi-device$` prevents setting `ax3200.defaults.acs='1'` if `wireless` is still empty.

3. **On-demand L2TP:**
   - `ifup l2tptest` (`proto l2tp` to the PC, port 1701) started `xl2tpd` (PID 6668), autoloaded `l2tp_core`, `l2tp_netlink`, and `l2tp_ppp`, brought up `l2tp-l2tptest` (`10.65.0.10` peer `10.65.0.1`), and `ping -c 3 10.65.0.1` succeeded with 0 % loss (`0.740–1.208 ms`); `ifdown l2tptest` tore down the session.
4. **Update check (`fwupdate`):**
   - Against a local test server on the PC (`fwupdate.settings.url`), a normal check returned `rc=0` (`v25.12.6-ax3200-r99`) and a 404 logged `check failed: http 404 (HTTP error 404)`.
   - Against a trickle endpoint (64 B every 20 s) with `DOWNLOAD_TIME=90` s and `STALE=120` s: `uclient-fetch`'s `uloop` signal handler catches `SIGTERM` and exits `0`, so checking the timeout marker before `r[0] == 0` is required. With that fix, the download ended at 90 s with `state: "error"`, `error: "stalled"`, `detail: "timed out after 90 s"`, logged `download failed: stalled (timed out after 90 s)`, and a concurrent `download` call returned `busy` (no second fetch).
   - `uclient-fetch` (`uclient_http_redirect()`) has no option to refuse `https` → `http` redirects.

**Decision:** Keep all three imported groups, dropping `acs_exclude_dfs` at 160/320 MHz in `wifi-scripts` (`hostapd.uc`) and hiding the DFS checkbox there in LuCI; track `uclient-fetch` HTTPS-only redirects and `SIGTERM` exit `0` in [TODO.md](TODO.md).
