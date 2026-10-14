#!/bin/sh
# Устанавливает cc-limits в ~/.local/bin и печатает сниппет для статуслайна.
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)/cc-limits"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
DEST="$BIN_DIR/cc-limits"

if [ ! -f "$SRC" ]; then
    echo "не нашёл $SRC" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "нужен python3 в PATH" >&2
    exit 1
fi

mkdir -p "$BIN_DIR"
install -m 755 "$SRC" "$DEST"
echo "установлен: $DEST"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "внимание: $BIN_DIR не в PATH, добавь его в профиль оболочки" ;;
esac

echo
echo "проверка:"
if "$DEST" >/dev/null 2>&1; then
    "$DEST"
else
    "$DEST" || true
    echo
    echo "если токен не найден - залогинься в Claude Code через /login"
fi

cat <<'SNIPPET'

Чтобы индикатор был в статуслайне Claude Code, добавь в
~/.claude/statusline-command.sh:

    limits=""
    if [ -x "$HOME/.local/bin/cc-limits" ]; then
        limits=$(CC_LIMITS_FORCE_COLOR=1 "$HOME/.local/bin/cc-limits" --statusline 2>/dev/null)
        [ -n "$limits" ] && limits="  $limits"
    fi

    printf "%s%s" "$your_existing_prompt" "$limits"

Готовый пример целиком - examples/statusline-command.sh
SNIPPET
