#!/usr/bin/env python3

import argparse
import datetime
import gzip
import json
import os
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

import requests
import yaml
from google.protobuf import text_format

from checkin import checkin_generator_pb2
from utils import functions

CHECKIN_URL = "https://android.googleapis.com/checkin"


def send_telegram_message(bot_token, chat_id, message, button_text, button_url):
    url = f"https://api.telegram.org/bot{bot_token}/sendMessage"
    payload = {
        "chat_id": chat_id,
        "text": message,
        "parse_mode": "MarkdownV2",
        "reply_markup": {
            "inline_keyboard": [[{"text": button_text, "url": button_url}]]
        },
    }
    response = requests.post(url, json=payload, timeout=30)
    response.raise_for_status()
    print("Telegram notification sent successfully")
    return response.json()


def escape_markdown_v2(text):
    escape_chars = r"_*[]()~`>#+-=|{}.!"
    return "".join("\\" + char if char in escape_chars else char for char in str(text))


def remove_html_tags(text):
    text = re.sub(r"<.*?>", "", text)
    text = re.sub(r"\s*\(http[s]?://\S+\)?", "", text)
    return text.strip()


def load_config(config_file):
    with open(config_file, "r", encoding="utf-8") as file:
        return yaml.safe_load(file)


def load_update_info(path="update_info.json"):
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as file:
            return json.load(file)
    return {}


def write_update_info(update_info, path="update_info.json"):
    with open(path, "w", encoding="utf-8") as file:
        json.dump(update_info, file, indent=2, ensure_ascii=False)
        file.write("\n")


def safe_filename(value):
    value = re.sub(r"[^A-Za-z0-9._-]+", "_", value.strip())
    return value.strip("._-") or "ota-update"


def download_ota(url, output_dir, preferred_name=""):
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    remote_name = Path(urlparse(url).path).name
    filename = preferred_name or remote_name or "ota-update.zip"
    if not Path(filename).suffix:
        filename += ".zip"
    filename = safe_filename(filename)
    output_path = output_dir / filename

    print(f"Downloading OTA to {output_path} ...")
    with requests.get(url, stream=True, timeout=(30, 300), allow_redirects=True) as response:
        response.raise_for_status()
        total = int(response.headers.get("content-length", 0))
        downloaded = 0
        with open(output_path, "wb") as file:
            for chunk in response.iter_content(chunk_size=1024 * 1024):
                if not chunk:
                    continue
                file.write(chunk)
                downloaded += len(chunk)
                if total:
                    percent = downloaded * 100 / total
                    print(f"\r{downloaded / 1024 / 1024:.1f} MiB / {total / 1024 / 1024:.1f} MiB ({percent:.1f}%)", end="", flush=True)
        if total:
            print()

    print(f"OTA downloaded: {output_path}")
    return str(output_path)


