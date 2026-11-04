# Research and Measurements

The measurements behind the decisions of this build, taken in October 2026 on a Redmi AX6S running OpenWrt 25.12.6 (`xq-25.12`) with a real home configuration. Each section ends with the decision it led to.

**Contents:** [Test setup](#test-setup) · [1. irqbalance](#1-irqbalance-vs-packet-steering) · [2. Official kmods](#2-official-kmod-compatibility) · [3. Traffic accounting](#3-traffic-accounting-with-hardware-offloading) · [4. Interface counters](#4-interface-counters-with-hardware-offloading) · [5. CPU governor](#5-cpu-frequency-governor) · [6. Latency](#6-latency-and-jitter) · [7. Kernel hardening](#7-cost-of-kernel-hardening) · [8. Extreme build](#8-extreme-build-experiment-dropped) · [9. WAN bufferbloat](#9-wan-bufferbloat-and-the-need-for-sqm) · [10. mt76 fixes](#10-wi-fi-driver-fixes-from-mt76-master) · [11. Wi-Fi ↔ LAN and bridger](#11-wi-fi--lan-throughput-and-bridger) · [12. Several clients, latency, WED](#12-several-wi-fi-clients-latency-and-wed) · [13. Operating modes](#13-packet-steering-mode-2-and-the-operating-modes)

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

**Bucket test (bug 4):** three 5 Mbit/s UDP flows from the build PC to an iperf3 server, with source ports chosen with the driver's hash function (`mtk_ppe_hash_entry()`) so that flow B lands in the bucket of flow A (slots `0x2fce` and `0x2fcf` in `/sys/kernel/debug/ppe0/bind`) and flow C in another bucket. B starts 45 s after A. Conntrack bytes against what iperf3 sent:

| Flow | sent (with headers) | before | after |
|---|---|---|---|
| A, first in the bucket | 64.5 MB | **29.1 MB**, stopped when B bound; its PPE entry outlived the flow | 64.5 MB |
| B, its neighbour | 35.5 MB | 35.5 MB | 35.5 MB |
| C, another bucket | 48.4 MB | 48.4 MB | 48.4 MB |

After the fix all three are counted to within 600 bytes (the PPE counts the 18 bytes of L2 headers per packet too), no PPE entry outlives its flow, and a 145 MB download closed at once is still counted at 105.2 % (2 of 2).

**Firewall reload test (bug 5):** one 5 Mbit/s UDP flow, `/etc/init.d/firewall reload` after 30 s, conntrack bytes against what iperf3 sent (58.04 MB with headers): before, 18.6 MB, the flow was never offloaded again, and its PPE entry kept forwarding until the flow ended; after, 58.04 MB, the flow stayed offloaded and its PPE entry went away with it. The bucket test and the download test give the same results as above.

**Wi-Fi download (bug 6):** one HTTPS connection from a 5 GHz client for 90 s, conntrack sampled every 2 s. With `975` the download direction (WAN → Wi-Fi, PPE + WED) reached conntrack every 3–4 s during the transfer, and 5.18 GB of payload on that one connection were counted as 5.55 GB (107 %, as for Wi-Fi before), more than 4 GiB without loss. Without the patches the whole download would have come in one poll at the end, truncated to 32 bits (about 1.25 GB); the old firmware was not measured.

**openwrt/openwrt#26107 in place of our patch (2026-10-29).** `736-06` of [openwrt/openwrt#26107](https://github.com/openwrt/openwrt/pull/26107) (Alexander Goodkind) carries the counter saving of our `970` together with two changes from Chad Monroe's tree. First, it checks the whole bucket before it binds the matching flow. Our version bound it at once, and the bind resets the slot counters, so an entry naming the same slot further down the list lost its last counters. Second, it takes the stats snapshot under `ppe_lock`: a rebind on another CPU between the snapshot and the update could count the same traffic twice. Same tests, wired client (build PC):

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

At a fixed 1.35 GHz the same work takes a smaller share of time than at the lower clocks `schedutil` picks. During a transfer the clock stays near 1.35 GHz anyway. Much of the extra busy time is the governor's own thread `sugov:0`. In the transfers of 2026-10-29 it took 7–15 % of a core, and ~22 % with bridger, where the load is lighter and more uneven. The clock changed 400–600 times per second (`stats/total_trans`): the MT7622 driver reports no transition latency, so `rate_limit_us` defaults to 1 ms; the CPU is not the bottleneck either way (50–60 % busy at ~900 Mbit/s over the bridge). Earlier, at idle: 3.8 % CPU with `schedutil` vs 6.0 % with `ondemand`. **`rate_limit_us` of `schedutil` (2026-10-29).** It sets how often the governor may change the clock, up or down; the kernel's default here is 1 ms. Two interleaved rounds per value, *Balanced* mode, laptop on 5 GHz with Wi-Fi power save off, build PC wired (`tests/scripts/rl/` outside the repository):

| `rate_limit_us` | 1 ms | 4 ms | 10 ms | 20 ms |
|---|---|---|---|---|
| `sugov:0` during LAN ↔ Wi-Fi transfers, share of a core | 7–15 % | 2–5 % | 1.4–3.5 % | 0.6–1.9 % |
| clock changes per second during transfers | 418–625 | 76–216 | 51–89 | 31–49 |
| idle: `sugov:0` / CPU0 busy / mean clock | 3–4 % / 7–8 % / ~500 MHz | 2.5 % / 5–6 % / ~540 MHz | 2 % / 4 % / ~595 MHz | 1.5 % / 4 % / ~650 MHz |
| idle ping build PC → laptop, median | 1.48–1.53 ms | 1.47–1.60 ms | 1.49–1.51 ms | 1.43–1.59 ms |

Throughput (812–932 Mbit/s) and the idle temperature (58–59 °C over the 60 s windows) did not depend on the value. A sudden 800 Mbit/s UDP burst from the build PC to the laptop after idle (the clock sampled every 2 ms by a ucode loop on the router, which keeps the CPU idle unlike a shell loop): from 437.5 MHz the clock reached 1.35 GHz after ~15–18 ms at 1 ms, ~26 ms at 4 ms and ~58 ms at 20 ms (one clean run each; mostly background traffic had already raised the clock). The loss in the first 100 ms (0–14 %) did not follow the value: the worst runs had the clock at 1.35 GHz throughout, and the 20 ms run that ramped from 437.5 MHz lost nothing. The CPU uses the lowest and the highest of its seven steps most of the time (437.5 MHz at 1.00 V to 1.35 GHz at 1.31 V); the five between them took ~7 % of the time.

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

Of the 387 mt76 commits since our version, 139 touch the code of this board's chips (MT7915E on 5 GHz, the MT7622 WMAC through `mt7615` on 2.4 GHz, the core and `connac` library) and 41 of them are already in 25.12. Every remaining commit that changes a compiled file was checked against the functions our drivers call: most are for MT7925/7927/7928, MT7996, MLO, NAN, or for the mt76 hardware scan and channel contexts, which neither driver uses (both use `mt76_sw_scan` and mac80211's chanctx emulation). 18 fixes apply to us and on top of 25.12's patches without conflicts (`package/kernel/mt76/patches/0300…0317`):

