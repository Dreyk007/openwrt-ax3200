#!/bin/sh
# Update any earlier Xiaomi AX3200 / Redmi AX6S release (r6+) to the latest release,
# keeping settings and user-installed packages.
#
# Wrapped in a single function called on the last line so a truncated curl | sh
# download runs nothing.

ax3200_update() {
	local DEFAULT_REPO="Dreyk007/openwrt-ax3200"
	local BOARD="xiaomi,redmi-router-ax6s"
	local COUNTDOWN=15
	_ax_fwupdate_dir="/tmp/fwupdate"
	_ax_fwupdate_keep="/lib/upgrade/keep.d/luci-app-fwupdate"

	local opt_lang="en"
	while [ $# -gt 0 ]; do
		case "$1" in
		--lang=en) opt_lang="en" ;;
		--lang=ru) opt_lang="ru" ;;
		*)
			printf 'Usage: ax3200-update.sh [--lang=en|ru]\n' >&2
			return 1
			;;
		esac
		shift
	done

	msg() {
		if [ "$opt_lang" = "ru" ]; then
			printf '%s\n' "$2"
		else
			printf '%s\n' "$1"
		fi
	}

	local board
	board=$(cat /tmp/sysinfo/board_name 2>/dev/null || true)
	if [ "$board" != "$BOARD" ]; then
		if [ "$opt_lang" = "ru" ]; then
			printf "Ошибка: неподдерживаемая плата '%s' (ожидается %s).\n" "${board:-unknown}" "$BOARD" >&2
		else
			printf "Error: unsupported board '%s' (expected %s).\n" "${board:-unknown}" "$BOARD" >&2
		fi
		return 1
	fi

	if [ "$(id -u)" -ne 0 ]; then
		msg "Error: this script must be run as root." "Ошибка: этот скрипт нужно запускать от имени root." >&2
		return 1
	fi

	local missing="" tool
	for tool in curl ucode jsonfilter; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			missing="${missing:+$missing, }$tool"
		fi
	done
	if [ -n "$missing" ]; then
		if [ "$opt_lang" = "ru" ]; then
			printf 'Ошибка: не найдены необходимые команды: %s.\n' "$missing" >&2
		else
			printf 'Error: missing required commands: %s.\n' "$missing" >&2
		fi
		return 1
	fi

	_ax_tmpdir=""
	_ax_fwupdate_was_running=0
	_ax_checked=0
	_ax_orig_status_saved=0
	_ax_did_download=0
	_ax_requested_packages=0
	_ax_created_keep=0
	_ax_flashing=0
	_ax_cleaned=0

	cleanup() {
		[ "$_ax_cleaned" = 1 ] && return 0
		_ax_cleaned=1
		[ "$_ax_flashing" = 1 ] && return 0

		if [ "$_ax_created_keep" = 1 ]; then
			rm -f "$_ax_fwupdate_keep"
		fi
		if [ "$_ax_requested_packages" = 1 ] && [ -n "$_ax_tmpdir" ] && [ -f "$_ax_tmpdir/fwupdate-packages" ]; then
			ucode "$_ax_tmpdir/fwupdate-packages" forget >/dev/null 2>&1 || true
		fi
		if [ "$_ax_did_download" = 1 ]; then
			rm -f "$_ax_fwupdate_dir/firmware.part" "$_ax_fwupdate_dir/firmware.bin" "$_ax_fwupdate_dir/download.json"
		fi
		if [ "$_ax_checked" = 1 ]; then
			if [ "$_ax_orig_status_saved" = 1 ] && [ -n "$_ax_tmpdir" ] && [ -f "$_ax_tmpdir/orig_status.json" ]; then
				mkdir -p "$_ax_fwupdate_dir"
				cp -f "$_ax_tmpdir/orig_status.json" "$_ax_fwupdate_dir/status.json" 2>/dev/null || true
			else
				rm -f "$_ax_fwupdate_dir/status.json" 2>/dev/null || true
			fi
			rmdir "$_ax_fwupdate_dir" 2>/dev/null || true
		fi
		if [ -n "$_ax_tmpdir" ]; then
			rm -rf "$_ax_tmpdir"
		fi
		if [ "$_ax_fwupdate_was_running" = 1 ] && [ -x /etc/init.d/fwupdate ]; then
			/etc/init.d/fwupdate start >/dev/null 2>&1 || true
		fi
	}

	on_signal() {
		trap - INT TERM HUP
		printf '\n' >&2
		cleanup
		exit 130
	}

	_ax_tmpdir=$(mktemp -d /tmp/ax3200-update.XXXXXX) || {
		msg "Error: could not create temporary directory." "Ошибка: не удалось создать временный каталог." >&2
		return 1
	}
	local tmpdir="$_ax_tmpdir"
	trap cleanup EXIT
	trap on_signal INT TERM HUP

	local repo="$DEFAULT_REPO" raw_repo=""
	if [ -f /etc/ax3200_release ]; then
		raw_repo=$(sed -n "s/^REPO='\([^']*\)'.*/\1/p" /etc/ax3200_release | head -n 1)
		if printf '%s' "$raw_repo" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
			repo="$raw_repo"
		fi
	fi

	local custom_url release_json_url
	custom_url=$(uci -q get fwupdate.settings.url || true)
	release_json_url="${custom_url:-https://github.com/$repo/releases/latest/download/release.json}"

	msg "Checking for updates..." "Проверка наличия обновлений..."

	local code rc tag
	code=$(curl -fsSL --connect-timeout 30 --speed-limit 1 --speed-time 30 -w '%{http_code}' -o "$tmpdir/release.json" -- "$release_json_url" 2>/dev/null)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		if [ "$rc" -eq 22 ]; then
			if [ "$opt_lang" = "ru" ]; then
				printf 'Проверка не удалась: GitHub вернул ошибку (HTTP %s).\n' "$code" >&2
			else
				printf 'Check failed: GitHub returned an error (HTTP %s).\n' "$code" >&2
			fi
		else
			msg "Check failed: no connection to GitHub." "Проверка не удалась: нет связи с GitHub." >&2
		fi
		cleanup
		return 1
	fi

	tag=$(jsonfilter -i "$tmpdir/release.json" -e '@.tag' 2>/dev/null || true)
	if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+-ax3200-r[0-9]+$'; then
		msg "Check failed: the release information could not be read." "Проверка не удалась: не удалось прочитать сведения о версии." >&2
		cleanup
		return 1
	fi

	local raw_base="https://raw.githubusercontent.com/$repo/$tag/package/ax3200/luci-app-fwupdate/root/usr/libexec"
	local script_name
	for script_name in fwupdate fwupdate-packages; do
		code=$(curl -fsSL --connect-timeout 30 --speed-limit 1 --speed-time 30 -w '%{http_code}' -o "$tmpdir/$script_name" -- "$raw_base/$script_name" 2>/dev/null)
		rc=$?
		if [ "$rc" -ne 0 ]; then
			if [ "$rc" -eq 22 ]; then
				if [ "$opt_lang" = "ru" ]; then
					printf 'Не удалось загрузить %s: GitHub вернул ошибку (HTTP %s).\n' "$script_name" "$code" >&2
				else
					printf 'Failed to download %s: GitHub returned an error (HTTP %s).\n' "$script_name" "$code" >&2
				fi
			else
				msg "Check failed: no connection to GitHub." "Проверка не удалась: нет связи с GitHub." >&2
			fi
			cleanup
			return 1
		fi
	done

	mkdir -p "$tmpdir/bin"
	cat <<'EOF' > "$tmpdir/bin/uclient-fetch"