def main():
    parser = argparse.ArgumentParser(description="Probe Google's OTA service for an Android device.")
    parser.add_argument("--debug", action="store_true", help="Save the protobuf response to debug.txt")
    parser.add_argument("-c", "--config", default="config/config.yml", help="Path to the YAML config file")
    parser.add_argument("--download", action="store_true", help="Download the OTA package when an update is found")
    parser.add_argument("--download-dir", default="downloads", help="Directory used by --download")
    parser.add_argument("--no-telegram", action="store_true", help="Do not send a Telegram notification")
    args = parser.parse_args()

    config = load_config(args.config)
    required = ["build_tag", "incremental", "android_version", "model", "device", "oem", "product"]
    missing = [key for key in required if key not in config]
    if missing:
        raise SystemExit(f"Missing config keys: {', '.join(missing)}")

    build_tag = str(config["build_tag"])
    incremental = str(config["incremental"])
    android_version = str(config["android_version"])
    model = str(config["model"])
    device = str(config["device"])
    oem = str(config["oem"])
    product = str(config["product"])

    headers = {
        "accept-encoding": "gzip, deflate",
        "content-encoding": "gzip",
        "content-type": "application/x-protobuffer",
        "user-agent": f"Dalvik/2.1.0 (Linux; U; Android {android_version}; {model} Build/{build_tag})",
    }

    checkinproto = checkin_generator_pb2.AndroidCheckinProto()
    payload = checkin_generator_pb2.AndroidCheckinRequest()
    build = checkin_generator_pb2.AndroidBuildProto()
    response = checkin_generator_pb2.AndroidCheckinResponse()

    build.id = f"{oem}/{product}/{device}:{android_version}/{build_tag}/{incremental}:user/release-keys"
    build.timestamp = 0
    build.device = device
    checkinproto.build.CopyFrom(build)
    checkinproto.roaming = "WIFI::"
    checkinproto.userNumber = 0
    checkinproto.deviceType = 2
    checkinproto.voiceCapable = False
    checkinproto.unknown19 = "WIFI"

    payload.imei = functions.generateImei()
    payload.id = 0
    payload.digest = functions.generateDigest()
    payload.checkin.CopyFrom(checkinproto)
    payload.locale = "en-US"
    payload.timeZone = "America/New_York"
    payload.version = 3
    payload.serialNumber = functions.generateSerial()
    payload.macAddr.append(functions.generateMac())
    payload.macAddrType.extend(["wifi"])
    payload.fragment = 0
    payload.userSerialNumber = 0
    payload.fetchSystemUpdates = 1
    payload.unknown30 = 0

    compressed_payload = gzip.compress(payload.SerializeToString())
    print(f"Checking device... {model}")
    print(f"Current version... {incremental}")

    try:
        request = requests.post(CHECKIN_URL, data=compressed_payload, headers=headers, timeout=60)
        request.raise_for_status()
        response.ParseFromString(request.content)
    except (requests.RequestException, Exception) as exc:
        print(f"Unable to obtain OTA URL. Error: {exc}", file=sys.stderr)
        return 2

    if args.debug:
        with open("debug.txt", "w", encoding="utf-8") as file:
            file.write(text_format.MessageToString(response))

    settings = {}
    for entry in response.setting:
        try:
            name = entry.name.decode(errors="replace")
            value = entry.value.decode(errors="replace")
            settings[name] = value
        except AttributeError:
            continue

    download_url = ""
    for entry in response.setting:
        if b"https://android.googleapis.com" in entry.value:
            download_url = entry.value.decode(errors="replace")
            break

    found = bool(download_url)
    config_name = Path(args.config).stem
    update_info = load_update_info()
    info = {
        "found": found,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "device": model,
        "codename": device,
        "current_incremental": incremental,
        "current_build_tag": build_tag,
        "android_version": android_version,
    }

    if found:
        info.update({
            "title": settings.get("update_title", "") or f"{device}-{datetime.date.today().isoformat()}",
            "description": remove_html_tags(settings.get("update_description", "")),
            "url": download_url,
            "size": settings.get("update_size", ""),
        })
        print("Found update.")
        print(f"Title: {info['title']}")
        print(f"URL: {download_url}")

        if args.download:
            preferred_name = f"{device}-{safe_filename(info['title'])}.zip"
            try:
                info["downloaded_file"] = download_ota(download_url, args.download_dir, preferred_name)
            except requests.RequestException as exc:
                print(f"OTA download failed: {exc}", file=sys.stderr)
                info["download_error"] = str(exc)
    else:
        print("There are no new updates for your device.")

    update_info[config_name] = info
    write_update_info(update_info)

    bot_token = os.environ.get("bot_token") or os.environ.get("BOT_TOKEN")
    chat_id = os.environ.get("chat_id") or os.environ.get("CHAT_ID")
    if found and not args.no_telegram and bot_token and chat_id:
        message = f"*Update available for {escape_markdown_v2(model.upper())}*\n\n"
        message += f"*Title:*\n{escape_markdown_v2(info['title'])}\n\n"
        if info["description"]:
            message += f"*Description:*\n{escape_markdown_v2(info['description'])}\n\n"
        if info["size"]:
            message += f"*Size:* {escape_markdown_v2(info['size'])}\n\n"
        try:
            send_telegram_message(bot_token, chat_id, message, "Google OTA Link", download_url)
        except requests.RequestException as exc:
            print(f"Telegram notification failed: {exc}", file=sys.stderr)
    elif found and not args.no_telegram:
        print("Telegram secrets are not configured; notification skipped.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
