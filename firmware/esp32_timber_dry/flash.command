#!/bin/bash

# ==============================================================================
#  🪵 TimberDry Pro — 1-CLICK ESP32 COMPILE & FLASH SCRIPT
# ==============================================================================

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

clear
echo -e "${CYAN}======================================================================${NC}"
echo -e "${BOLD}${YELLOW}   🪵 TimberDry Pro — АВТОПРОШИВКА КОНТРОЛЕРА СУШАРКИ (ESP32)${NC}"
echo -e "${CYAN}======================================================================${NC}"
echo ""

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI="/Users/astraagnon/homebrew/bin/arduino-cli"
BOARD_FQBN="esp32:esp32:esp32:PartitionScheme=huge_app"

# 1. Пошук підключеної плати ESP32
echo -e "${CYAN}▶ Пошук підключеної плати ESP32 через USB...${NC}"
PORT=$($CLI board list | grep -E "usbserial|SLAB|wchusb|CP210|ch34" | awk '{print $1}' | head -n 1)

if [[ -z "$PORT" ]]; then
    PORT=$(ls /dev/cu.usbserial* /dev/cu.SLAB_USBtoUART* /dev/cu.wchusbserial* 2>/dev/null | head -n 1)
fi

if [[ -z "$PORT" ]]; then
    echo -e "${RED}❌ Плату ESP32 не знайдено!${NC}"
    echo -e "${YELLOW}👉 Підключіть ESP32 через USB-кабель до Mac і запустіть цей файл знову.${NC}"
    echo ""
    echo -e "${CYAN}Список виявлених портів:${NC}"
    $CLI board list
    echo ""
    echo "Натисніть Enter для виходу..."
    read -r
    exit 1
fi

echo -e "${GREEN}✔ Знайдено ESP32 на порту: ${BOLD}$PORT${NC}"
echo ""

# 2. Компіляція
echo -e "${CYAN}▶ Компіляція скетчу з підтримкою Bluetooth (BLE) та Wi-Fi...${NC}"
$CLI compile --fqbn "$BOARD_FQBN" "$PROJECT_DIR"

if [[ $? -ne 0 ]]; then
    echo -e "${RED}❌ Помилка компіляції!${NC}"
    read -r
    exit 1
fi
echo -e "${GREEN}✔ Компіляція успішна!${NC}"
echo ""

# 3. Прошивка
echo -e "${CYAN}▶ Завантаження прошивки в ESP32 ($PORT)...${NC}"
echo -e "${YELLOW}(Якщо завантаження не стартує — затисніть кнопку BOOT на ESP32 на 2 секунди)${NC}"
echo ""

$CLI upload -p "$PORT" --fqbn "$BOARD_FQBN" "$PROJECT_DIR"

if [[ $? -eq 0 ]]; then
    echo ""
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "${BOLD}${GREEN}  🎉 ДАТЧИК СУШАРКИ УСПІШНО ПРОШИТО!${NC}"
    echo -e "${GREEN}======================================================================${NC}"
    echo ""
    echo -e "📱 Тепер ви можете відкрити додаток TimberDry Pro на телефоні"
    echo -e "   та налаштувати Wi-Fi через Bluetooth за PIN-кодом ${BOLD}196711${NC}."
    echo ""
    echo -e -n "${BOLD}Бажаєте відкрити Монітор Порту (Serial Monitor) для перегляду логів? (Y/n):${NC} "
    read -r MONITOR
    MONITOR=${MONITOR:-Y}
    if [[ "$MONITOR" == "y" || "$MONITOR" == "Y" ]]; then
        echo -e "${CYAN}▶ Запуск Serial Monitor (115200 бод). Для виходу натисніть Ctrl+C...${NC}"
        echo ""
        $CLI monitor -p "$PORT" -c baudrate=115200
    fi
else
    echo -e "${RED}❌ Помилка під час завантаження прошивки.${NC}"
fi

echo ""
echo "Натисніть Enter для завершення..."
read -r
