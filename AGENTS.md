# AGENTS.md

Guidance for AI coding agents (and people) working on this repository.

**Read the documentation first:** `README.md` (what the build does and why), `BUILDING.md`
(how it is built and released), `UPGRADING.md` (every file this fork adds or changes, and how it
is ported to a new OpenWrt release), `RESEARCH.md` (the measurements behind the defaults; each
section ends with its decision, so do not propose a rejected option again without new data) and
`TODO.md` (patches to drop once upstream has the fix, deferred candidates).
OpenWrt's own `.github/llm-review-rules.md` applies to patches. This file only adds what those
documents do not cover.

## Rules

- **Measure before changing a default**, and record the setup, method, numbers and decision in
  `RESEARCH.md`.
- **Keep the documentation of the fork complete:** a new file or an edit of an upstream file goes
  into the table in `UPGRADING.md` section 1.2, a new assumption about upstream into the
  checklist in section 3.6.
- **The owner's devices:** flashing, rebooting or changing the configuration of the owner's
  router needs the owner's explicit OK for that step.

## Building and testing

- A single package: `make package/<name>/compile` after `make defconfig` with the package
  selected. LuCI apps build through `feeds/luci/luci.mk`, so the feeds must be installed. A full
  build takes long: run it in the background and check its log.
- Test a package on a router without reflashing: `apk add --allow-untrusted <file>.apk` (local
  builds are not signed with a key the image trusts). After replacing LuCI files, clear
  `/tmp/luci-indexcache*` and `/tmp/luci-modulecache`; browsers keep scripts by their `?v=`
  stamp, which follows the mtime of `/lib/apk/db/installed`. In an image that is the date of
  the last commit, or the build time when the tree had uncommitted changes (`build.sh`).
- ucode: a syntax check is `ucode <file>` on the router (a CLI prints its usage); an rpcd plugin
  loads with `ucode -e 'loadfile("<file>")()'`. There is no `fs.statvfs`; a failed
  `uclient-fetch -q` exits 8 on HTTP errors, 4 on connection errors and 7 on a response it cannot
  parse (the uclient patches of this build).
- Update check: the hidden option `fwupdate.settings.url` points a router at a test server that
  serves a fake `release.json` (written by `.github/scripts/ax3200-release-json.py`) and an
  image. Remove it afterwards; sysupgrade keeps it.
- "Keep my packages" without reflashing: after `fwupdate-packages save`, put the router back to
  the packages of its image by writing `/rom/etc/apk/world` to `/etc/apk/world` and running
  `apk add`. A package that provides one of the image (`dnsmasq-full`) stays until a
  `!dnsmasq-full` line forces the swap. Then write `/etc/fwupdate/restore.json` with
  `"state": "pending"` and the release, and run `fwupdate-packages retry`.
- `pkill -f <pattern>` kills the shell that runs it when the pattern is part of its own command
  line (e.g. `ssh host 'pkill -f …'`); keep a PID file instead.
- If the agent reaches the router over Wi-Fi, start commands that restart Wi-Fi detached on the
  router, or the session dies with the link.

## LuCI and ucode

- Follow the layout of `luci-app-tuning`: a JS view, an rpcd ucode plugin in
  `root/usr/share/rpcd/ucode/<name>.uc` returning `{ 'luci.<name>': methods }`, `menu.d`,
  `acl.d`, `po/templates/*.pot` and `po/ru/*.po`.
- Every `_()` string needs a Russian translation. LuCI's tools keep the catalogues in sync:
  `feeds/luci/build/i18n-scan.pl package/ax3200/<app> > package/ax3200/<app>/po/templates/<name>.pot`,
  then `feeds/luci/build/i18n-update.pl package/ax3200/<app>/po` (needs gettext), then translate
  the new `msgstr`s; `msgfmt -c` checks the result.
- rpc calls time out: run anything that touches the network (checks, downloads) in the
  background (`(cmd) </dev/null >/dev/null 2>&1 &`) and let the page poll a status file. Do not
  use `start-stop-daemon -x /bin/sh`: it starts nothing while any shell runs.
- An rpcd plugin waits for the commands it runs, and rpcd answers nothing else meanwhile. Never run
  another package's init script there, not even `enabled`: banIP's asks rpcd over ubus for the
  package list while it loads, so rpcd hung until ubus gave up after 30 s and LuCI reported
  "XHR request timed out".
- `E('p', E('a', …))` renders an empty `<p>`: a single element as the second argument is taken
  for the attributes. Write `E('p', {}, E(…))` or pass an array. Nested arrays among children are
  not flattened (an `<a>` turns into its URL as text).
- Pages that poll must not rebuild buttons when nothing changed, or a click can land on a removed
  element.
