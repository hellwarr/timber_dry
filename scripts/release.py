#!/usr/bin/env python3
import os
import sys
import json
import re
import argparse
import subprocess
import urllib.request
import urllib.parse
import urllib.error
import uuid
from datetime import datetime

TOKEN = "8763563551:AAHn8Tv2rYth6bFa_ROJKXd5uN8wxKN4piI"
BASE_URL = f"https://api.telegram.org/bot{TOKEN}"
PROJECT_DIR = "/Users/astraagnon/Projects/timber_dry"
PUBSPEC_PATH = os.path.join(PROJECT_DIR, "pubspec.yaml")
CHANGELOG_PATH = os.path.join(PROJECT_DIR, "CHANGELOG.md")
APK_PATH = os.path.join(PROJECT_DIR, "build/app/outputs/flutter-apk/app-release.apk")
CONFIG_PATH = os.path.join(PROJECT_DIR, "telegram_config.json")

def load_config():
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {"chat_id": "-1003967522645", "thread_id": "204"}

def save_config(chat_id, thread_id=None):
    cfg = {"chat_id": str(chat_id), "thread_id": str(thread_id) if thread_id else None}
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    return cfg

def get_current_version():
    with open(PUBSPEC_PATH, "r", encoding="utf-8") as f:
        content = f.read()
    match = re.search(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)", content, re.MULTILINE)
    if match:
        return match.group(1), int(match.group(2))
    return "1.0.0", 1

def bump_version(bump_type="patch"):
    ver_str, build_num = get_current_version()
    major, minor, patch = map(int, ver_str.split("."))
    
    if bump_type == "major":
        major += 1
        minor = 0
        patch = 0
    elif bump_type == "minor":
        minor += 1
        patch = 0
    else:
        patch += 1
        
    build_num += 1
    new_version_name = f"{major}.{minor}.{patch}"
    new_full_version = f"{new_version_name}+{build_num}"
    
    with open(PUBSPEC_PATH, "r", encoding="utf-8") as f:
        content = f.read()
    
    new_content = re.sub(r"^version:\s*.*$", f"version: {new_full_version}", content, flags=re.MULTILINE)
    with open(PUBSPEC_PATH, "w", encoding="utf-8") as f:
        f.write(new_content)
        
    return new_version_name, build_num

def update_changelog(version_name, notes):
    date_str = datetime.now().strftime("%Y-%m-%d")
    entry = f"\n## [{version_name}] - {date_str}\n{notes}\n"
    
    existing = ""
    if os.path.exists(CHANGELOG_PATH):
        with open(CHANGELOG_PATH, "r", encoding="utf-8") as f:
            existing = f.read()
            
    with open(CHANGELOG_PATH, "w", encoding="utf-8") as f:
        f.write("# 🪵 CHANGELOG — TimberDry Pro\n" + entry + existing.replace("# 🪵 CHANGELOG — TimberDry Pro\n", ""))

def send_telegram_apk(chat_id, thread_id, version_name, build_num, notes):
    arm64_apk = os.path.join(PROJECT_DIR, "build/app/outputs/flutter-apk/app-arm64-v8a-release.apk")
    universal_apk = os.path.join(PROJECT_DIR, "build/app/outputs/flutter-apk/app-release.apk")

    if os.path.exists(arm64_apk):
        actual_apk = arm64_apk
    elif os.path.exists(universal_apk):
        actual_apk = universal_apk
    else:
        print("❌ APK file not found at", APK_PATH)
        return False

    file_size_mb = os.path.getsize(actual_apk) / (1024 * 1024)
    if len(notes) > 700:
        notes = notes[:697] + "..."
    caption = (
        f"🪵 *TimberDry Pro v{version_name} (Build {build_num})*\n"
        f"_Контроль сушильних камер деревини_\n\n"
        f"📝 *Що входить у реліз:*\n{notes}\n\n"
        f"📦 *Розмір*: {file_size_mb:.1f} MB\n"
        f"⚙️ *Статус*: Релізна збірка APK"
    )

    boundary = f"----WebKitFormBoundary{uuid.uuid4().hex}"
    body = bytearray()
    
    fields = [("chat_id", str(chat_id)), ("caption", caption), ("parse_mode", "Markdown")]
    if thread_id:
        fields.append(("message_thread_id", str(thread_id)))
        
    for name, value in fields:
        body.extend(f"--{boundary}\r\n".encode("utf-8"))
        body.extend(f'Content-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode("utf-8"))
        
    filename = f"TimberDryPro-v{version_name}.apk"
    body.extend(f"--{boundary}\r\n".encode("utf-8"))
    body.extend(f'Content-Disposition: form-data; name="document"; filename="{filename}"\r\n'.encode("utf-8"))
    body.extend(b"Content-Type: application/vnd.android.package-archive\r\n\r\n")
    
    with open(actual_apk, "rb") as f:
        body.extend(f.read())
    body.extend(f"\r\n--{boundary}--\r\n".encode("utf-8"))

    url = f"{BASE_URL}/sendDocument"
    req = urllib.request.Request(url, data=bytes(body), headers={
        "Content-Type": f"multipart/form-data; boundary={boundary}"
    })

    try:
        print(f"Uploading APK to Telegram chat {chat_id}" + (f" (Topic: {thread_id})" if thread_id else "") + "...")
        with urllib.request.urlopen(req, timeout=180) as resp:
            res = json.loads(resp.read().decode("utf-8"))
            if res.get("ok"):
                print("✅ Release successfully posted to Telegram Topic!")
                return True
            else:
                print(f"❌ Telegram API Error: {res}")
                return False
    except urllib.error.HTTPError as e:
        print(f"❌ HTTP Error {e.code}: {e.read().decode('utf-8')}")
        return False
    except Exception as e:
        print(f"❌ Upload Error: {e}")
        return False

def main():
    parser = argparse.ArgumentParser(description="TimberDry Pro Release & Telegram Publisher")
    parser.add_argument("--notes", type=str, help="Release notes / description of changes")
    parser.add_argument("--bump", type=str, choices=["patch", "minor", "major"], default="patch", help="Version bump level")
    parser.add_argument("--chat", type=str, help="Telegram Chat ID")
    parser.add_argument("--thread", type=str, help="Telegram Topic / Thread ID")
    args = parser.parse_args()

    cfg = load_config()
    chat_id = args.chat or cfg.get("chat_id")
    thread_id = args.thread or cfg.get("thread_id")

    if args.chat or args.thread:
        save_config(chat_id, thread_id)

    notes = args.notes or "• Оновлення додатку TimberDry Pro."

    print("📌 Bumping application version...")
    version_name, build_num = bump_version(args.bump)
    print(f"New Version: v{version_name} (Build {build_num})")

    print("📝 Updating CHANGELOG.md...")
    update_changelog(version_name, notes)

    print("⚙️ Building Release APK with Flutter...")
    env = os.environ.copy()
    env["PATH"] = env.get("PATH", "") + ":/Users/astraagnon/development/flutter/bin"
    build_cmd = ["flutter", "build", "apk", "--split-per-abi"]
    res = subprocess.run(build_cmd, cwd=PROJECT_DIR, env=env)

    if res.returncode != 0:
        print("❌ Flutter APK build failed!")
        sys.exit(1)

    print("🚀 Sending Release APK & Notes to Telegram...")
    send_telegram_apk(chat_id, thread_id, version_name, build_num, notes)

if __name__ == "__main__":
    main()
