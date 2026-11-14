<p align="center">
  <a href="README.en.md">English</a> · <strong>Русский</strong>
</p>

<p align="center"><img src="assets/hero.svg" alt="MetaKeep — Metadata, kept." width="100%"></p>

<p align="center">
  <a href="https://github.com/nordz0r/metadata-preserver/actions/workflows/ci.yml"><img src="https://github.com/nordz0r/metadata-preserver/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/nordz0r/metadata-preserver/releases"><img src="https://img.shields.io/github/v/release/nordz0r/metadata-preserver?display_name=tag" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-65e6d0.svg" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/python-3.10%2B-75a7ff.svg" alt="Python 3.10+">
</p>

<p align="center"><b>Сохраняйте метаданные, а не только байты.</b><br>Copy, download и convert с проверяемым sidecar-манифестом.</p>

**MetaKeep** — небольшая кроссплатформенная CLI-утилита для копирования, скачивания и конвертации файлов без тихой потери доступных метаданных. Она сохраняет файловые атрибуты, фиксирует provenance в JSON sidecar, проверяет результат и честно сообщает, что конкретная ОС или конвертер перенести не смогли.

> MetaKeep не обещает невозможного: HTTP-сервер не отдаёт исходные ACL или Finder tags, а формат конвертации может не поддерживать некоторые встроенные теги. Недоступные для переноса значения остаются в sidecar, а ограничения показываются явно.

## Содержание