* station add/removal races that corrupt memory (`20f0979088`, `b1bc93f953`, `8f69e214f0`, `7ff2f295a6`), a NULL dereference in the 2.4 GHz driver (`bd41e0fbea`), frames to disassociated stations stuck in the queues (`0898393ee0`);
* firmware recovery (SER): RX hang detection (`af601a725f`), stuck TX queues (`130273a947`), the PHY setup that a full restart skipped (`b1f962a838`), and an out-of-bounds write in the coredump that a firmware crash produces (`fd3dc2614c`; coredump support is built in);
* the per-station RSSI average (`ed62359710`): since "mt76: improve signal strength reporting" (February 2022) mt76 fed it zeros, so the adaptive sensitivity (SCS) of the MT7622 WMAC always fell back to its default;
* TX aggregation on the VO queue (`f67ffb60cd`), HE DCM and VHT RX STBC peer capabilities (`e593243800`, `41cecc382b`), 4th-chain ACK RSSI (`cdc6c0d07c`), bounds checks (`04017929f6`, `1c9854c436`, `2802466a94`).

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

**Not taken:** the whole mt76 HEAD needs mac80211 7.2 APIs (`ieee80211_txq_aql_pending()`, link-ID template getters) that OpenWrt main only builds on kernel 6.18. The power-save buffering for MT7915 (`9a46d8d21d`, `9e613fb007`) is a behaviour change with little effect here: offloaded traffic from the WAN goes through WED past the driver, and only host-path frames to dozing 5 GHz clients would be affected. mac80211 fixes from Linux 6.18.56–58 (e.g. extension frame validation, oversized fragments, PS teardown) arrive with the next mac80211 update of 25.12, which happened every 2–3 months so far.

## 11. Wi-Fi ↔ LAN throughput and bridger

**Setup:** the laptop (Intel Wi-Fi 6, 2×2, HE160 on channel 100) about 1 m from the router at −45 dBm, link rate 1815–2268 Mbit/s to the laptop and 2402 Mbit/s from it. Two wired iperf3 servers, the build PC on `lan1` and a mini-server on `lan2`, both at once with 4 streams each for 20 s (the first 2 s left out), so that no single gigabit port caps the sum; wired ↔ wired gives 931–941 Mbit/s. Router CPU per core from `/proc/stat`, the transmit/receive airtime of the station from `/sys/kernel/debug/ieee80211/wl1/netdev:wl1-ap0/stations/<mac>/airtime`. The `performance` governor was set for the comparisons, the configurations were switched at runtime and run interleaved.

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