#!/bin/sh
timeout=30
out=""
url=""
while [ $# -gt 0 ]; do
	case "$1" in
	-T) timeout="$2"; shift 2 ;;
	-T*) timeout="${1#-T}"; shift ;;
	-O) out="$2"; shift 2 ;;
	-O*) out="${1#-O}"; shift ;;
	-q) shift ;;
	--) shift; [ $# -gt 0 ] && url="$1"; break ;;
	-*) shift ;;
	*) url="$1"; shift ;;
	esac
done
[ -n "$out" ] && [ -n "$url" ] || exit 4
code=$(curl -fsSL --connect-timeout "$timeout" --speed-limit 1 --speed-time "$timeout" -w '%{http_code}' -o "$out" -- "$url" 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ]; then
	exit 0
fi
rm -f "$out"
if [ "$rc" -eq 22 ]; then
	printf 'HTTP error %s\n' "$code" >&2
	exit 8
fi
exit 4
EOF
	chmod +x "$tmpdir/bin/uclient-fetch"

	cat <<'EOF' > "$tmpdir/render.uc"
'use strict';

import { readfile, stat } from 'fs';

const mode = ARGV[0];
const lang = (ARGV[1] == 'ru') ? 'ru' : 'en';
const MONTHS = {
	en: [ '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec' ],
	ru: [ '', 'янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек' ]
};

function tr(en, ru) {
	return (lang == 'ru') ? ru : en;
}

