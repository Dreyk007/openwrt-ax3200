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
  2026-10-28) and Paul-Louis Charrière's "netfilter: flowtable: remove hardware flows before
  unbinding" fix what `972`/`973` fix: offloaded flows that stay in the PPE after a firewall reload.
  - Once one is merged, repeat the firewall reload test of
    [RESEARCH.md section 3](RESEARCH.md#3-traffic-accounting-with-hardware-offloading) without
    `972`/`973`.
  - Drop them if it passes.
- **[openwrt/openwrt#26107](https://github.com/openwrt/openwrt/pull/26107).** `970` is its `736-06`;
  `971` is its `708`. Drop both once 25.12 carries it.
- **[openwrt/openwrt#26178](https://github.com/openwrt/openwrt/pull/26178).**
  - After the merge in main, submit the `[25.12]` backport.
  - Drop `976` once 25.12 has it.
- **[openwrt/luci#9154](https://github.com/openwrt/luci/pull/9154).** Merged in master on 2026-10-30
  (`967b74154a`, `377df0286d`); `feeds-patches/luci/` carries these commits.
  - A cherry-pick into `openwrt-25.12` was requested on the PR on 2026-10-30.
  - Drop `feeds-patches/luci/` once the LuCI branch of the build has it.
- **[nbd168/bridger#17](https://github.com/nbd168/bridger/pull/17).** No review yet; ping it after
  2026-11-04. Drop `patches/100-…` once the fix is in bridger and OpenWrt's package.
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

## Next releases

- **25.12.7 (Linux 6.12.113).** Merge the tag, not the branch: a newer kernel on 25.12.6 stops the
  official kmods from loading. On 2026-10-31 `openwrt-25.12` merged into `xq-25.12` without
  conflicts.
  - Drop `977`: 6.12.113 has the CVE-2026-98432 fix.
  - `971` no longer applies: 6.12.113 sets `NF_FLOW_HW_DEAD` at the end of
    `flow_offload_work_del()` ("netfilter: flowtable: generalize pending status bit"). Keep that
    `set_bit()` as the last line of the function in both the removed and the added copy. With
    that, all mt7622 patches applied at fuzz 0 to 6.12.113.
  - The same release reworks the timeout extension of offloaded conntrack entries and makes the
    flowtable GC wait for pending hardware work (`NF_FLOW_PENDING`). Repeat the accounting tests
    of [RESEARCH.md section 3](RESEARCH.md#3-traffic-accounting-with-hardware-offloading),
    including `975`'s own stats interval.
  - The cherry-picked ca-certificates, musl and dnsmasq commits come with it unchanged. It also
    brings a MT7622 Ethernet probe race fix ("mtk_eth_soc: allocate dummy netdev sooner").
- **Our patches and bridger on the next release** (25.12.7 or a new series).
  - Go through "When upstream merges" above and the table in
    [AGENTS.md](AGENTS.md#upstream-contributions): drop what the release already has (`970`–`976`,
    `799-0*`, `feeds-patches/luci/`, bridger `patches/100-…`), refresh the rest at fuzz 0.
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
