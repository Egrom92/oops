#!/bin/bash
# Удаление конвертера раскладки (Hammerspoon остаётся):
#   curl -fsSL https://raw.githubusercontent.com/Egrom92/layout-converter/main/uninstall.sh | bash
set -u
HS_DIR="$HOME/.hammerspoon"
rm -f "$HS_DIR/layout_converter.lua"
if [ -f "$HS_DIR/init.lua" ]; then
    grep -v 'require("layout_converter")' "$HS_DIR/init.lua" > "$HS_DIR/init.lua.tmp" && mv "$HS_DIR/init.lua.tmp" "$HS_DIR/init.lua"
fi
if [ -z "${LAYOUT_CONVERTER_NO_LAUNCH:-}" ] && pgrep -xq Hammerspoon; then
    osascript -e 'tell application "Hammerspoon" to quit' >/dev/null 2>&1
    sleep 1
    open -a Hammerspoon
fi
echo "✅ Конвертер раскладки удалён. Hammerspoon можно удалить из «Программ», если он больше не нужен."
