# Google OTA prober

This program obtains OTA update URLs from Google's Android check-in service for a configured device and can optionally download the OTA package.

## Requirements

- Python 3
- Stock ROM build fingerprint data

## Local usage

1. Install dependencies: `python -m pip install -r requirements.txt`
2. Edit `config/config.yml`.
3. Run: `python probe.py -c config/config.yml`
4. To download the detected OTA locally: `python probe.py -c config/config.yml --download`

Telegram is optional. Set `BOT_TOKEN` and `CHAT_ID` only if you want notifications.

## GitHub Releases

The included GitHub Actions workflow checks OTA updates every hour. For every detected update it creates a GitHub Release and attaches a file named similar to:

`firmware-download-DEVICE-UPDATE.zip`

That small archive contains:

- `firmware-url.txt` — direct official OTA URL;
- `update-info.json` — update metadata;
- `download.sh` — Linux/macOS downloader with resume support;
- `download.ps1` — Windows PowerShell downloader;
- `download.bat` — Windows CMD downloader using curl;
- `README.txt` — usage information.

This makes the firmware downloadable from every release without storing a multi-gigabyte OTA in the repository.

For a manually started workflow, enable **Also download and attach the complete OTA package** to additionally try uploading the complete firmware ZIP to the GitHub Release. If GitHub rejects a very large OTA asset, the downloader archive remains attached and usable.

## Limitations

- Works only for devices whose OTA updates are served through Google's check-in/OTA infrastructure.
- Usually returns the newest OTA applicable to the configured source build.
- Incremental updates may be returned instead of full packages.