function read_json(file) {
	const s = readfile(file);
	if (s == null)
		return null;
	try {
		return json(s);
	}
	catch (e) {
		return null;
	}
}

function fmt_date(d) {
	if (type(d) != 'string')
		return '';
	const m = match(d, /^([0-9]{4})-([0-9]{2})-([0-9]{2})/);
	if (!m)
		return d;
	const day = +m[3], mon = +m[2], year = m[1];
	const mname = (mon >= 1 && mon <= 12) ? MONTHS[lang][mon] : m[2];
	return sprintf('%d %s %s', day, mname, year);
}

function note_text(r) {
	if (!r || !r.note)
		return '';
	return (lang == 'ru' && r.note.ru) ? r.note.ru : (r.note.en || '');
}

function check_error(e) {
	if (e == 'network')
		return tr('no connection to GitHub', 'нет связи с GitHub');
	if (e == 'invalid')
		return tr('the release information could not be read', 'не удалось прочитать сведения о версии');
	const m = (type(e) == 'string') ? match(e, /^http ([0-9]+)$/) : null;
	if (m)
		return sprintf(tr('GitHub returned an error (HTTP %s)', 'GitHub вернул ошибку (HTTP %s)'), m[1]);
	if (e == 'http')
		return tr('GitHub returned an error', 'GitHub вернул ошибку');
	return e || tr('Unknown error', 'Неизвестная ошибка');
}

function download_error(dl) {
	switch (dl ? dl.error : '') {
	case 'space': return tr('There is not enough free memory for the update.', 'Для обновления не хватает свободной памяти.');
	case 'network': return tr('The download failed: no connection to GitHub.', 'Загрузка не удалась: нет связи с GitHub.');
	case 'http': return tr('The download failed: GitHub returned an error.', 'Загрузка не удалась: GitHub вернул ошибку.');
	case 'size':
	case 'checksum': return tr('The downloaded file is damaged. Try again.', 'Загруженный файл повреждён. Попробуйте ещё раз.');
	case 'invalid': return tr('The router does not accept this firmware file.', 'Роутер не принимает этот файл прошивки.');
	case 'manual': return tr('This release has to be installed manually.', 'Эту версию нужно установить вручную.');
	case 'stalled': return tr('The download stopped. Try again.', 'Загрузка прервалась. Попробуйте ещё раз.');
	case 'no_release': return tr('Check for updates first.', 'Сначала проверьте наличие обновлений.');
	default: return (dl && dl.error) || tr('Unknown error', 'Неизвестная ошибка');
	}
}

function names(list) {
	return join(', ', map(list, (p) => (type(p) == 'string') ? p : p.name));
}

function print_notes(releases, latest) {
	for (let r in releases || []) {
		const txt = note_text(r);
		if (!txt && !r.note_url)
			continue;
		printf('%s: %s\n', r.tag, txt);
		if (r.note_url)
			printf('%s: %s\n', tr('Instructions', 'Инструкция'), r.note_url);
	}
	if (latest && latest.url)
		printf('%s: %s\n', tr('Release page on GitHub', 'Страница версии на GitHub'), latest.url);
}

