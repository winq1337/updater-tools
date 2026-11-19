#!/usr/bin/env bash
# Quick one-line installer for updater-tools
set -e

REPO_URL="https://raw.githubusercontent.com/winq1337/updater-tools/main/updater-tools.sh"
TARGET_DIR="/usr/local/bin"
BIN_NAME="updater-tools"

if [ "$EUID" -ne 0 ]; then
  echo "[-] Ошибка: Запустите установщик с правами root: sudo bash -c \"\$(curl -fsSL ...)\""
  exit 1
fi

echo "[*] Загрузка Updater Tools..."
curl -4 -fsSL "$REPO_URL" -o "${TARGET_DIR}/${BIN_NAME}"
chmod +x "${TARGET_DIR}/${BIN_NAME}"

echo "[✓] Успешно установлено в ${TARGET_DIR}/${BIN_NAME}"
echo "    Теперь вы можете запускать утилиту командой:"
echo "    sudo ${BIN_NAME}"
