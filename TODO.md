# TODO

Open work on this fork: patches to drop once upstream has the fix, and candidates that were looked at
but deferred. The status of what was submitted upstream is in the table at the end of
[AGENTS.md](AGENTS.md#upstream-contributions); the measurements are in [RESEARCH.md](RESEARCH.md).
Remove an item when it is done.

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
  its own and may then conflict with `972`.
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
- **[openwrt/uclient#22](https://github.com/openwrt/uclient/pull/22) (header lines longer than 4
  KiB).** Opened 2026-11-14. Until uclient has the fix, `uclient-fetch` (`wget`) on every OpenWrt
  router stalls on github.com. The build carries its three commits as `patches/10[0-2]-…`. Drop
  them once OpenWrt's uclient package has the fix; if the PR changes in review, take the new
  version.
  - [openwrt/uclient#20](https://github.com/openwrt/uclient/pull/20) (Filip722, 2026-11-12) fixes
    the same hang differently: header lines go into a separate buffer that grows without a limit
    (a 20 MB line is accepted), with cram tests. It does not fix the hang on an invalid chunk
    length, and its `realloc()` failure path uses the same `UCLIENT_ERROR_UNKNOWN` (0). If
    upstream takes #20, carry it and our chunk length commit instead.
- **`978` (`pskb_expand_head()` without `BUG()`).** net-next `c7d8bc3dd511`, not marked for stable, so
  6.12 will not get it. Drop it once the kernel of the build has it. A `WARNING` from
  `pskb_expand_head()` in a user's log shows where the shared skb comes from: compare with
  [openwrt/openwrt#26151](https://github.com/openwrt/openwrt/issues/26151), where fraglist GRO
  (`rx-gro-list`, on by default in OpenWrt) is suspected.
- **bridger version.** The build has `4b63ed4` (2026-10-27), OpenWrt main has `2a2d126`. Do not go back
  when OpenWrt updates the package. Optionally submit "bridger: update to Git HEAD (2026-10-27)" to
  OpenWrt.

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
- **Update check: its own message for exit code 7.** With the uclient patches `uclient-fetch`
  exits with 7 on a response it cannot parse. `fetch()` in `luci-app-fwupdate` treats every code
  except 8 as no connection, so the page says "no connection to GitHub" then.

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
  - The cherry-picked ca-certificates, musl, dnsmasq, uhttpd, libubox and wifi-scripts commits
    come with it unchanged. It also brings a MT7622 Ethernet probe race fix ("mtk_eth_soc:
    allocate dummy netdev sooner").
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
