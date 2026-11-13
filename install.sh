#!/bin/bash
# Установка или обновление Oops одной командой:
#   curl -fsSL https://raw.githubusercontent.com/Egrom92/oops/main/install.sh | bash
# или из скачанной папки:  ./install.sh
set -euo pipefail

REPO="Egrom92/oops"
say() { printf '\n\033[1m▶︎ %s\033[0m\n' "$*"; }
die() { printf '\n❌ %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "Oops работает только на macOS."
ver=$(sw_vers -productVersion)
[ "${ver%%.*}" -ge 13 ] || die "Нужна macOS 13 Ventura или новее (у вас $ver)."

if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swift >/dev/null 2>&1; then
    say "Нужны бесплатные инструменты разработчика Apple (Command Line Tools)"
    echo "Сейчас откроется окно установки: нажмите «Установить», дождитесь окончания"
    echo "(5–15 минут) и запустите эту же команду ещё раз."
    xcode-select --install 2>/dev/null || true
    exit 1
fi

# --- исходники: из этой папки или свежие с GitHub ---
self="${BASH_SOURCE[0]:-}"
if [ -n "$self" ] && [ -f "$(dirname "$self")/Package.swift" ] && [ -d "$(dirname "$self")/Sources/Oops" ]; then
    SRC="$(cd "$(dirname "$self")" && pwd)"
else
    say "Скачиваю Oops с GitHub"
    TMP=$(mktemp -d "${TMPDIR:-/tmp}/oops.XXXXXX")
    trap 'rm -rf "$TMP"' EXIT
    curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$TMP" \
        || die "Не удалось скачать https://github.com/$REPO. Проверьте интернет."
    SRC="$TMP/oops-main"
fi
cd "$SRC"

say "Собираю (первый раз 1–2 минуты)"
LOG="${TMPDIR:-/tmp}/oops-build.log"
if ! ./scripts/build.sh >"$LOG" 2>&1; then
    tail -30 "$LOG" >&2
    die "Сборка не удалась. Полный журнал: $LOG"
fi

# --- старая версия на Hammerspoon: выключить, чтобы Ctrl+Option не срабатывал дважды ---
HS="$HOME/.hammerspoon"
if [ -f "$HS/init.lua" ] && grep -q 'require("layout_converter")\|Конвертер раскладки (замена Punto Switcher)' "$HS/init.lua"; then
    if grep -q 'Конвертер раскладки (замена Punto Switcher)' "$HS/init.lua"; then
        mv "$HS/init.lua" "$HS/init.lua.bak"   # это был только конвертер
    else
        grep -v 'require("layout_converter")' "$HS/init.lua" > "$HS/init.lua.tmp" && mv "$HS/init.lua.tmp" "$HS/init.lua"
    fi
    rm -f "$HS/layout_converter.lua"
    if pgrep -xq Hammerspoon; then
        osascript -e 'tell application "Hammerspoon" to quit' >/dev/null 2>&1 || true
        [ -s "$HS/init.lua" ] && { sleep 1; open -a Hammerspoon; }
    fi
    say "Конвертер в Hammerspoon выключен (копия: $HS/init.lua.bak, если был только он). Hammerspoon больше не нужен."
fi

# --- установка ---
DEST=/Applications
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
say "Ставлю в $DEST/Oops.app"
osascript -e 'tell application id "local.layoutconverter" to quit' >/dev/null 2>&1 || true
pkill -x Oops 2>/dev/null || true
# Под старым именем (Layout Converter): убрать из «Объектов входа» и удалить; новое имя включит автозапуск заново.
for old in "/Applications/Layout Converter.app" "$HOME/Applications/Layout Converter.app"; do
    if [ -d "$old" ]; then
        pkill -x LayoutConverter 2>/dev/null || true
        open -n -W "$old" --args --unregister-login >/dev/null 2>&1 || true
        rm -rf "$old"
        defaults delete local.layoutconverter loginItemConfigured >/dev/null 2>&1 || true
    fi
done
sleep 0.5
rm -rf "$DEST/Oops.app"
ditto "build/Oops.app" "$DEST/Oops.app"
open "$DEST/Oops.app"

cat <<'DONE'

✅ Готово: значок клавиатуры в строке меню.

Один раз выдайте доступ (macOS сама предложит):
  Системные настройки → Конфиденциальность и безопасность → Универсальный доступ → Oops.

Как пользоваться: напечатали не в той раскладке («ghbdtn») — нажмите и отпустите Ctrl+Option.
Есть выделение — меняется оно, нет — последнее слово. Раскладка переключится сама.
Работает с любыми включёнными раскладками: английской, русской, эстонской, латышской, финской и другими.
Обновить — запустить эту же команду ещё раз.
DONE