[Возможности](#возможности) · [Быстрый старт](#быстрый-старт) · [Команды](#команды) · [Что сохраняется](#что-сохраняется) · [ExifTool и конвертация](#exiftool-и-конвертация) · [Безопасность](#безопасность) · [Разработка](#разработка)

## Возможности

- 📦 **Metadata-aware copy** — файлы и каталоги, временная копия, восстановление метаданных и проверка до установки результата.
- 🌐 **Download provenance** — выбранные HTTP-заголовки (`ETag`, `Last-Modified` и др.), SHA-256 и домен источника рядом с файлом.
- 🔄 **Converter wrapper** — запускает выбранный конвертер без shell-интерпретации и переносит поддерживаемые метаданные.
- 🧾 **Portable sidecar** — `*.metakeep.json` хранит то, что не может безопасно или корректно поместиться в целевой формат.
- ✅ **Verify / restore** — сверка хеша и атрибутов; восстановление файловых метаданных из доверенного манифеста.
- 🔒 **Без перезаписи** — существующий файл назначения не трогается; перед заменой сначала нужно явно решить конфликт.
- 🪶 **Без обязательных зависимостей** — Python standard library; ExifTool и POSIX ACL tools подключаются опционально.

## Быстрый старт

Требуется Python 3.10 или новее.

```bash
python -m pip install .
```

Скопировать файл и сохранить манифест:

```bash
metakeep copy "Original Photo.tif" "archive/Original Photo.tif"
metakeep verify "archive/Original Photo.tif"
```

Скачать файл, записав HTTP provenance:

```bash
metakeep download https://example.org/photo.jpg photo.jpg
```

Конвертировать и перенести доступные файловые и встроенные метаданные:

```bash
metakeep convert photo.tif photo.jpg -- magick {input} {output}
```

Установите [ExifTool](https://exiftool.org/) для переноса встроенных EXIF/IPTC/XMP и других поддерживаемых тегов. Режим строгой проверки завершится ошибкой, если ExifTool отсутствует:

```bash
metakeep convert --require-embedded photo.tif photo.jpg -- magick {input} {output}
```

> Каждый выходной файл получает соседний sidecar: `photo.jpg.metakeep.json`. Храните его вместе с файлом, если метаданные важны для последующей проверки или восстановления.

## Команды

| Команда | Что делает |
|:--|:--|
| `metakeep copy SRC DEST` | Копирует файл или дерево каталогов, переносит доступные filesystem metadata и проверяет содержимое. |
| `metakeep download URL DEST` | Скачивает HTTP(S)-файл, записывает provenance и ставит mtime по `Last-Modified`, если сервер его прислал. |
| `metakeep convert SRC DEST -- COMMAND {input} {output}` | Запускает конвертер без shell, затем переносит файловые метаданные и, с ExifTool, поддерживаемые встроенные теги. |
| `metakeep inspect PATH` | Показывает метаданные файла/каталога и имена xattrs без вывода их бинарных значений. |
| `metakeep verify PATH` | Проверяет содержимое и метаданные по соседнему sidecar. |
| `metakeep restore PATH` | Восстанавливает filesystem metadata по sidecar. Используйте только с доверенным манифестом. |

Для нестандартного расположения sidecar используйте `--manifest PATH` у `verify` или `restore`. Флаг `--owner` дополнительно пытается восстановить числовые UID/GID и обычно требует root:

```bash
metakeep verify archive/file.bin --owner
metakeep restore archive/file.bin --manifest backup/file.bin.metakeep.json --owner
```

Путь/параметры URL по умолчанию не записываются: sidecar хранит только origin. `--record-url` сохраняет полный URL, включая query-параметры; не включайте его для URL с токенами или credentials.

## Что сохраняется

| Метаданные | Copy | Download | Convert |
|:--|:--:|:--:|:--:|
| SHA-256 содержимого | ✅ проверяется | ✅ записывается | ✅ записывается |
| POSIX mode и время доступа/изменения | ✅ переносится | ✅ `mtime` из HTTP, если есть | ✅ переносится с источника |
| Extended attributes / macOS resource forks | ✅ где позволяет ОС | ✅ что появилось у локального файла | ✅ переносится и записывается в sidecar |
| POSIX ACL | ✅ при наличии `getfacl`/`setfacl` | — | ✅ при наличии ACL tools |
| UID/GID | 🧾 записываются; применение через `--owner` | 🧾 записываются | 🧾 записываются; применение через `--owner` |
| EXIF, IPTC, XMP и другие embedded tags | байты не меняются | из HTTP недоступны | перенос ExifTool, если формат поддерживается |
| Выбранные HTTP headers и origin | — | ✅ записываются | — |
| Creation/birth time | 🧾 записывается, если ОС отдаёт | недоступно из HTTP | 🧾 источник хранится в sidecar |

`copy` не перезаписывает назначения. `convert` принимает только один обычный файл на вход. Для каталога используйте `copy`.

## ExifTool и конвертация

MetaKeep не пытается угадать синтаксис конкретного конвертера. После `--` передайте argv программы и используйте два обязательных маркера:

```bash
metakeep convert input.png output.webp -- magick {input} -quality 88 {output}
```

Команда запускается напрямую, без `sh -c`/`shell=True`. Если ExifTool установлен и обнаружил embedded metadata, MetaKeep запускает перенос `-TagsFromFile ... -all:all`. Если ExifTool отсутствует, source metadata остаётся в `source_metadata` внутри sidecar; предупреждение не даёт принять отсутствие переноса за успех. `--require-embedded` требует установленный ExifTool. Поддержка зависит от исходного и целевого форматов: значения, которые целевой формат не умеет хранить, доступны в sidecar, но не появятся в самом файле.

После конвертации MetaKeep переносит mode, timestamps, xattrs и доступные ACL, затем проверяет выходной файл. Создание времени (birth time), владельца без `--owner` и несовместимые ACL могут потребовать ручной проверки.

## Безопасность

- Sidecar содержит значения xattrs, numeric owner, timestamps, SHA-256 и может включать встроенные теги вроде GPS-координат. Храните его с тем же уровнем защиты, что и исходный файл.
- Полный URL не сохраняется без `--record-url`; query string может содержать токены.
- `restore` применяет данные из sidecar к файловой системе. Не восстанавливайте metadata из недоверенного манифеста.
- Converter исполняется с правами текущего пользователя. Вызывайте только доверенную программу и не передавайте непроверенные команды.
- См. [SECURITY.md](SECURITY.md) и [MIT License](LICENSE).

## Разработка

```bash
python -m unittest discover -s tests -v
python -m metakeep --help
```

Проект не требует runtime-зависимостей. CI тестирует Python 3.10–3.13 на Linux и macOS. История изменений — в [CHANGELOG.md](CHANGELOG.md).
