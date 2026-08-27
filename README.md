# Google OTA Prober

Утилита опрашивает Google OTA API для устройств из `config/`, определяет доступное обновление и создаёт GitHub Release.

## Что теперь публикуется в Release

При найденном обновлении workflow **обязательно скачивает полную OTA-прошивку с официального Google OTA URL** и загружает сами данные прошивки в GitHub Release.

- Если OTA помещается в лимит одного Release asset, в `Resources / Assets` появляется один файл вида `DEVICE-VERSION-FULL-OTA.zip` — это полноценная прошивка.
- Если OTA превышает лимит одного файла GitHub, исходный ZIP автоматически делится на `...FULL-OTA.zip.part-001`, `part-002`, ... . Это части самой прошивки, а не downloader-файлы. После объединения получается исходный OTA ZIP байт-в-байт.
- Рядом публикуется `SHA256SUMS-*.txt` для проверки целостности.

Архивы со ссылками и `download.sh`/`download.ps1` больше не создаются.

## Ручной запуск

```bash
python -m pip install -r requirements.txt
python probe.py -c config/config.yml
bash release.sh
```

Для публикации через `release.sh` должен быть установлен GitHub CLI (`gh`) и задан `GH_TOKEN` с правом записи Releases.

Для локального скачивания OTA без GitHub Release также доступно:

```bash
python probe.py -c config/config.yml --download
```