- Test both themes. Bootstrap aligns `.cbi-page-actions` its own way (use an own flex row) and
  draws lists in sections without bullets. Footstrap draws every button inside a notification
  plain, and its client-side router sweeps notifications away on page changes; the Overview runs
  its includes before the page is shown, and `oneshot()` only once per session.
- LuCI caches the menu tree per session in the browser: a renamed menu entry shows after the next
  login.
- Dates in views: format with `document.documentElement.lang`, the LuCI language, not the
  browser's.

## Writing for users

- `README.md` and `README.ru.md` change together, as do `BUILDING.md` and `BUILDING.ru.md`.
- Plain language for users. Implementation details (patch numbers, file paths, how something was
  fixed, internal tooling) belong in `UPGRADING.md` and `RESEARCH.md`, not in the README.
- UI texts: say what happens and what it costs, with measured numbers where there are some.
  Leave out the obvious (that a reboot interrupts the network, that one has to log in again) and
  do not say which languages a text comes in.
- Code comments are in English only.

## Commits

- Work on `xq-25.12`. Commit messages: `<area>: <what>` (`build:`, `docs:`, `luci-app-tuning:`,
  `mediatek: mtk_ppe:` …), a body that explains why, with measurements where they matter.
- Commits in this fork carry no AI attribution trailers (no `Co-Authored-By`). They are signed
  with the owner's key through the repository's git configuration; do not bypass it.
- Combine related commits before they are pushed. Push only when the owner asks; never rewrite
  pushed history without the owner's explicit OK.

## Upstream contributions

- Fixes that matter beyond this device go upstream: kernel and OpenWrt patches to
  openwrt/openwrt, bridger fixes to nbd168/bridger, LuCI fixes to openwrt/luci.
- Prepare them on separate branches from the upstream branch, authored under the owner's real
  name (OpenWrt does not accept pseudonyms), with `Assisted-by: LLM` and a sentence in the PR
  that discloses the AI assistance. The agent never adds `Signed-off-by` and never sends or opens
  anything: the owner reviews, signs off and submits.
- A patch file submitted to OpenWrt starts with a `From <sha> Mon Sep 17 00:00:00 2001` line, or
  its bot flags it. Check commits with OpenWrt's formality checker
  (`openwrt/actions-shared-workflows`, `check_formalities.sh`) before they are submitted. A
  stable-branch backport (`[25.12]`) follows the merge in main and carries
  `(cherry picked from commit …)`.
- To build OpenWrt main with a BPF package (bridger) using the host's clang, set
  `CONFIG_DEVEL=y` and `CONFIG_BPF_TOOLCHAIN_HOST=y`: without `CONFIG_DEVEL` the choice is hidden
  and main builds LLVM from source.

Waiting upstream (update this list when one is merged or closed, and drop the fork's copy as
`TODO.md` describes):

| Change in this fork | Submitted as |
|---|---|
| `971` flowtable: fetch the hardware counters before a flow is removed | superseded by Pablo Neira Ayuso's "netfilter: flowtable: retrieve stats on flow deletion" ([nf-next v4](https://lore.kernel.org/netfilter-devel/20261029122749.196486-1-pablo@netfilter.org/)), which needs a backport with its mtk_ppe part adapted to `736-03`/`736-04`; carried as `708` in [openwrt/openwrt#26107](https://github.com/openwrt/openwrt/pull/26107) meanwhile |
| `970` PPE flow accounting (a copy of `736-06` from #26107) | [openwrt/openwrt#26107](https://github.com/openwrt/openwrt/pull/26107) (Alexander Goodkind; our #26081 was closed in its favour) |
| `976` | in main as `042f7034ea` (Shi Jiayang, `pending-6.18/967-44-…`; our [openwrt/openwrt#26178](https://github.com/openwrt/openwrt/pull/26178) was closed in its favour); the `[25.12]` backport with the bridger update is [openwrt/openwrt#26484](https://github.com/openwrt/openwrt/pull/26484) |
| bridger update to `4b63ed4` | not submitted: OpenWrt main has `2a2d126` since `fbbcf2f78b`; drop ours once OpenWrt updates past `4b63ed4` |
| bridger `patches/100-…` | [nbd168/bridger#17](https://github.com/nbd168/bridger/pull/17) |
| uclient `patches/10[0-2]-…` (header lines longer than 4 KiB, hangs on an invalid response) | [openwrt/uclient#22](https://github.com/openwrt/uclient/pull/22) |
| `feeds-patches/luci/` (DDNS status) | [openwrt/luci#9154](https://github.com/openwrt/luci/pull/9154), in LuCI master since 2026-10-30 (`967b74154a`, `377df0286d`); waiting for `openwrt-25.12` |

## Working with the owner

- Plan larger features first and get the plan approved.
- Tests on the owner's devices go step by step, each with the owner's consent; say what a step
  does (reboot, minutes without network) before asking.
- Report what actually happened, including failed steps and results that contradict an earlier
  conclusion.