if (mode == 'status') {
	const st = read_json('/tmp/fwupdate/status.json');
	if (!st) {
		printf('%s\n', tr('Check failed: the release information could not be read.', 'Проверка не удалась: не удалось прочитать сведения о версии.'));
		exit(1);
	}
	if (st.error) {
		printf('%s: %s.\n', tr('Check failed', 'Проверка не удалась'), check_error(st.error));
		exit(1);
	}
	const inst = (st.installed && st.installed.release) ? st.installed.release : tr('local build', 'локальная сборка');
	printf('%s: %s\n', tr('Installed firmware', 'Установленная прошивка'), inst);
	if (!st.latest) {
		printf('%s\n', tr('Check failed: the release information could not be read.', 'Проверка не удалась: не удалось прочитать сведения о версии.'));
		exit(1);
	}
	if (!st.update && !st.local) {
		printf(tr('This is the latest release: %s.\n', 'Обновлений нет: %s — последняя версия.\n'), st.latest.tag);
		exit(10);
	}
	const hdr = st.local
		? tr('Latest release: %s', 'Последняя версия: %s')
		: tr('New release: %s', 'Новая версия: %s');
	printf('%s · %s\n', sprintf(hdr, st.latest.tag), fmt_date(st.latest.date));
	printf('%s: %s\n', tr('Release page on GitHub', 'Страница версии на GitHub'), st.latest.url);
	if (st.local)
		printf('%s\n', tr('This firmware was built locally, so the router cannot tell whether this release is newer.',
			'Эта прошивка собрана локально, поэтому роутер не может определить, новее ли эта версия.'));
	const rels = st.releases || [];
	if (length(rels) == 1)
		printf('\n');
	for (let r in rels) {
		if (length(rels) > 1)
			printf('\n%s · %s\n', r.tag, fmt_date(r.date));
		if (length(r.changes || [])) {
			for (let c in r.changes)
				printf('  - %s\n', c.subject);
		}
		else {
			printf('  %s\n', tr('No list of changes.', 'Список изменений не указан.'));
		}
	}
	printf('\n');
	if (st.method != 'auto') {
		if (st.method == 'manual')
			printf('%s\n', tr('This release has to be installed manually.', 'Эту версию нужно установить вручную.'));
		else
			printf('%s\n', tr('This update can only be installed without keeping the settings.', 'Это обновление можно установить только без сохранения настроек.'));
		print_notes(filter(st.releases || [], (r) => r.upgrade != 'auto'), st.latest);
		exit(11);
	}
	printf('%s\n', tr('The settings are kept.', 'Настройки сохранятся.'));
	exit(0);
}
else if (mode == 'packages') {
	const pkgs = read_json(ARGV[2]);
	if (!pkgs) {
		printf('%s\n', tr('The list of packages could not be read.', 'Не удалось прочитать список пакетов.'));
		exit(1);
	}
	const added = pkgs.added || [], removed = pkgs.removed || [];
	const again = filter(added, (p) => p.source != 'file');
	const manual = filter(added, (p) => p.source == 'file');
	if (!length(again) && !length(removed) && !length(manual)) {
		printf('%s\n', tr('No added or removed packages.', 'Добавленных или удалённых пакетов нет.'));
		exit(10);
	}
	if (length(again))
		printf('%s: %s\n', tr('Installed again after the update', 'После обновления установятся снова'), names(again));
	if (length(removed))
		printf('%s: %s\n', tr('Firmware packages you removed will be removed again', 'Удалённые вами пакеты прошивки снова будут удалены'), names(removed));
	if (length(manual))
		printf('%s: %s\n', tr('Installed not from a repository (from a file or by a script), to be installed again by hand',
			'Установлены не из репозитория (файлом или скриптом), их нужно будет установить заново вручную'), names(manual));
	if (length(again) || length(removed)) {
		printf('%s\n', tr('After installing your packages the router restarts once.', 'После установки пакетов роутер один раз перезагрузится.'));
		exit(0);
	}
	exit(10);
}
else if (mode == 'size') {
	const st = read_json('/tmp/fwupdate/status.json');
	if (st && st.latest && st.latest.sysupgrade && st.latest.sysupgrade.size) {
		let s = sprintf('%.1f', st.latest.sysupgrade.size / 1048576.0);
		if (lang == 'ru')
			s = replace(s, '.', ',');
		print(s);
	}
	exit(0);
}
else if (mode == 'download') {
	const st = read_json('/tmp/fwupdate/status.json');
	const dl = read_json('/tmp/fwupdate/download.json');
	if (!dl || dl.state != 'ready') {
		printf('%s\n', download_error(dl));
		if (dl && dl.detail)
			printf('%s\n', dl.detail);
		exit(1);
	}
	if (!st || !st.latest || dl.tag != st.latest.tag || dl.sha256 != st.latest.sysupgrade.sha256 || !stat('/tmp/fwupdate/firmware.bin')) {
		printf('%s\n', tr('The downloaded file is damaged. Try again.', 'Загруженный файл повреждён. Попробуйте ещё раз.'));
		exit(1);
	}
	if (dl.allow_backup === false) {
		printf('%s\n', tr('This firmware cannot keep the current settings.', 'Эта прошивка не может сохранить текущие настройки.'));
		print_notes(st.releases, st.latest);
		exit(1);
	}
	exit(0);
}
exit(1);
EOF

	if [ -x /etc/init.d/fwupdate ]; then
		if /etc/init.d/fwupdate running >/dev/null 2>&1; then
			_ax_fwupdate_was_running=1
		fi
		/etc/init.d/fwupdate stop >/dev/null 2>&1 || true
	fi

	_ax_checked=1
	if [ -f "$_ax_fwupdate_dir/status.json" ]; then
		if cp -f "$_ax_fwupdate_dir/status.json" "$tmpdir/orig_status.json" 2>/dev/null; then
			_ax_orig_status_saved=1
			rm -f "$_ax_fwupdate_dir/status.json"
		fi
	fi

	PATH="$tmpdir/bin:$PATH" ucode "$tmpdir/fwupdate" check >/dev/null 2>&1 || true

	ucode "$tmpdir/render.uc" status "$opt_lang"
	rc=$?
	if [ "$rc" -eq 10 ]; then
		cleanup
		return 0
	elif [ "$rc" -ne 0 ]; then
		cleanup
		return 1
	fi

	tag=$(jsonfilter -i "$_ax_fwupdate_dir/status.json" -e '@.latest.tag' 2>/dev/null || true)

	if ! ucode "$tmpdir/fwupdate-packages" list > "$tmpdir/packages.json"; then
		msg "Error: could not read the list of packages." "Ошибка: не удалось получить список пакетов." >&2
		cleanup
		return 1
	fi

	local has_pkg_reboot=0
	ucode "$tmpdir/render.uc" packages "$opt_lang" "$tmpdir/packages.json"
	rc=$?
	if [ "$rc" -eq 0 ]; then
		has_pkg_reboot=1
	elif [ "$rc" -ne 10 ]; then
		cleanup
		return 1
	fi

	local size_mb
	size_mb=$(ucode "$tmpdir/render.uc" size "$opt_lang")
	printf '\n'
	if [ "$opt_lang" = "ru" ]; then
		printf 'Загрузка и проверка обновления (%s МБ)...\n' "${size_mb:-?}"
	else
		printf 'Downloading and verifying the update (%s MB)...\n' "${size_mb:-?}"
	fi

	_ax_did_download=1
	rm -f "$_ax_fwupdate_dir/download.json"
	PATH="$tmpdir/bin:$PATH" ucode "$tmpdir/fwupdate" download >/dev/null 2>&1 || true

	if ! ucode "$tmpdir/render.uc" download "$opt_lang"; then
		cleanup
		return 1
	fi

	msg "The update is downloaded and verified." "Обновление загружено и проверено."

	printf '\n'
	if [ "$has_pkg_reboot" = 1 ]; then
		msg "Next: the router writes the image and restarts (a few minutes without network, the session ends), and installs your packages once it is online, which restarts it once more." \
		    "Дальше роутер запишет образ и перезагрузится (сеть пропадёт на несколько минут, сессия завершится), а когда выйдет в сеть — установит ваши пакеты и перезагрузится ещё раз."
	else
		msg "Next: the router writes the image and restarts (a few minutes without network, the session ends)." \
		    "Дальше роутер запишет образ и перезагрузится (сеть пропадёт на несколько минут, сессия завершится)."
	fi

	if [ "$opt_lang" = "ru" ]; then
		printf 'Запуск через %d с (Ctrl+C — отмена):' "$COUNTDOWN"
	else
		printf 'Starting in %ds (Ctrl+C cancels):' "$COUNTDOWN"
	fi
	local i="$COUNTDOWN"
	while [ "$i" -gt 0 ]; do
		printf ' %d' "$i"
		sleep 1
		i=$((i - 1))
	done
	printf '\n'

	msg "Saving the list of packages..." "Сохранение списка пакетов..."
	_ax_requested_packages=1
	if ! ucode "$tmpdir/fwupdate-packages" request "$tag"; then
		msg "The list of packages could not be saved." "Не удалось сохранить список пакетов." >&2
		cleanup
		return 1
	fi

	if [ ! -e "$_ax_fwupdate_keep" ]; then
		mkdir -p /lib/upgrade/keep.d
		printf '/etc/fwupdate/\n' > "$_ax_fwupdate_keep" || {
			msg "The update could not be started. Try again." "Не удалось начать обновление. Попробуйте ещё раз." >&2
			cleanup
			return 1
		}
		_ax_created_keep=1
	fi

	msg "The router is installing the update. Do not unplug it." "Роутер устанавливает обновление. Не отключайте его от питания."
	_ax_flashing=1
	if ! /sbin/sysupgrade "$_ax_fwupdate_dir/firmware.bin" >"$tmpdir/sysupgrade.log" 2>&1; then
		if ubus -t 2 call system board >/dev/null 2>&1; then
			_ax_flashing=0
			if [ -s "$tmpdir/sysupgrade.log" ]; then
				cat "$tmpdir/sysupgrade.log" >&2
			fi
			msg "The update could not be started. Try again." "Не удалось начать обновление. Попробуйте ещё раз." >&2
			cleanup
			return 1
		fi
	fi
	cleanup
	return 0
}

ax3200_update "$@"
