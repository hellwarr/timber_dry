#!/usr/bin/env bash
# ==============================================================================
#  🪵 TimberDry Pro — 1-Click ESP32 Firmware Flasher
# ==============================================================================
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CLI="/Users/astraagnon/homebrew/bin/arduino-cli"

echo "======================================================="
echo "🪵  TimberDry Pro — Завантажувач прошивки ESP32 (v1.7.0)"
echo "======================================================="

PORT=$(ls /dev/cu.usbserial-* /dev/cu.SLAB_USBtoUART* /dev/cu.wchusbserial* 2>/dev/null | head -n 1 || true)

if [ -z "$PORT" ]; then
    echo "❌ Помилка: ESP32 не знайдено! Перевірте підключення кабелю USB."
    echo "Натисніть будь-яку клавішу для виходу..."
    read -n 1
    exit 1
fi

echo "🔌 Знайдено порт: $PORT"
echo "⚙️  Компіляція..."
"$CLI" compile --fqbn esp32:esp32:esp32:PartitionScheme=huge_app "$DIR"

echo "🚀 Запис прошивки у пам'ять ESP32..."
"$CLI" upload -p "$PORT" --fqbn esp32:esp32:esp32:PartitionScheme=huge_app,UploadSpeed=115200 "$DIR"

echo ""
echo "======================================================="
echo "✅ ПРОШИВКУ УСПІШНО ЗАВАНТАЖЕНО У ВАШУ ПЛАТУ ESP32!"
echo "======================================================="
echo "Натисніть будь-яку клавішу для закриття вікна..."
read -n 1
