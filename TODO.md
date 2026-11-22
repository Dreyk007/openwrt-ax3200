# TODO

Open work on this fork: patches to drop once upstream has the fix, and candidates that were looked at
but deferred. The status of what was submitted upstream is in the table at the end of
[AGENTS.md](AGENTS.md#upstream-contributions); the measurements are in [RESEARCH.md](RESEARCH.md).
Remove an item when it is done.

## To submit upstream

Changes of this fork that belong upstream and are not submitted yet. The owner reviews, signs off
and submits them ([AGENTS.md](AGENTS.md#upstream-contributions)). Once one is submitted, move it
to the table there.

- **openwrt/packages, `net/https-dns-proxy`:** the update to upstream HEAD and the `0002` fix (items
  below), one PR to master, then the backport to 25.12.
- **openwrt/openwrt `[25.12]`: netifd 2026-10-28 or newer.** With it pppd sends Terminate-Request
  and PADT on a sysupgrade (our `0001`–`0006`). Main already has it.
- **openwrt/openwrt: kernel `981`** (`e7b01bc0202a`, a fix for OpenWrt's own lockless patch
  `623`). Submit it to `[25.12]`, and to main if main still carries `623` without the fix.
- **openwrt/openwrt: `ppp6-up`** adds no `<iface>_6` next to a configured DHCPv6 interface on the
  same link (GitHub issue #1, [RESEARCH.md section 15](RESEARCH.md#15-pppoe-through-the-router-lab)).
  Main first, then `[25.12]`.
- **To check before proposing:** whether OpenWrt main or 6.12 stable already has the ppp/pppoe
  fixes `979`, `980`, `982`, `983`, and the merged PPPoE GRO of `984` in place of the pending `650`.
- **bridger:** optionally "bridger: update to Git HEAD (2026-10-27)" (below).
- **openwrt/uclient (`uclient-fetch.c`):** `uclient-fetch` exits with `0` when `SIGTERM` ends a
  transfer because `uloop_run()` catches `SIGTERM` via `uloop_handle_sigint()` and returns the
  signal number, while `uclient-fetch.c:953` ignores `uloop_run()`'s return value and leaves
  `error_ret` at `0` (`uclient-fetch.c:979` in `openwrt/uclient` master), so a caller cannot tell a
  killed transfer from a finished one.

## When upstream merges

- **Pablo Neira Ayuso's "netfilter: flowtable: retrieve stats on flow deletion"** (nf-next v4,
  2026-10-29, [lore](https://lore.kernel.org/netfilter-devel/20261029122749.196486-1-pablo@netfilter.org/)).
  It closes our netfilter patch.
  - Replace `971` with a backport of it.
  - Adapt its mtk_ppe part to `736-03`/`736-04`, where the counters come from
    `mtk_foe_entry_get_stats()`, not `mtk_foe_entry_get_mib()`.
  - nf-next goes into the next merge window, so 6.12 will not get it on its own.
- **Pablo Neira Ayuso's "netfilter: flowtable: perform unbind callback on hook release"** (nf,
  2026-10-28), Paul-Louis Charrière's "netfilter: flowtable: remove hardware flows before
  unbinding" and Arnau Valls's "netfilter: flowtable: remove hw flows before unbinding the flow
  block" (nf, 2026-11-03, `Cc: stable`, tested on MT7981 with 6.12.74) fix what `972`/`973` fix:
  offloaded flows that stay in the PPE after a firewall reload. A `Cc: stable` fix reaches 6.12 on
  its own and may then conflict with `972`. In OpenWrt this is
  [openwrt/openwrt#17915](https://github.com/openwrt/openwrt/issues/17915): long-lived
  connections (WireGuard, VoIP) break after a firewall reload. OpenWrt reloads the firewall by
  itself when PPPoE reconnects or DHCP renews, so PPPoE users see it most. The cause was found
  there on 2026-11-03 on an MT7981. Official 25.12 still has it.
  - Once one is merged, repeat the firewall reload test of
    [RESEARCH.md section 3](RESEARCH.md#3-traffic-accounting-with-hardware-offloading) without
    `972`/`973`.
  - Drop them if it passes.
- **João Silva's "netfilter: flowtable: do not clear the offload bit twice"** (2026-11-03; Pablo
  asked for nf-next, so 6.12 will not get it on its own). A hardware flow that waits for its
  deletion is torn down again by the next GC pass and clears `IPS_OFFLOAD_BIT` of the flow that
  replaced it, so more flows pile up for one conntrack entry (seen on RTL930x). 6.12.113 has the
  same `flow_offload_teardown()`. Not seen in the accounting tests on this router; consider it if
  duplicate PPE entries for one connection show up.
- **[openwrt/openwrt#26107](https://github.com/openwrt/openwrt/pull/26107).** `970` is its `736-06`;
  `971` is its `708`. Drop both once 25.12 carries it.
- **`976`.** Main fixed the same line on 2026-11-03 with `042f7034ea` (Shi Jiayang,
  `pending-6.18/967-44-…`), so our [openwrt/openwrt#26178](https://github.com/openwrt/openwrt/pull/26178)
  was closed. The `[25.12]` backport, together with the bridger update, is
  [openwrt/openwrt#26484](https://github.com/openwrt/openwrt/pull/26484).
  - Drop `976` once 25.12 has `967-44` in `pending-6.12`: `976` no longer applies then.
- **[openwrt/luci#9154](https://github.com/openwrt/luci/pull/9154).** Merged in master on 2026-10-30
  (`967b74154a`, `377df0286d`); `feeds-patches/luci/` carries these commits.
  - A cherry-pick into `openwrt-25.12` was requested on the PR on 2026-10-30.
  - Drop `feeds-patches/luci/` once the LuCI branch of the build has it.
- **[nbd168/bridger#17](https://github.com/nbd168/bridger/pull/17).** No review yet; pinged on
  2026-11-04. Drop `patches/100-…` once the fix is in bridger and OpenWrt's package.
- **[openwrt/uclient#20](https://github.com/openwrt/uclient/pull/20) (header lines longer than 4 KiB).**
  Until uclient has the fix, `uclient-fetch` (`wget`) on every OpenWrt router stalls on
  github.com. The build carries the three commits of our [openwrt/uclient#22](https://github.com/openwrt/uclient/pull/22) as `patches/10[0-2]-…`. We closed
  #22 on 2026-11-15 in favour of #20 (Filip722): after our review it limits a header line to
  64 KiB and adds the same `UCLIENT_ERROR_INVALID_RESPONSE`, also for an invalid chunk length
  (`8dc6934`; tested by us on 2026-11-15). Once upstream takes #20, replace our patches with its
  commits; drop them when OpenWrt's uclient package has them.
- **`978` (`pskb_expand_head()` without `BUG()`).** net-next `c7d8bc3dd511`, not marked for stable, so
  6.12 will not get it. Drop it once the kernel of the build has it. A `WARNING` from
  `pskb_expand_head()` in a user's log shows where the shared skb comes from: compare with
  [openwrt/openwrt#26151](https://github.com/openwrt/openwrt/issues/26151), where fraglist GRO
  (`rx-gro-list`, on by default in OpenWrt) is suspected.
- **https-dns-proxy feed patch (`feeds-patches/packages/0002-…`).** Submit it to openwrt/packages
  (`net/https-dns-proxy`, Stan Grishin): rebase onto master and set `PKG_RELEASE` one above
  master's. One submission covers the Archer A5 v4 build too, which carries the same patch. Drop it
  once the feed of the build has the fix; the `doh_backup` cleanup in `99-custom-settings` stays
  for configurations of earlier builds.
- **https-dns-proxy update (`feeds-patches/packages/0003-…`).** While the upstream connection was
  down, both proxies of 2026.05.06 exited every few seconds with `[F] dns_poller.c:39 c-ares needed
  more IO event handler, than the number of provided nameservers: 2`. procd restarted them without
  limit: 50 times in 3.5 minutes of a 7-minute outage on the PPPoE bench. DNS still came back within
  4 s of the connection, so the loop filled the log without delaying the recovery.
  - **The fix.** Upstream `63c49b4` "Fix bootstrap socket watcher exhaustion" allocates the
    watchers on demand. `0003` takes upstream HEAD `e83e0b6118` (2026-10-19).
  - **Checked on the router (2026-11-22).** The proxies' own packets were cut off for 6 minutes:
    marked by uid in output and dropped at the egress of `wan`, so sends succeed and the packets
    vanish, as in an outage.
    - The old binary from `/rom` ran on another port as the control. It hit the fatal error after
      3 min 48 s and exited 46 times in the next 3.5 minutes.
    - The two instances of 2026.10.19 kept their PIDs and answered as soon as the cut ended.
    - Dropping in the output hook instead returns an error to `sendto()` at once and does not
      trigger the loop, not even with the old binary.
  - **The PR to openwrt/packages:** the update first, then the `0002` fix with `PKG_RELEASE` 2.
  - **Drop** `0003` once the feed pins `63c49b4` or newer.
  - **Upgrade without a reboot.** The init script maps `restart` to `reload`, and procd keeps
    instances whose command line did not change. So `apk upgrade` leaves the old binary running
    until `stop` and `start` or a reboot.
- **netifd patches (`package/network/config/netifd/patches/000[1-6]`).** A sysupgrade left the
  PPPoE session open at the ISP: procd stops netifd before stage2, and netifd 2026-02-26 of 25.12
  ended pppd with SIGKILL, before its Terminate-Request and PADT (lab: no PADT with r15's netifd,
  Terminate-Request and PADT with the patches, [RESEARCH.md section 15](RESEARCH.md#15-pppoe-through-the-router-lab)).
  OpenWrt main has the fix with netifd 2026-10-28. Drop the patches once 25.12's netifd contains
  `2922ee8232`; propose that netifd update for 25.12 meanwhile.
- **bridger version.** The build has `4b63ed4` (2026-10-27), OpenWrt main has `2a2d126`. Do not go back
  when OpenWrt updates the package. Optionally submit "bridger: update to Git HEAD (2026-10-27)" to
  OpenWrt.
- **`0345` (`package/kernel/mt76/patches/0345-wifi-mt76-reorder-RX-frames-when-WED-does-not-handle-RX.patch`) for `linux-wireless` (`mt76`).**
  Owner sends it upstream: `mt76_rx_poll_complete()` checks only `mtk_wed_device_active()` before
  skipping `mt76_rx_aggr_reorder()`, so checking `mtk_wed_get_rx_capa()` as well restores RX
  reordering on MT7622 + MT7915 when `mt7915e wed_enable=1` (WED v1, TX offload only), without
  changing MT7986 (WED v2 with WO) or MT7988/MT7996 (WED v3 with HWRRO). Note that only MT7622 with
  `wed_enable` hits this (OpenWrt leaves `wed_enable` off by default). Drop `0345` once upstream
  `mt76` carries it.
  - **Before sending:** with `0345`, a station that uploads at 800 Mbit/s and scans in the
    background gets ~100 ms stalls of its own TID about every 2–3 s, against every ~11 s without
    `0345`; at 400 Mbit/s practically none
    ([RESEARCH.md section 10](RESEARCH.md#10-wi-fi-driver-fixes-from-mt76-master)).
    - **Not the router's doing.** A debug build showed that the router does not hold these
      frames: no reorder timeout fired. The stalls form in the client's queue.
    - **Not WED-specific either.** OpenWrt's default without WED behaves the same.
    - So they do not hold up the submission.

## Deferred

- **Lost counters of L2 subflows.** `__mtk_ppe_check_skb()` frees an `L2_SUBFLOW` entry that names
  the slot being bound, and its counters never reach the L2 flow. This came up in the AI review of
  #26107 and in Sashiko's and Simon Horman's review of the netdev version. It affects bridged flows
  (bridger) only.
  - Wait for #26107.
  - Otherwise, only detach the subflow there and let `mtk_flow_entry_update_l2()` fold its
    counters and free it. Test with bridger on.
- **WED `793-02` "fix reset condition for rx wdma"** (Zhi-Jun You, OpenWrt main since 2026-10-28).
  Of the new WED fixes it is the only one that touches WED v1 (MT7622), and only on a Wi-Fi
  restart. Take it if Wi-Fi misbehaves after `wifi` or a Wi-Fi settings change, or with the next
  OpenWrt release.
- **`797`: WMM priority (TID) for flows through the PPE/WED** (Felix Fietkau, OpenWrt main, 6.18).
  It is 825 lines plus cfg80211 and mt76 patches. Look at it with the next OpenWrt release. mt7915
  needs mt76 to answer the priority query (`001-wifi-mt76-answer-the-flow-priority-query`).
- **`Tested-by` for Pablo's series on MT7622** (optional). Its driver part has not run on hardware.
  It needs a test build with the mtk_ppe part adapted to `736-03`/`736-04` and the tests of
  [RESEARCH.md section 3](RESEARCH.md#3-traffic-accounting-with-hardware-offloading).
- **Two CPU clock steps instead of seven** (437.5 MHz and 1.35 GHz). They cannot be disabled at run
  time: this needs a DTS patch of the OPP table. The five steps in between take ~7 % of the time.
  After `rate_limit_us` 10 ms the gain is likely small, and the power at moderate load would rise.
  Only with a test build and the measurements of
  [RESEARCH.md section 5](RESEARCH.md#5-cpu-frequency-governor).
- **Chad Monroe's series** (990-08, 990-34 of the SmartRG tree). Test it on MT7622 when it is
  submitted, as offered in #26081.
- **Routed flows of a Wi-Fi client that changes band, with hardware offloading.** Only bridged
  flows (bridger) were tested when a client moves from 5 GHz to 2.4 GHz
  ([RESEARCH.md section 11](RESEARCH.md#11-wi-fi--lan-throughput-and-bridger)). Upstream reports
  that an offloaded flow keeps its old output port when its client moves to another bridge port
  or MAC; OpenWrt main took Julius Bairaktaris's "netfilter: flowtable: tear down direct xmit
  flows when the fdb entry moves" for this (`279704475c`, 6.18; nf-next v9 of 2026-11-08). 6.12
  will not get it on its own.
  - Test first, in the default operating mode: a Wi-Fi client downloads from the internet and
    switches from the 5 GHz to the 2.4 GHz network; the download must go on.
  - Only if it stalls: backport the patch to 6.12. In main it is 313 lines and comes with two
    forward path backports; check which of them 6.12 needs.
- **Flowtable VLAN ID fix** (`c203ecf90574`, OpenWrt main as `be75fbfa9b`): the tuple is keyed on
  the whole VLAN TCI, so frames whose tag carries a priority (PCP) miss their flow and are not
  offloaded. Matters only for a WAN on a VLAN with PCP. It has a `Fixes:` tag; check whether
  6.12 stable has it when 25.12.7 is merged.
- **mt7615 uploads the CSA beacon twice as well.** `mt7615_bss_info_changed()` uploads it on
  `BSS_CHANGED_BEACON`, and `mt7615_channel_switch_beacon()` uploads the same template with the
  initial count again, as mt7915 did before mt76 `2356292ae3`. Upstream has not changed mt7615.
  The 2.4 GHz radio has no radar channels, so a CSA there only comes from a manual or automatic
  channel change. The same removal as in `2356292ae3` would fix it; a candidate for an upstream
  patch, tested like the mt7915 one.
- **`rmmod mt7915e` with WED attached** (seen 2026-11-14 when testing modules): three warnings
  in `page_pool_disable_direct_recycling()` (mt76 destroys the RX page pools while their NAPI is
  still enabled; fixed upstream by `a57185c5` "wifi: mt7915: disable rx napi when removing
  device", which applies to our mt76), then a reset of the Ethernet and the switch that leaves
  WAN down until `ifup wan`, and after `insmod` 5 GHz runs without WED until a reboot. Normal
  operation never unloads the module; it matters for module tests. Take `a57185c5` if module
  swaps are needed more often, and test then whether the Ethernet reset remains.
- **mt76 master commits not taken into `0330`–`0346`** (checked against `39c960c3` + `0063`–`0329`,
  [RESEARCH.md section 10](RESEARCH.md#10-wi-fi-driver-fixes-from-mt76-master)):
  - `7474835` ("mt7615: skip MT_TXD5_TX_STATUS_HOST for group frames", reported against MT7663e):
    `mt7615_mac_write_txwi()` requests host TX status on non-beacon frames for all MT7615/MT7622/MT7663
    chips, and on MT7622 (`MT7615_FIRMWARE_V2`, `!mt7615_firmware_offload()`) mac80211 handles PS
    buffering instead of firmware offload; cannot verify from code whether closed MT7622 N9
    firmware shares MT7663's DTIM queue stall, so left out unless a group-traffic stall appears.
  - `3c17c4d` ("check the RX PN of CCMP-256, GCMP and GCMP-256 keys"): depends on the earlier
    `sta_key_conf` rework (`62694ed0b76f`) not present in `39c960c3`; take if backporting that
    rework or updating mt76.
  - `0241c2b` ("remove a replayed station from the driver before the add"): requires checking
    interaction with `0067-wifi-mt76-add-wcid-publish-check-in-mt76_sta_add.patch` (kept from
    25.12), which already guards re-adds via `mt76_sta_add()`; revisit if mac80211 debugfs
    `reset` station replay matters.
- **MT7915 full firmware recovery (`echo 7 > /sys/kernel/debug/ieee80211/wl1/mt76/sys_recovery`)
  fails to bring 5 GHz back** (seen on both 25.12's mt76 `fbd08ee272` and the updated mt76
  `d962f2553d`): `mt7915_mac_restart()` times out on `PATCH_SEM` (`0x00000010`) and then
  `MCU_EXT_CMD(FW_LOG_2_HOST)` (`0x000013ed`) across all 10 attempts (`chip full reset failed`),
  leaving `wl1-ap0` `DOWN` (`Out of memory` on `wifi up` until a reboot). Consequence: if the
  MT7915 firmware crashes in use and escalates beyond L1 recovery to a full chip reset, 5 GHz
  stays down until the router is rebooted. To investigate: guess is an interaction with WED v1 on
  MT7622 during `mt7915_dma_reset()` / `mtk_wed_device_stop()`.
- **~100 ms stalls of a heavy uploader during its scans.** Under an upload of 800 Mbit/s the
  laptop's own TID 0 traffic stalls for 80–110 ms about every 2–3 s, only while it scans in the
  background; traffic in another TID does not stall. With `0345` this happens ~4× as often as
  without it, with WED on or off
  ([RESEARCH.md section 10](RESEARCH.md#10-wi-fi-driver-fixes-from-mt76-master)).
  - **Not the router's reorder buffer.** A debug build (44 runs) showed no reorder timeout and no
    window overflow:
    - holes closed within 20 ms, rarely within 60 ms;
    - runs without any late hole still had stalls;
    - no QoS Null, BlockAckReq or driver drop left a hole.

    The stalls form in the laptop's TID 0 queue during its off-channel dwells.
  - **Why `0345` makes them more frequent: the TCP window** (tested). With in-order frames the
    laptop's window grows from 3.5–5.1 to 7.7–10.7 MiB. Capping it at C's size
    (`iperf3 -w 256K`) or using UDP removed the stalls. Nothing to fix on the router.
  - **Two states.** The rate varies about 3× from boot to boot: ~26 against ~5–9 stalls per
    minute.
    - The high state came with a higher full-speed upload (1370–1430 against 1220–1240 Mbit/s) at
      the same MCS, and with longer absences of the laptop during scans.
    - Four connections in the debug build were all high; the cause is unknown.
  - **A timer flaw in `agg-rx.c`** (found by an outside review, confirmed in the code).
    - **The flaw:** the reorder work is not cancelled when the buffer empties. When it then wakes
      for a newer hole, nothing has expired yet, and it re-arms a full timeout from that moment.
    - **Its effect:** a hole could wait up to ~200 ms. A fresh work runs on the 11th jiffy, because
      the timer wheel rounds up (`calc_index()`).
    - **Seen here:** the debug build saw such early wake-ups (`early_rearm`), but no hole lasted
      long enough to matter.
    - **The fix:** schedule from the oldest buffered frame, as mac80211 does in
      `ieee80211_sta_reorder_release()`, and queue the work only while frames are buffered. Small;
      an upstream candidate.
  - **Not useful:** a shorter reorder timeout. The router never reached it here, and with a client
    that retransmits after a ~50 ms dwell it would turn late frames into drops.
- **Update check: HTTPS-only redirects (`luci-app-fwupdate`).** `uclient-fetch` (`uclient_http_redirect()`)
  follows any `Location` URL regardless of scheme and has no flag like curl's `--proto-redir =https`
  to refuse `https` → `http` downgrades. Left open until `uclient` adds a scheme restriction or
  `fwupdate` switches client.
- **DoH with the clock behind.** dnsmasq asks only the DoH proxies (`noresolv`), and NTP resolves
  its servers by name. If the clock at boot is earlier than the start of validity of the
  certificate of cloudflare-dns.com or dns.google, TLS fails, no name resolves and NTP cannot
  correct the clock. The init script of https-dns-proxy does nothing about the time. To check on
  the router (with the owner's OK): how the clock comes back after a reboot and after a power cut
  (RTC of the MT7622, `sysfixtime`), then set it a few months back and restart the service. If
  it gets stuck: NTP servers by IP address, or start the proxies only after the first NTP sync.
- **zapret2 through Zapret Manager.** The README section "zapret (only if you use it)" and
  RESEARCH §14 were tested with ZM 5.004 and zapret v1 (2026-11-04). ZM 5.089 installs zapret2
  (`/opt/zapret2`, `nfqws2` with Lua strategies).
  - **Measured on the PPPoE bench on 2026-11-22** ([RESEARCH.md section 15](RESEARCH.md#15-pppoe-through-the-router-lab)):
    - ZM applies the 30-packet rule itself;
    - bulk traffic keeps its throughput and the PPE;
    - its defaults turn on `games_udp` and `games_tcp`;
    - many new UDP flows multiply the WAN packets by 11 and raise the ping maximum from about 27 to about 110 ms;
    - at 1,000 new flows/s `nfqws2` takes one core.
  - **Still to do:**
    - the §14 test with zapret2: fake ClientHellos on `wan`, wired and Wi-Fi clients, all four modes;
    - a line in README.md and README.ru.md that the game strategies are on by default and cost latency with torrents;
    - RESEARCH §14.

  Installing it on the owner's router needs the owner's OK.
- **Update check: its own message for exit code 7.** With the uclient patches `uclient-fetch`
  exits with 7 on a response it cannot parse. `fetch()` in `luci-app-fwupdate` treats every code
  except 8 as no connection, so the page says "no connection to GitHub" then.
- **PPPoE bench and tests.** The PPPoE changes of 2026-11-21 (kernel `979`–`987`, ppp 2.5.5,
  `ppp6-up`, the netifd patches, SQM on the WAN device) passed the lab over `br-lan` and the bench
  on the `wan` port: a PC in line between the ONT and the router, as the ISP's BRAS
  (accel-ppp). Both are in [RESEARCH.md section 15](RESEARCH.md#15-pppoe-through-the-router-lab).
  - **Covered:**
    - the operating modes;
    - accounting;
    - reconnects;
    - the loss of LCP and of IP traffic;
    - sysupgrade against a server that refuses a second session, r15 against the netifd patches;
    - IPv6 prefix delegation and client traffic;
    - zapret2;
    - the internet throughput against DHCP.
  - **Still open:** a real ISP. The 4PDA report of 2026-11-20 (PPPoE up, no IP traffic, fixed by
    restarting wan): on the bench the router recovered from the same state by itself.
  - **The bench:**
    - scripts `bench-gw.sh` (the ISP side: the USB NIC with the router's WAN MAC, NAT) and
      `bench-pppoe.sh` (accel-ppp in Docker; `LCP_INTERVAL`/`LCP_FAILURE` set how long the server
      keeps a silent session) in `temp_workdir/pppoe-test/lab/`;
    - the PC is reached through the router over IPv6 link-local on `wan`.
  - **Upstream:** `981` and the `ppp6-up` fix are listed under "To submit upstream".
- **5 GHz Wi-Fi loses 0.6–1 % of the packets at 600–700 Mbit/s.**
  - **What was seen.** On the PPPoE bench (2026-11-22, *Balanced*, laptop with an Intel AX card
    at -47 dBm, 160 MHz):
    - every wired hop and the router's kernel dropped nothing;
    - between the router's `wan` and the laptop 4,451–5,379 packets per 12 s got lost, as many
      as the server retransmitted, with 92–111k `tx failed` of the station.
  - **What it costs.** At LAN latency TCP hides it (650–710 Mbit/s). At 10 ms one stream gets
    about 260 Mbit/s and 8 streams about 410; at 40 ms 125 and 265. To a CDN 10 ms away 8 streams
    got 395–477 Mbit/s, while the PC got 590 by cable. Speedtest with 12–16 connections
    still reaches the tariff.
  - **To check:**
    - the same in *Low latency* (WED off) and on 80 MHz;
    - with the mt76 of OpenWrt 25.12 without the fixes of [RESEARCH.md section 10](RESEARCH.md#10-wi-fi-driver-fixes-from-mt76-master);
    - with another client;
    - the counters of `ethtool -S wl1-ap0` (`tx_retry_failed`, `tx_mpdu_attempts`) per run.

    A local iperf3 with netem 10 ms on the server reproduces it without the internet.
- **SQM on PPPoE: CAKE on the WAN device gets PPPoE frames.** The *SQM* mode now shapes
  `network.wan.device`, not `pppoe-wan`. On `pppoe-wan`, the fast path of software offloading took
  the downloads in at the netfilter ingress of `wan` and they skipped the shaper: 763 Mbit/s with
  a 200 Mbit/s limit. On `wan` the same download got 170 Mbit/s
  ([RESEARCH.md section 15](RESEARCH.md#15-pppoe-through-the-router-lab)). To check there:
  - whether CAKE still tells the hosts apart (`nat`, `triple-isolate`) when the IP packets come
    inside PPPoE frames;
  - which overhead to count (`overhead`, `mpu`; PPPoE adds 8 bytes), and why the download got
    85 % of the limit (the lab on a PPPoE device got 96 %).

  MilkFlint (below) keeps SQM on `pppoe-wan` instead, with two patches that are not upstream:
  - a kernel patch (543 lines): the fast path of `nft_flow_offload` stops at a device with tc
    ingress;
  - a fw4 patch that adds `pppoe-wan` to the flowtable (`d831baba6e`).
- **MilkFlint**, the source of the items below: OddBlueDog's OpenWrt 25.12.6 build for the
  GL-MT6000 (MT7986), [forum thread](https://forum.openwrt.org/t/254862),
  [repository](https://github.com/OddBlueDog/openwrt), branch `milkflint-25.12`.
  - It has 130 commits, mostly written with AI. Its author publishes no CPU or throughput
    measurements for its patches.
  - Patch names below are the files in that branch's `target/linux/generic/` and
    `package/kernel/mt76/patches/`. Hashes are commits there.
  - **Not applicable here:**
    - RSS and the cheaper receive path (MT7986 Ethernet, netsys v2 and newer);
    - its WED fixes (WO and WED v2; the one for WED v1, `793-02`, is listed above);
    - its kernel 6.12.115 (the official kmods need 25.12's kernel);
    - its web interface, AdGuard Home, banIP, own kmod feed and KFENCE.
- **cake_mq for downloads.**
  - **What 25.12 has.** cake_mq is in `700-0x` and `701-0x`, and in iproute2's
    `001-1-tc-cake-add-cake_mq-support`. sqm-scripts 1.7.2 uses it with `option use_mq 1` on a
    device with more than one TX queue, and creates its ifb with one TX queue per CPU.
  - **Download only.** On the router `wan` has one TX queue (`eth0` has 16), so only the
    download (`ifb4wan`) can use cake_mq. Uploads stay with one CAKE.
  - **Experiment** in the *SQM* mode on the ~600/365 Mbit/s link:
    - `use_mq 1`;
    - RPS of `wan` on both CPUs (`rps_cpus` 3);
    - XPS of `ifb4wan` tx-0 on CPU0 and tx-1 on CPU1 (`xps_cpus` 1 and 2), so each core runs
      its own sub-CAKE. MilkFlint 0.84a does this for PPPoE (`dc570595ba`).
    - Set the download rate to 550–600 Mbit/s and compare throughput, per-core CPU and p99
      with one CAKE at the same rate, by the method of section 9.
    - Baseline: one CAKE shapes ~390–430 Mbit/s wired, at 96–98 % of one core.
  - **Stock cake_mq's limits.** It gives each active sub-CAKE rate / n. Uneven traffic loses
    throughput: 80/20 between two queues gives 70 % of the rate. The sum can also run over the
    rate for moments.
    - MilkFlint's `760-08`, `760-25` and `760-26` fix that.
    - Take them only if stock cake_mq gains anything on two cores.
- **CAKE patches that cut the CPU cost per packet** (MilkFlint).
  - **The patches:**
    - `760-01`: the host hashes only when a flow queue is allocated;
    - `760-02`: cake_mq rates redone only when the share changes;
    - `760-12`: the shaper's watchdog may wake up to 300 µs late and send what came due
      meanwhile (module parameter `wake_slack_us`);
    - "no timer for every packet of a quiet link" (`eb5e5892b8`);
    - the rest of `7ffe78a347`, which also changes the scheduling (no dither, a bigger bulk
      quantum).
  - **Why they matter.** The single CAKE of section 9 is bound by one core, so any saving raises
    the ceiling.
  - **Test without reflashing.**
    - Build `kmod-sched-cake` with the patches. They change only `sch_cake.c`.
    - Install it with `apk add --allow-untrusted`.
    - A/B it against the stock module above the CPU limit (450/340 as in section 9):
      throughput, CPU, p99.
  - **The fixes from netdev in the same series:**
    - `701-03` "skip clearing unused tins during rate adjustment";
    - `760-20`…`760-23`: autorate throttling, reconfiguration serialized with the datapath, the
      parent backlog when a tin is cleared, and encap headers in the qdisc packet length.
- **mt76 2026-10-08 on 25.12.**
  - **Why it is possible now.** Section 10 left the mt76 HEAD out because it needs mac80211 7.2
    APIs. MilkFlint builds mt76 `467ae2e3f1` (the version of OpenWrt main) on 25.12 with:
    - three compat patches (`0001`–`0003`: NAN data interface cases, the action frame layout
      before `d49721c2`, the FILS unsolicited probe template API);
    - two mac80211 backports from OpenWrt main: `ieee80211_txq_aql_pending()` and the
      `sta_set_airtime_weight` op (`edc8a22ecc`, `c59ef1b709`).
  - **Tested there** only on MT7986, which uses the mt7915 driver, since 2026-10-25. The
    MT7622 WMAC (`mt7615`) has not been tried.
  - **What it would give.** All of upstream instead of the cherry-picks `0300`–`0344` (`0329` is from A5 v4), with the
    Wi-Fi tests of sections 10–12.
  - **MilkFlint's own mt76 patches** (`0004`–`0159`, about 130 without its tests) are not
    upstream. They touch mt7915 and the mt76 core, none `mt7615`. Take single ones only
    against a symptom seen here. One example is reorder windows that are not a power of two
    (`0124`, `0132`).

## Next releases

- **25.12.7 (Linux 6.12.113 or newer).** Merge the tag, not the branch: a newer kernel on 25.12.6
  stops the official kmods from loading. On 2026-10-31 `openwrt-25.12` merged into `xq-25.12`
  without conflicts.
  - Drop `977`: 6.12.113 has the CVE-2026-98432 fix.
  - `971` no longer applies: 6.12.113 sets `NF_FLOW_HW_DEAD` at the end of
    `flow_offload_work_del()` ("netfilter: flowtable: generalize pending status bit"). Keep that
    `set_bit()` as the last line of the function in both the removed and the added copy. With
    that, all mt7622 patches applied at fuzz 0 to 6.12.113.
  - The same release reworks the timeout extension of offloaded conntrack entries and makes the
    flowtable GC wait for pending hardware work (`NF_FLOW_PENDING`). Repeat the accounting tests
    of [RESEARCH.md section 3](RESEARCH.md#3-traffic-accounting-with-hardware-offloading),
    including `975`'s own stats interval.
  - The rework (`ed250c60e164`, upstream `03428ca5cee9`) must come with its fix "netfilter:
    flowtable: fix offloaded ct timeout never being extended" (upstream `53b3e60edb67`, also in
    6.12.113). Without it, the timeout of an offloaded connection is never extended: WED-offloaded
    flows drop after about 300 s (seen on MT7986). 6.12.112 still has the old logic
    (`nf_ct_offload_timeout()`) and is not affected. Before releasing 25.12.7, check that
    `nf_flow_table_extend_ct_timeout()` compares against one `READ_ONCE(ct->timeout)` snapshot,
    and keep a Wi-Fi download through WED running for more than 10 minutes.
  - The cherry-picked ca-certificates, musl, dnsmasq, uhttpd, libubox and wifi-scripts commits
    come with it unchanged. It also brings a MT7622 Ethernet probe race fix ("mtk_eth_soc:
    allocate dummy netdev sooner").
  - `985` and `986` were written against 6.12.112. 6.12.113 brings the timeout rework
    (`03428ca5cee9`) without these two, and it changes `flow_offload_fixup_ct()` that they
    touch. Rebuild them in mainline's order (`d9d7b489416d`, then `03428ca5cee9`, then
    `fdbaf5163331`), keep `NF_FLOW_CLOSING` at the end of the enum, and repeat the accounting
    tests. `980` and `982` are marked for stable: drop them if the new 6.12.y has
    them.
  - Since 2026-11-10 the branch has 6.12.116. 6.12.114–116 add two flowtable fixes ("avoid
    num_encaps underflow on bridge VLAN untag", "nf_flow_table: drop existing skb dst before
    skb_dst_set_noref()") in other files than `971`–`975`; check that those still apply at fuzz 0
    and repeat the accounting tests.
  - ucode goes from Git HEAD 2026-02-27 to 2026-07-09 plus backports (nl80211: HE MCS parsing,
    DFS CAC time, survey attributes). Check LuCI and the ucode parts of this build
    (`luci-app-tuning`, `luci-app-fwupdate`, the rpcd plugins) on the router.
- **Our patches and bridger on the next release** (25.12.7 or a new series).
  - Go through "When upstream merges" above and the table in
    [AGENTS.md](AGENTS.md#upstream-contributions): drop what the release already has (`970`–`976`,
    `799-0*`, `feeds-patches/luci/`, bridger `patches/100-…`, uclient `patches/10[0-2]-…`), refresh
    the rest at fuzz 0.
  - If 25.12 backports nbd's mtk_wed fixes or "mtk_eth_soc: query the wireless driver for the TID
    of flows" (pending-6.18 since 2026-10-28), check that `970`–`976` still apply and repeat the
    accounting tests.
  - bridger: if the release updates the package, keep `4b63ed4` or newer and check that
    `patches/100-…` still applies. Then test with bridger on (operating mode *Maximum
    throughput*), as in [RESEARCH.md section 11](RESEARCH.md#11-wi-fi--lan-throughput-and-bridger):
    two wired → Wi-Fi transfers one after the other must both go through the hardware (`Sent
    hardware` grows in `tc -s filter show dev eth0 ingress`; the second one checks `976`), and a
    Wi-Fi client reconnect, `wifi` and `kill -9` of bridger must not stall traffic
    (`patches/100-…`). Switch back to the default mode afterwards.
