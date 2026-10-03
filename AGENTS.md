# AGENTS.md

Текущая директория является форком проекта github.com/lovell/sharp (библиотека для Node.js; технологии: Node.js, C++, gyp, сборка libvips).
Upstream не поддерживает HEIC/HEVC из коробки: поддержка доступна только через установленную в системе libvips.

Задача форка: встроить поддержку HEIC/HEVC непосредственно в prebuilt-бинарники sharp.

Работая в этом репозитории, задавай вопросы до изменения или выдачи кода, если требования неоднозначны.
Предлагай варианты с рекомендацией. Пользователь пишет на русском.

## Требования (согласованы с пользователем)

- **Платформы:**
  - **linux-x64 (glibc):** рабочее окружение — TypeScript + Node 24 приложение в Docker-образе `node:24-trixie-slim` (Debian 13).
  - **win32-x64:** только для локальной разработки, нативно, без Docker и WSL. Node 24 x64.
  - Прочие OS и архитектуры не нужны.
- **Форматы:**
  - декодирование: JPEG, PNG, WebP, HEIC, TIFF, AVIF;
  - кодирование: WebP.
  - Остальные форматы убраны из сборки, а не заблокированы в рантайме.
  - JPEG/PNG/TIFF-вывод остался, потому что эти кодеры неотделимы от декодеров; блокировать их в рантайме пользователь не захотел.
  - HEIF/AVIF-вывод недоступен: x265 (GPL) и AV1-энкодер не собираются.
  - `png({ palette: true })` молча даёт PNG без палитры: libimagequant исключён.
- **Сохранены:** ICC-профили (lcms) и EXIF (libexif). Ultra HDR / gain maps (libultrahdr) убраны.
- **Распространение:** один локальный `sharp-<version>.tgz` с обеими платформами, без npm-реестра. Приложение подключает его как `"sharp": "file:vendor/sharp-0.35.5.tgz"`.
- **CI:** нет. Всё собирается на этой Debian-машине: x86_64, ~2 ГБ RAM, без Docker, sudo без пароля.
- **Тесты upstream** для исключённых форматов пропускаются по доступности формата, а не удаляются.

## Текущее состояние (2026-10-03)

- Работа закоммичена в ветку `heic` поверх upstream `1189cf49` (sharp 0.35.5); не отправлена в origin.
  Первым коммитом идёт этот файл, за ним шесть коммитов реализации.
  Порядок коммитов реализации:
  1. скрипты сборки libvips;
  2. тесты и пропуски;
  3. использование `vendor/`;
  4. Windows-сборка `sharp.node`;
  5. упаковка в один tarball;
  6. удаление кода других платформ.
- `npm test` проходит: 1745 тестов пройдено, 0 упало, 70 пропущено.
- Linux-пакет проверен в chroot образа `node:24-trixie-slim`. Windows-пакет проверен пользователем на реальной Windows.
- Remote `upstream` указывает на https://github.com/lovell/sharp.git, `origin` — на форк.

## Как устроено

| Что | Где |
|---|---|
| Сборка libvips и зависимостей (обе платформы), описание, prerequisites | [scripts/libvips-heic/README.md](scripts/libvips-heic/README.md), [scripts/libvips-heic/build.sh](scripts/libvips-heic/build.sh) |
| Версии зависимостей (как в sharp-libvips 1.3.4 + libde265) | [scripts/libvips-heic/versions.properties](scripts/libvips-heic/versions.properties) |
| Кросс-компиляция `sharp.node` для Windows | [scripts/libvips-heic/build-sharp-win32.sh](scripts/libvips-heic/build-sharp-win32.sh), [Toolchain-win32-x64.cmake](scripts/libvips-heic/Toolchain-win32-x64.cmake) |
| Лицензии сторонних библиотек, патенты HEVC | [scripts/libvips-heic/THIRD-PARTY-NOTICES.md](scripts/libvips-heic/THIRD-PARTY-NOTICES.md) |
| Поиск libvips в `vendor/` при сборке, приоритет над глобальной libvips | [lib/libvips.mjs](lib/libvips.mjs) (`vendorSharpLibvipsDir`) |
| `sharp.versions` из `vendor/`, флаги HEIF input/output | [lib/utility.mjs](lib/utility.mjs) |
| rpath на `vendor/` для Linux | [src/binding.gyp](src/binding.gyp) |
| Загрузка бинарника: первым пробуется `src/build/Release/sharp-<platform>-<version>.node` | [lib/sharp.mjs](lib/sharp.mjs) |
| Состав tarball (`files`), `os`/`cpu`, скрипты сборки | [package.json](package.json) |
| Тесты HEIC и минимальной сборки | [test/unit/heic.js](test/unit/heic.js), фикстура `test/fixtures/hevc.heic` |
| Пропуск тестов для исключённых форматов | `unsupported(...)` в [test/fixtures/index.js](test/fixtures/index.js) |

