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
- **xl2tpd only when an L2TP interface comes up.** It runs from boot and the L2TP modules stay
  loaded although no interface uses them (796 kB resident on the router, 2026-11-15).
  `/lib/netifd/proto/l2tp.sh` starts xl2tpd itself. The Archer A5 v4 build drops its start at
  boot (feed patch `0003-xl2tpd-do-not-start-at-boot`) and the `AUTOLOAD` of `kmod-l2tp` and
  `kmod-pppol2tp` in `netsupport.mk` (branch `task/l2tp-fixes` of openwrt-archer-a5v4-c50v4). Small
  gain at 256 MB; take it with an L2TP test on the router.
- **DoH with the clock behind.** dnsmasq asks only the DoH proxies (`noresolv`), and NTP resolves
  its servers by name. If the clock at boot is earlier than the start of validity of the
  certificate of cloudflare-dns.com or dns.google, TLS fails, no name resolves and NTP cannot
  correct the clock. The init script of https-dns-proxy does nothing about the time. To check on
  the router (with the owner's OK): how the clock comes back after a reboot and after a power cut
  (RTC of the MT7622, `sysfixtime`), then set it a few months back and restart the service. If
  it gets stuck: NTP servers by IP address, or start the proxies only after the first NTP sync.
- **https-dns-proxy crashes in a loop while the WAN is down.**
  - **Seen on 2026-11-21** in the log of a WAN outage (PPPoE, 2026.05.06-r1). Both proxies exited
    about every 9 s with `[F] dns_poller.c:39 c-ares needed more IO event handler, than the number
    of provided nameservers: 2`, and procd restarted them until the WAN came back. DoH was dead
    for that time, and the log filled. The crash follows an outage; it does not cause one.
  - **The cause.** The poller allocates one libev watcher per bootstrap server; `-b` gets only the
    two IPv4 ones. It exits (`FLOG`) when c-ares opens more sockets than that, which it can do
    while queries fail.
  - **Upstream fix.** `63c49b405d` "Fix bootstrap socket watcher exhaustion" (2026-09-09)
    allocates the watchers on demand. `116655073f` and `dd5f52a81b` fix the same poller later.
    The feed, in both 25.12 and master, still pins `0ba0525fa7` (2026.05.06).
  - **The fix.** Update the package to upstream HEAD (`e83e0b6118`, 2026-10-19), or take
    `63c49b405d` as a patch.
    - Submit the update to openwrt/packages together with the `0002` feed patch.
    - Check it (with the owner's OK): cut the WAN for a few minutes and watch
      `logread -f | grep https-dns-proxy`.
- **zapret2 through Zapret Manager.** The README section "zapret (only if you use it)" and
  RESEARCH §14 were tested with ZM 5.004 and zapret v1 (2026-11-04). ZM 5.089 can install zapret2
  instead (`/opt/zapret2`, `/etc/config/zapret2`, `nfqws2` with Lua strategies). To check:
  - **What ZM installs by default.** Does it still change the fw4 offload rule to
    `ct original packets ge 30` for zapret2?
  - **The settings it writes.** An install of 2026-11-21 had:
    - `NFQWS2_PORTS_TCP=80,443,853,1024-65535` and `NFQWS2_PORTS_UDP=53,80,88,443,1024-65535`;
    - `NFQWS2_TCP_PKT_OUT=25`;
    - `POSTNAT=1`, which also queues the router's own traffic, DNS included;
    - `MODE_FILTER=none`.
  - **The strategies `games_udp` and `games_tcp`.** They cover almost every UDP port above 1024
    and many TCP game ports, and send 8–10 fake packets for each of the first three packets of a
    flow.
    - Are they on by default, or opt-in?
    - With torrents or Steam that means thousands of flows. Measure the CPU of `nfqws2`, the drops
      in `/proc/net/netfilter/nfnetlink_queue` and the packet rate on `wan`.
  - **The §14 test.** Repeat it: fake ClientHellos on `wan`, wired and Wi-Fi clients, all four
    modes.

  Then update README.md, README.ru.md and RESEARCH §14. Installing it on the owner's router needs
  the owner's OK.
- **Update check: its own message for exit code 7.** With the uclient patches `uclient-fetch`
  exits with 7 on a response it cannot parse. `fetch()` in `luci-app-fwupdate` treats every code
  except 8 as no connection, so the page says "no connection to GitHub" then.
- **sysupgrade leaves the PPPoE session open at the ISP.**
  - **The cause.** `stage2` does not stop `network` on devices with more than 32 MB of RAM,
    so nothing runs `ifdown`. `kill_remaining TERM` then reaches netifd, and netifd sends
    SIGKILL to its `proto_task` pppd (`main.c` `netifd_kill_processes()`) before pppd sends its
    PADT.
  - **Measured on 2026-11-16** on a lab PPPoE server, with r15 flashed over r15 and the settings
    kept:
    - no Term-Request and no PADT left the router;
    - the PADI after the boot came 52 s later, while the server still held the old session;
    - a `reboot` sent Term-Request and PADT within 0.075 s (`ifdown -a` in `/etc/init.d/network`).
  - **The effect.** An ISP with one session per login may reject the new login with
    `AUTH_TOPEER_FAILED` until its own timeout closes the old session. netifd retries about
    twice a second (`authfail` 0).
  - **The fix to try.** In `stage2`, bring the ppp-proto interfaces down before
    `kill_remaining`.
    - Check it with the same lab test: a real sysupgrade with a session up.
    - It is an upstream bug: submit it to OpenWrt as well.
    - The bench and the logs are in the task `pppoe-auth` of the agents folder.
- **SQM on PPPoE: offloaded downloads may skip the shaper.**
  - **The cause (to confirm).** The *SQM* operating mode puts SQM on `pppoe-wan`
    (`wan_device()` in `tuning.uc`) and switches to software flow offloading. fw4 puts the
    zone's Ethernet port into the flowtable, not `pppoe-wan`. So the fast path takes an
    offloaded PPPoE download in at the port, PPPoE header and all, and the download never passes
    the tc ingress of `pppoe-wan`, where sqm-scripts redirects it to `ifb4pppoe-wan`.
  - **What stays shaped.** Uploads still leave through `pppoe-wan` and stay shaped. So do the
    first packets of each connection, before it is offloaded.
  - **Where this comes from.** MilkFlint (below) describes and fixes it in `36937d7b60`.
    [RESEARCH.md section 9](RESEARCH.md#9-wan-bufferbloat-and-the-need-for-sqm) measured SQM
    with software offloading on a DHCP WAN only.
  - **Check** on a lab PPPoE server (the bench of the sysupgrade item above): the *SQM* mode
    with PPPoE, and a download well above the set rate. Compare the bytes in
    `tc -s qdisc show dev ifb4pppoe-wan` with the download, and the throughput with the rate.
  - **Fix to try:** shape the Ethernet device (`network.wan.device`, e.g. `wan` or `wan.500`)
    instead of `pppoe-wan`.
    - Its tc ingress runs before the netfilter ingress hook of the flowtable, as on a DHCP WAN,
      where section 9 saw the CAKE counters grow with offloading on.
    - CAKE then gets PPPoE frames, so check that it still tells the flows apart and how it
      counts the extra headers.
    - Measure again.
  - **MilkFlint's fix** is two patches, not upstream:
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
- **Flowtable fixes from 6.14** that 6.12 lacks (MilkFlint `703-01`, `703-02`):
  - "nft_flow_offload: clear tcp MAXACK flag before moving to slowpath" (`d9d7b489416d`);
  - "flowtable: add CLOSING state" (`fdbaf5163331`).
  - They apply to hardware and software offloading alike. No symptom has been seen here.
  - Check whether 25.12.7's kernel has them.
  - Take them if TCP connections stall after leaving the fast path, or if closed connections
    stay in the flowtable.
- **mt76 2026-10-08 on 25.12.**
  - **Why it is possible now.** Section 10 left the mt76 HEAD out because it needs mac80211 7.2
    APIs. MilkFlint builds mt76 `467ae2e3f1` (the version of OpenWrt main) on 25.12 with:
    - three compat patches (`0001`–`0003`: NAN data interface cases, the action frame layout
      before `d49721c2`, the FILS unsolicited probe template API);
    - two mac80211 backports from OpenWrt main: `ieee80211_txq_aql_pending()` and the
      `sta_set_airtime_weight` op (`edc8a22ecc`, `c59ef1b709`).
  - **Tested there** only on MT7986, which uses the mt7915 driver, since 2026-10-25. The
    MT7622 WMAC (`mt7615`) has not been tried.
  - **What it would give.** All of upstream instead of the cherry-picks `0300`–`0317`, with the
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
