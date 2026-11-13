#!/bin/bash
# Установка конвертера раскладки:
#   curl -fsSL https://raw.githubusercontent.com/Egrom92/layout-converter/main/install.sh | bash
# или из скачанной папки:  ./install.sh
set -euo pipefail

REPO="Egrom92/layout-converter"
HS_DIR="$HOME/.hammerspoon"
MODULE="$HS_DIR/layout_converter.lua"
INIT="$HS_DIR/init.lua"
say() { printf '\n\033[1m▶︎ %s\033[0m\n' "$*"; }
die() { printf '\n❌ %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "Конвертер работает только на macOS."

# --- 1. Hammerspoon ------------------------------------------------------------
if [ ! -d /Applications/Hammerspoon.app ] && [ ! -d "$HOME/Applications/Hammerspoon.app" ]; then
    if command -v brew >/dev/null 2>&1; then
        say "Ставлю Hammerspoon (через Homebrew)"
        brew install --cask hammerspoon
    else
        die "Нужен Hammerspoon: скачайте его с https://www.hammerspoon.org, перенесите в «Программы» и запустите эту команду ещё раз."
    fi
fi

# --- 2. Скрипт ------------------------------------------------------------------
mkdir -p "$HS_DIR"
self="${BASH_SOURCE[0]:-}"
if [ -n "$self" ] && [ -f "$(dirname "$self")/layout_converter.lua" ]; then
    cp "$(dirname "$self")/layout_converter.lua" "$MODULE"
else
    curl -fsSL "https://raw.githubusercontent.com/$REPO/main/layout_converter.lua" -o "$MODULE" \
        || die "Не удалось скачать layout_converter.lua. Проверьте интернет."
fi
say "Скрипт: $MODULE"

# --- 3. Подключить в init.lua, не затирая ваши настройки -------------------------
LINE='require("layout_converter")   -- конвертер раскладки: Ctrl+Option'
if [ ! -f "$INIT" ]; then
    printf '%s\n' "$LINE" > "$INIT"
elif grep -q 'require("layout_converter")' "$INIT"; then
    : # уже подключён
elif grep -q 'Конвертер раскладки (замена Punto Switcher)' "$INIT"; then
    # старая версия, вставленная целиком в init.lua: заменяем, копию оставляем рядом
    cp "$INIT" "$INIT.bak"
    printf '%s\n' "$LINE" > "$INIT"
    say "Старая копия конвертера в init.lua заменена подключением; прежний файл: $INIT.bak"
else
    printf '\n%s\n' "$LINE" >> "$INIT"
fi

# --- 4. Перезапустить Hammerspoon с новым конфигом -------------------------------
if [ -z "${LAYOUT_CONVERTER_NO_LAUNCH:-}" ]; then
    if pgrep -xq Hammerspoon; then
        osascript -e 'tell application "Hammerspoon" to quit' >/dev/null 2>&1 || true
        sleep 1
    fi
    open -a Hammerspoon
fi

cat <<'DONE'

✅ Готово. Вверху экрана мелькнёт «Конвертер раскладки: Ctrl+Option».

Один раз выдайте Hammerspoon доступ:
  Системные настройки → Конфиденциальность и безопасность → Универсальный доступ → Hammerspoon.

Как пользоваться: напечатали не в той раскладке («ghbdtn») — нажмите и отпустите Ctrl+Option.
Есть выделение — меняется оно, нет — последнее слово перед курсором. Раскладка переключится сама.
DONE
