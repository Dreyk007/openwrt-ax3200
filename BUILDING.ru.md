### [English](BUILDING.md) · Русский

# Сборка прошивки

[← README](README.ru.md)

В корне репозитория лежат seed-конфигурация [`ax3200.config`](ax3200.config) (сгенерирована `./scripts/diffconfig.sh`) и оверлей корневой ФС [`files/`](files/).

## Автоматическая сборка через `build.sh`
[`build.sh`](build.sh) устанавливает зависимости для сборки (опционально, через `apt`), обновляет фиды, накладывает на пакеты фидов патчи из `feeds-patches/<фид>/*.patch`, применяет `ax3200.config`, синхронизирует `vermagic` ядра с официальным репозиторием или его зеркалами (если не ответил ни один сервер, берётся список этого релиза из репозитория; если его нет, сборка останавливается), компилирует прошивку, проверяет разметку `factory.bin` и формирует `sha256sums`.

Из-за `CONFIG_ALL_KMODS=y` (см. [README, раздел 7](README.ru.md#7-совместимость-с-официальным-репозиторием-vermagic--apk)) собираются все ~1100 пакетов модулей ядра: первая сборка идёт заметно дольше, а `bin/` вырастает примерно до 140 МБ; в прошивку при этом попадают только выбранные модули. `kmod-rtl8812au-ct` исключён, так как не собирается с GCC 15 (у AX6S нет USB-порта).

На чистой Ubuntu 24.04 / 26.04 LTS или Debian:
```bash
git clone -b xq-25.12 https://github.com/Dreyk007/openwrt-ax3200.git
cd openwrt-ax3200
./build.sh --install-deps
```
Последующие сборки:
```bash
./build.sh        # все потоки CPU
./build.sh -j4    # своё число параллельных задач
./build.sh --ccache   # кэш компилятора в .ccache: следующие сборки перекомпилируют только изменённое
```

## Сборка и релиз через GitHub Actions
Workflow [`.github/workflows/build-ax3200.yml`](.github/workflows/build-ax3200.yml) запускает `build.sh --install-deps` на раннере GitHub (по умолчанию Ubuntu 26.04) и публикует файлы из `bin/targets/mediatek/mt7622/` — те же образы, `sha256sums` и buildinfo, что и при локальной сборке — как релиз GitHub. Запускается только вручную: *Actions → Build AX3200 firmware → Run workflow*. Параметры:
* **Release tag** — пусто для следующего `v<версия OpenWrt>-ax3200-r<N>`;
* **Publish as a pre-release** — опубликовать как пре-релиз; роутеры не предлагают пре-релизы как обновление;
* **Update from LuCI** — `auto`; `reset`, если версию можно установить только без сохранения настроек; `manual`, если её нужно устанавливать вручную (кнопки обновления нет). Для `reset` и `manual` на странице обновления роутера показываются пояснения и, по желанию, ссылка на инструкцию;
* **Runner image** — `ubuntu-26.04` или запасной `ubuntu-24.04`.

Полная сборка на 4-ядерном раннере занимает около двух часов; исходники (`dl/`) и кэш компилятора (`.ccache`, `build.sh --ccache`) сохраняются между запусками, поэтому следующие сборки идут быстрее. Если сборка упала, её лог прикладывается к запуску как артефакт `build-log`.

**Проверка скачанных файлов.** Для каждого публикуемого файла workflow подписывает подтверждение происхождения сборки ([`actions/attest`](https://github.com/actions/attest), Sigstore). Оно связывает SHA256 файла с запуском workflow и коммитом, из которого файл собран, и записывается в публичный журнал прозрачности, поэтому для файла, собранного не этим workflow, его получить нельзя. Релизы неизменяемые: файлы и теги после публикации тоже не подменить. Проверить скачанный образ можно через [GitHub CLI](https://cli.github.com/):
```bash
gh attestation verify openwrt-mediatek-mt7622-xiaomi_redmi-router-ax6s-squashfs-sysupgrade.itb --repo Dreyk007/openwrt-ax3200
gh release verify-asset <тег релиза> openwrt-mediatek-mt7622-xiaomi_redmi-router-ax6s-squashfs-sysupgrade.itb --repo Dreyk007/openwrt-ax3200
```

> В репозитории также лежат собственные CI-workflow OpenWrt (`kernel.yml`, `packages.yml`, `toolchain.yml`, `github-release.yml`, …). Они предназначены для openwrt/openwrt: после включения Actions в форке отключите их (*Actions → workflow → ⋯ → Disable workflow* или `gh workflow disable <файл>`), иначе они будут запускаться на push и на теги `v*`.

## Ручная сборка
```bash
# 1. Обновление и установка фидов
./scripts/feeds update -a
./scripts/feeds install -a

# 2. Загрузка seed-конфигурации AX3200 и раскрытие всех зависимостей
cp ax3200.config .config
make defconfig

# 3. Загрузка официального vermagic ядра (обязательно после перехода на новый релиз 25.12.x)
./vermagic_update.sh mediatek mt7622

# 4. Загрузка исходников и компиляция
make download -j$(nproc)
make -j$(nproc)
```

> **Примечание:** в отличие от ядра Linux, `make defconfig` в OpenWrt **не** сбрасывает `.config` к умолчаниям — он дополняет скопированную в `.config` короткую seed-конфигурацию всеми зависимыми параметрами.

## Изменение конфигурации
Меняйте конфигурацию через `make menuconfig` и сохраняйте результат обратно как seed — не редактируйте `ax3200.config` вручную. Оставляйте `CONFIG_ALL_KMODS=y` и `# CONFIG_KERNEL_KALLSYMS is not set`: они нужны для совместимости с официальными kmods.
```bash
cp ax3200.config .config && make defconfig
make menuconfig
./scripts/diffconfig.sh > ax3200.config
```

## Обновление до нового релиза OpenWrt
В [UPGRADING.md](UPGRADING.md) (на английском) подробно описано, как влить в эту ветку новый минорный релиз (например, 25.12.7) и как перенести сборку на новый мажорный релиз: обновление vermagic, сверка конфигурации ядра с официальным SDK и проверка на устройстве.