The build therefore updates bridger to Git HEAD 2026-09-17. Then a kernel bug showed up: OpenWrt's pending `736-03` clears the parent L2 flow in `mtk_flow_entry_update_l2()` when one of its subflows is no longer bound, instead of that subflow. Test: a long 50 Mbit/s TCP stream between the build PC and the laptop, a full-speed transfer between the same hosts, then two more 20 s apart:

| | first transfer | second | third |
|---|---|---|---|
| without the fix | 5 / 17 % CPU, in the PPE | 25 / 69 %, on the CPU | 24 / 71 %, on the CPU |
| with `976` | 4 / 16 % | 6 / 17 % | 6 / 16 % |

Without the fix the hardware byte counter of the rule stopped as well: even the long stream had left the PPE.

**Result** on the test firmware (bridger 2026-09-17 + `976`), 3 interleaved rounds; the UDP row is one 500 Mbit/s stream from the build PC to the laptop with 100 pings/s from the laptop to the mini-server meanwhile (Wi-Fi power save of the laptop on):

| | mode 1 | mode 2 | bridger + mode 1 | bridger + mode 2 |
|---|---|---|---|---|
| LAN → Wi-Fi TCP, Mbit/s | 1193–1298 | 1287–1331 | 1174–1323 | 1143–1344 |
| router CPU (both cores) | 67–76 % | 77–79 % | **8–9 %** | **7–8 %** |
| Wi-Fi → LAN TCP, Mbit/s | 1574–1804 | 1531–1709 | 1539–1760 | 1502–1782 |
| router CPU | 78–86 % | 80–83 % | 65–75 % | 68–72 % |
| UDP 500 Mbit/s LAN → Wi-Fi: CPU | 32–33 % | 33–38 % | **10–11 %** | 11–12 % |
| ping meanwhile, median / p99 | 3.3–3.5 / 17–26 ms | 3.1–3.2 / 16–28 ms | 3.5–3.7 / 18–21 ms | 3.7–3.9 / 23–52 ms |

