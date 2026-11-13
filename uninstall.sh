#!/bin/bash
# Удаление Oops:
#   curl -fsSL https://raw.githubusercontent.com/Egrom92/oops/main/uninstall.sh | bash
set -u
osascript -e 'tell application id "local.layoutconverter" to quit' >/dev/null 2>&1
pkill -x Oops 2>/dev/null; pkill -x LayoutConverter 2>/dev/null
sleep 0.5
for app in /Applications/Oops.app "$HOME/Applications/Oops.app" "/Applications/Layout Converter.app" "$HOME/Applications/Layout Converter.app"; do
    if [ -d "$app" ]; then
        open -n -W "$app" --args --unregister-login >/dev/null 2>&1   # убрать из «Объектов входа»
        rm -rf "$app" && echo "Удалено: $app"
    fi
done
KC="$HOME/Library/Keychains/layoutconverter-signing.keychain-db"
if [ -f "$KC" ]; then
    rest=$(security list-keychains -d user | tr -d '"' | grep -v "layoutconverter-signing" | xargs)
    # shellcheck disable=SC2086
    security list-keychains -d user -s $rest
    security delete-keychain "$KC" 2>/dev/null
fi
defaults delete local.layoutconverter >/dev/null 2>&1
echo "✅ Oops удалён. Разрешение можно убрать в Системных настройках → Универсальный доступ."