- **Linux:** `vendor/sharp-libvips-linux-x64/lib/libvips-cpp.so.8.18.7`.
  - Внутрь статически вшиты glib, gobject, gio и все кодеки.
  - Зависит только от libc, libm, libstdc++ и libgcc_s.
  - `sharp-linux-x64-<version>.node` находит её через rpath `$ORIGIN/../../../vendor/...`.
- **Windows:** libvips собирается статически и целиком вшивается в `sharp-win32-x64-<version>.node`.
  - Компилятор — llvm-mingw (clang и libc++), а не MSVC. Это допустимо, потому что Node-API имеет C ABI.
  - Файл зависит только от системных DLL (UCRT, kernel32 и т. п.) и от `node.exe`.
  - Статика выбрана потому, что glib, собранная статически, не экспортирует символы из DLL.
- **Каталоги `vendor/` и `.libvips-build/`** не в git: это результаты сборки.

## Сборка с нуля

Prerequisites описаны в [scripts/libvips-heic/README.md](scripts/libvips-heic/README.md):
- apt-пакеты;
- llvm-mingw в `~/.local/llvm-mingw`;
- meson ≥ 1.11 и ninja ставятся автоматически в `.libvips-build/venv`.

Rust не нужен: librsvg исключён.

```sh
npm install
npm run build:libvips-heic                      # linux-x64
PLATFORM=win32-x64 npm run build:libvips-heic   # win32-x64
npm run package-heic                            # dist + оба sharp.node + sharp-<version>.tgz
npm test                                        # lint + unit (на Linux)
```

Шаги сборки возобновляемые: готовые зависимости отмечаются файлами `.libvips-build/<platform>/deps/.done-<name>`. Чтобы пересобрать шаг, удали его отметку.

## Подводные камни, уже решённые

- **libvips без expat не собирается:** это обязательная зависимость libvips.
- **fontconfig и новые зависимости требуют meson ≥ 1.11.** В Debian 13 есть только 1.7, поэтому meson ставится через venv.
- **Windows и `dllimport`.** Нужны define `G_INTL_STATIC_COMPILATION`, `LIBDE265_STATIC_BUILD`, `LIBHEIF_STATIC_BUILD` и `G*_STATIC_COMPILATION`, иначе заголовки объявляют символы как `dllimport`.
- **Windows и флаги компиляции.** На Windows нельзя `-fPIC` и `-fno-asynchronous-unwind-tables`: SEH-таблицы нужны для исключений.
- **meson при кросс-компиляции игнорирует `CFLAGS`.** Флаги передаются через сгенерированный cross-file.
- **Поле `"libc"` в `package.json` ломает установку на Windows**, поэтому его нет. Следствие: на Alpine (musl) пакет ставится, но падает при загрузке.
- **Наличие libde265 проверяется по строке `libde265 HEVC` (`strings`).** Символы `de265_` скрыты через `--exclude-libs` и strip.
- **Проверка в Docker-образе без Docker:** слои `node:24-trixie-slim` скачиваются из registry API и запускаются через chroot.

## Обновление с upstream

```sh
git fetch upstream --tags
git rebase upstream/main heic        # или на тег релиза
```

- **Конфликты ожидаются в коммитах 5–6:** `package.json` и `npm/*`, где upstream каждый релиз меняет версии. Коммит 6 проще пересоздать, чем мержить.
- **Если upstream обновил sharp-libvips,** перенеси версии из его `versions.properties` в `scripts/libvips-heic/versions.properties`.
  - Сравни `build/posix.sh` нового релиза с `scripts/libvips-heic/build.sh` (новые флаги, патчи).
  - Пересобери обе платформы и прогони `npm test`.
- **Удалённые проверки** (yarn locator, wasm, MSVC) не возвращать.

## Открытые вопросы

- `.github/workflows` унаследован от upstream и в форке не работает: не трогали.
- Мёртвый код для macOS в `binding.gyp` и загрузчики других платформ в `lib/sharp.mjs`: оставлены.
- Версия пакета совпадает с upstream (`0.35.5`). При риске смешения с оригиналом стоит дать отдельную версию, например `0.35.5-heic.1`.