With bridger the LAN → Wi-Fi throughput stays the same: the station's transmit airtime is ~85 %, so the radio link is the limit, not the CPU. Wi-Fi → LAN is unchanged, as expected without WED RX. Latency with a saturating download (one wired PC → laptop, 4 TCP streams, ~937 Mbit/s, 100 pings/s to the mini-server): median / p99 5.6–6.3 / 24–36 ms without bridger, 4.8–5.6 / 22–31 ms with it, so with one client the bypassed mac80211 queues cost nothing in this test. These single-client latency runs had the laptop's Wi-Fi power save on, which adds its own delay; with it off and with several clients the hardware path does cost latency and fairness, see [section 12](#12-several-wi-fi-clients-latency-and-wed). **Decision:** bridger is in the image but off by default.

**Functional checks with bridger** (a UDP stream from the build PC to the laptop, the event in the middle):
* client reconnect (hostapd deauthenticates the laptop during a 20 Mbit/s stream): data flows again 1–2 s later, in a new hardware rule; 4 s without bridger. Disconnecting and reconnecting on the laptop (`nmcli device disconnect/connect`): back 5 s later;
* band change of the client (5 → 2.4 → 5 GHz): the rule goes away as the client leaves 5 GHz, the stream continues over the CPU on 2.4 GHz 5 s after the switch (the time to reassociate), and gets a new hardware rule 2 s after the return to 5 GHz;
* `wifi` restart during a transfer: back after ~15 s, again in hardware;
* `/etc/init.d/firewall reload` during a 200 Mbit/s stream: one second at 176 Mbit/s, 0.5 % loss; `/etc/init.d/network reload`: no effect;
* `kill -9` of bridger: procd restarts it after ~5 s, the stream keeps flowing. This showed a bridger bug: the rule of the killed instance stayed on `eth0`, and the new instance did not know it. When the client then moved to 2.4 GHz, the PPE kept sending its stream to `wl1-ap0`: 44 s without traffic until the client came back to 5 GHz. At startup bridger removes the rules an earlier instance left behind, but it attaches a bridge port before it looks up the port's offload device, so `eth0` was never cleaned. `package/network/services/bridger/patches/100-…` looks the offload device up first; with it the new instance replaces the rule within 2 s and the band change works;
* 128 parallel UDP streams from the build PC to the laptop (the laptop's iperf3 3.16 crashed with more): ~900 Mbit/s, the port limit, 208 bound PPE entries, CPU 6 / 56 %, so part of the traffic stays on the CPU with that many flows; a WAN download to the laptop meanwhile was counted by nlbwmon at 105 % (headers), as without bridger;
* traffic from the router itself to the laptop (iperf3 server on the router): 855–880 Mbit/s with and without bridger;
* clients on 2.4 GHz (the MT7622 WMAC has no WED) get no hardware rule, their traffic stays on the CPU path; all 10 clients of the 2.4 GHz radio stayed connected and active;
* WAN downloads are not affected (~500 Mbit/s, the ISP limit, at 11 % CPU, PPE entries from the flowtable as before);
* 5 minutes of alternating full-speed LAN ↔ Wi-Fi transfers: no kernel warnings, bridger keeps running.

**bridger `4b63ed4` (2026-10-29).** Git HEAD 2026-10-27 adds `76dbaa8`: when a client's FDB entry goes away or moves to another port, bridger removes the client's BPF redirects and hardware rules at once. Before, they stayed in place until the entry's flows expired. The checks above, repeated with `4b63ed4` + `patches/100-…`:
* client reconnect (hostapd) during a 2-stream TCP transfer to the laptop: the transfer dips only while the client reassociates and continues in a new hardware rule;
* `wifi` restart: back after ~10 s, in hardware;
* `kill -9` of bridger during a 200 Mbit/s UDP stream: no loss beyond normal (0.08 %), the new instance replaces the rule.
* band change of the client (5 → 2.4 → 5 GHz) during a 30 Mbit/s UDP stream: the rule goes away as soon as the client leaves 5 GHz, and the return gets a new hardware rule in the second the client associates, against ~2 s with `2a2d126`. The stream stops only while the laptop is associated with neither radio (~10 s and ~5 s here).

Router CPU per core during a 2-stream TCP transfer from the build PC to the laptop (~910–940 Mbit/s), with the governor of the *Maximum throughput* mode (`performance`), 3 interleaved rounds:

| | `4b63ed4` | `2a2d126` | no bridger |
|---|---|---|---|
| CPU0 / CPU1 | 2–3 % / 10–14 % | 3–4 % / 11–14 % | 32–52 % / 53–69 % |

With `schedutil` (the *Balanced* mode, which does not turn bridger on) one core was 44–53 % busy with either version. The network work itself was ~10 % (`napi/phy1`, `mt76-tx`). Most of the rest was the governor's own thread `sugov:0`, ~22 % of a core, see [section 5](#5-cpu-frequency-governor).

**Pitfalls:**
* `iw dev wl1-ap0 station del <mac>` removes the station behind hostapd's back: the client reassociates within 2 s but passes no traffic for about a minute, with or without bridger. Use `ubus call hostapd.wl1-ap0 del_client '{"addr":"<mac>","reason":3,"deauth":true,"ban_time":0}'`.
* sysupgrade keeps services that were disabled before the upgrade disabled (`/etc/uci-defaults/10_disable_services`), so a router that had `bridger` disabled during tests comes up without it: `/etc/init.d/bridger enable; /etc/init.d/bridger start`.
* The fixed-rate UDP test keeps the airtime at ~85 % even at 500 Mbit/s: paced packets leave in short A-MPDUs. Airtime is only a capacity measure when the link is saturated.

## 12. Several Wi-Fi clients, latency and WED

**Setup:** three 5 GHz clients: the laptop as a VR headset (2×2 HE160, ~1 m, Wi-Fi power save off), an Android TV box (Ugoos AM8, Android 14, 2×2 HE80, −48 dBm, link rate 865–907 Mbit/s) and a phone (2×2 HE160). Sources: the mini-server sends to the laptop, the build PC to the TV box and the phone. "VR" is a 200 Mbit/s UDP stream to the laptop plus 100 pings/s from the laptop to the mini-server. 3 interleaved rounds per configuration, `schedutil` governor; airtime per station from mac80211's debugfs.

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

**A household evening:** the laptop as a gamer on Wi-Fi pings 1.1.1.1 at 50/s for 60 s, and the wired build PC pings it too. The TV box plays "4K" the way streaming apps do: 10 MB at full speed from the internet every 4 s, ~16 Mbit/s on average. The phone lies asleep. "VR" adds the 200 Mbit/s stream, with the laptop pinging the mini-server. Blocks WED on → off → on, 2 rounds each; gamer p99 / max:

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

**Method:** the provider of the test setup blocks nothing, so the question was whether `nfqws` gets to modify the ClientHello, not whether a site opens. One HTTPS request to `discord.com` (pinned to 162.159.137.232) per run; `tcpdump` on `wan`, filtered to that address, counts the fakes with `rzd.ru` (two per processed connection). Clients: the laptop on 5 GHz Wi-Fi and the build PC on `lan1`. Three runs per cell; the firewall was reloaded after each change.

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
