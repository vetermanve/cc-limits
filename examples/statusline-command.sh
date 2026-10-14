#!/bin/bash
# Пример статуслайна Claude Code: каталог, ветка git и лимиты через cc-limits.
#
# Положи это в ~/.claude/statusline-command.sh, сделай исполняемым и укажи
# в ~/.claude/settings.json:
#
#   "statusLine": { "type": "command", "command": "~/.claude/statusline-command.sh" }

input=$(cat)

current_dir=$(echo "$input" | jq -r '.workspace.current_dir // .cwd')
dir_name=$(basename "$current_dir")

cd "$current_dir" 2>/dev/null || exit 1

git_info=""
if git rev-parse --git-dir >/dev/null 2>&1; then
    branch=$(git branch --show-current 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
    if [ -n "$branch" ]; then
        if git diff-index --quiet HEAD -- 2>/dev/null; then
            git_info=" git:($branch)"
        else
            git_info=" git:($branch) *"
        fi
    fi
fi

# Лимиты. Читает только кэш и дёргает обновление в фоне, поэтому статуслайн
# не блокируется на сети.
limits=""
if [ -x "$HOME/.local/bin/cc-limits" ]; then
    limits=$(CC_LIMITS_FORCE_COLOR=1 "$HOME/.local/bin/cc-limits" --statusline 2>/dev/null)
    [ -n "$limits" ] && limits="  $limits"
fi

printf "> %s%s%s" "$dir_name" "$git_info" "$limits"
