#!/bin/bash
# Прогон проверок cc-limits: модульные (tests/accounts.py) и через CLI.
# Сеть не нужна: кэш и история подкладываются фикстурой, TTL не истёк.
# Аккаунт окна в тестах задаётся через CLAUDE_CODE_OAUTH_TOKEN, чтобы
# результат не зависел от того, под каким токеном запущен сам прогон.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CC="$HERE/../cc-limits"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cc-limits-tests.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

check() {
    # check <имя> <ожидаемый код> <подстрока|-> <команда...>
    local name="$1" want_rc="$2" want="$3"; shift 3
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    local bad=""
    [ "$rc" = "$want_rc" ] || bad="код $rc, ждали $want_rc"
    if [ "$want" != "-" ] && ! printf '%s' "$out" | grep -qF -- "$want"; then
        # имя переменной в фигурных скобках: иначе в не-UTF-8 локали bash
        # приклеивает к нему байты кавычки-ёлочки и падает на unbound variable
        bad="${bad:+$bad; }нет подстроки «${want}»"
    fi
    if [ -z "$bad" ]; then
        pass=$((pass + 1))
        printf 'OK   %s\n' "$name"
    else
        fail=$((fail + 1))
        printf 'ПАДЕНИЕ %s: %s\n' "$name" "$bad"
        printf '%s\n' "$out" | sed 's/^/        /' | head -5
    fi
}

# --- модульные проверки
if python3 "$HERE/accounts.py" >"$TMP/unit.log" 2>&1; then
    pass=$((pass + 1)); printf 'OK   модульные проверки аккаунтов\n'
else
    fail=$((fail + 1)); printf 'ПАДЕНИЕ модульные проверки аккаунтов\n'
    sed 's/^/        /' "$TMP/unit.log"
fi

# --- конфига нет: вывод как был, без подписей аккаунта
legacy="$TMP/legacy"
python3 "$HERE/fixture.py" "$legacy" "" >/dev/null
check "без конфига: есть окна" 0 "5ч" \
    env CLAUDE_CONFIG_DIR="$legacy" CLAUDE_CODE_OAUTH_TOKEN= python3 "$CC"
out="$(CLAUDE_CONFIG_DIR="$legacy" python3 "$CC" --statusline 2>&1)"
if printf '%s' "$out" | grep -q "аккаунт"; then
    fail=$((fail + 1)); printf 'ПАДЕНИЕ без конфига: в статуслайне появилась подпись аккаунта\n'
else
    pass=$((pass + 1)); printf 'OK   без конфига: статуслайн без подписи аккаунта\n'
fi
[ -f "$legacy/cache/cc-limits-cache.json" ] \
    && { pass=$((pass + 1)); printf 'OK   без конфига: прежнее имя файла кэша\n'; } \
    || { fail=$((fail + 1)); printf 'ПАДЕНИЕ без конфига: имя файла кэша изменилось\n'; }

# --- два аккаунта
multi="$TMP/multi"
python3 "$HERE/fixture.py" "$multi" "личный" "флот" >/dev/null
cat > "$multi/cc-limits.json" <<'JSON'
{"accounts": [
  {"name": "личный", "source": "token", "token": "tok-личный"},
  {"name": "флот", "source": "token", "token": "tok-флот",
   "reserve": {"five_hour": 50}}
]}
JSON
check "два аккаунта: оба блока" 0 "флот" \
    env CLAUDE_CONFIG_DIR="$multi" CLAUDE_CODE_OAUTH_TOKEN=tok-флот python3 "$CC"
check "два аккаунта: окно помечено" 0 "(это окно)" \
    env CLAUDE_CONFIG_DIR="$multi" CLAUDE_CODE_OAUTH_TOKEN=tok-флот python3 "$CC"
check "резерв аккаунта применён" 0 "резерв 50%" \
    env CLAUDE_CONFIG_DIR="$multi" CLAUDE_CODE_OAUTH_TOKEN=tok-флот python3 "$CC"
check "статуслайн: имя аккаунта в конце" 0 "| флот" \
    env CLAUDE_CONFIG_DIR="$multi" CLAUDE_CODE_OAUTH_TOKEN=tok-флот python3 "$CC" --statusline
check "статуслайн: другое окно - другой аккаунт" 0 "| личный" \
    env CLAUDE_CONFIG_DIR="$multi" CLAUDE_CODE_OAUTH_TOKEN=tok-личный python3 "$CC" --statusline
check "незнакомый токен окна: предупреждение" 0 "аккаунт ?" \
    env CLAUDE_CONFIG_DIR="$multi" CLAUDE_CODE_OAUTH_TOKEN=tok-чужой python3 "$CC" --statusline
check "--accounts помечает окно" 0 "это окно" \
    env CLAUDE_CONFIG_DIR="$multi" CLAUDE_CODE_OAUTH_TOKEN=tok-флот python3 "$CC" --accounts
check "--account выбирает один" 0 "личный" \
    env CLAUDE_CONFIG_DIR="$multi" CLAUDE_CODE_OAUTH_TOKEN=tok-флот python3 "$CC" --account личный
check "--account с чужим именем" 1 "не описан" \
    env CLAUDE_CONFIG_DIR="$multi" python3 "$CC" --account нетакого
check "--account без значения" 1 "без имени аккаунта" \
    env CLAUDE_CONFIG_DIR="$multi" python3 "$CC" --account

# --- json: одна форма на аккаунт окна, карта на --all
out="$(CLAUDE_CONFIG_DIR="$multi" CLAUDE_CODE_OAUTH_TOKEN=tok-флот python3 "$CC" --json --cache 2>&1)"
printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert "five_hour" in d, "нет five_hour"
assert d["five_hour"]["utilization"] == 60, d["five_hour"]
' && { pass=$((pass + 1)); printf 'OK   --json: аккаунт окна, форма прежняя\n'; } \
  || { fail=$((fail + 1)); printf 'ПАДЕНИЕ --json: не тот аккаунт или форма\n'; }

out="$(CLAUDE_CONFIG_DIR="$multi" python3 "$CC" --json --all --cache 2>&1)"
printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert set(d) == {"личный", "флот"}, set(d)
' && { pass=$((pass + 1)); printf 'OK   --json --all: карта по аккаунтам\n'; } \
  || { fail=$((fail + 1)); printf 'ПАДЕНИЕ --json --all: не карта по аккаунтам\n'; }

# --- наследование файлов безымянного аккаунта при появлении accounts
heir="$TMP/heir"
python3 "$HERE/fixture.py" "$heir" "" >/dev/null
cat > "$heir/cc-limits.json" <<'JSON'
{"accounts": [
  {"name": "личный", "source": "keychain"},
  {"name": "флот", "source": "token", "token": "tok-флот"}
]}
JSON
check "наследник видит прежние замеры" 0 "хватит до сброса" \
    env CLAUDE_CONFIG_DIR="$heir" CLAUDE_CODE_OAUTH_TOKEN= python3 "$CC" --account личный
if [ -f "$heir/cache/cc-limits-cache-личный.json" ] && [ -f "$heir/cache/cc-limits-history-личный.jsonl" ]; then
    pass=$((pass + 1)); printf 'OK   кэш и история скопированы наследнику\n'
else
    fail=$((fail + 1)); printf 'ПАДЕНИЕ файлы наследнику не скопированы\n'
fi
if [ -f "$heir/cache/cc-limits-cache.json" ]; then
    pass=$((pass + 1)); printf 'OK   прежние файлы на месте (откат конфига возможен)\n'
else
    fail=$((fail + 1)); printf 'ПАДЕНИЕ прежние файлы пропали\n'
fi
if [ -f "$heir/cache/cc-limits-cache-флот.json" ]; then
    fail=$((fail + 1)); printf 'ПАДЕНИЕ история досталась не тому аккаунту\n'
else
    pass=$((pass + 1)); printf 'OK   второму аккаунту чужие замеры не достались\n'
fi

# --- аккаунт без данных: индикатор не должен просто исчезать
empty="$TMP/empty"; mkdir -p "$empty"
cat > "$empty/cc-limits.json" <<'JSON'
{"accounts": [{"name": "пустой", "source": "token", "token": "tok-пустой"}]}
JSON
check "аккаунт без кэша: говорит, что данных нет" 0 "пустой: нет данных" \
    env CLAUDE_CONFIG_DIR="$empty" CLAUDE_CODE_OAUTH_TOKEN=tok-пустой \
    python3 "$CC" --statusline
# пауза после 429: статуслайн пишет, когда будет повтор, и не плодит процессы
mkdir -p "$empty/cache"
python3 -c "
import json, time, sys
json.dump({'until': time.time() + 600, 'strikes': 3},
          open(sys.argv[1], 'w'))
" "$empty/cache/cc-limits-throttle-пустой"
check "пауза после 429 видна в статуслайне" 0 "повтор через" \
    env CLAUDE_CONFIG_DIR="$empty" CLAUDE_CODE_OAUTH_TOKEN=tok-пустой \
    python3 "$CC" --statusline
nocfg="$TMP/nocfg"; mkdir -p "$nocfg"
out="$(CLAUDE_CONFIG_DIR="$nocfg" CLAUDE_CODE_OAUTH_TOKEN= python3 "$CC" --statusline 2>/dev/null)"
if [ -z "$out" ]; then
    pass=$((pass + 1)); printf 'OK   без конфига и без кэша статуслайн молчит\n'
else
    fail=$((fail + 1)); printf 'ПАДЕНИЕ без конфига статуслайн напечатал: %s\n' "$out"
fi

# --- токен без scope user:profile: причина вместо обещания повтора
noscope="$TMP/noscope"; mkdir -p "$noscope/cache"
cat > "$noscope/cc-limits.json" <<'JSON'
{"accounts": [{"name": "безскоупа", "source": "token", "token": "tok-без"}]}
JSON
python3 -c "
import json, time, sys
json.dump({'fp': sys.argv[2], 'profile': False, 't': time.time()},
          open(sys.argv[1], 'w'))
" "$noscope/cache/cc-limits-scope-безскоупа.json" \
  "$(python3 -c "import hashlib;print(hashlib.sha256('tok-без'.encode()).hexdigest()[:16])")"
# throttle намеренно не кладём: приговор по scope должен работать сам,
# без паузы, и без запроса к серверу (токен заведомо битый - живой запрос
# дал бы другую ошибку)
check "одноразовый вывод: лимиты недоступны, запроса нет" 1 "определение лимитов невозможно" \
    env CLAUDE_CONFIG_DIR="$noscope" CLAUDE_CODE_OAUTH_TOKEN=tok-без \
    python3 "$CC" --account безскоупа --force
# даже если от прежних 429 осталась пауза, причина должна быть про scope
python3 -c "
import json, time, sys
json.dump({'until': time.time() + 21600, 'strikes': 4}, open(sys.argv[1], 'w'))
" "$noscope/cache/cc-limits-throttle-безскоупа"
check "пауза не подменяет причину" 1 "определение лимитов невозможно" \
    env CLAUDE_CONFIG_DIR="$noscope" CLAUDE_CODE_OAUTH_TOKEN=tok-без \
    python3 "$CC" --account безскоупа
if [ -s "$noscope/cache/cc-limits-throttle-безскоупа" ] && grep -q '"until": 0' "$noscope/cache/cc-limits-throttle-безскоупа"; then
    pass=$((pass + 1)); printf 'OK   мёртвая пауза снята\n'
else
    fail=$((fail + 1)); printf 'ПАДЕНИЕ пауза осталась: %s\n' "$(cat "$noscope/cache/cc-limits-throttle-безскоупа")"
fi
check "статуслайн называет причину: нет scope" 0 "безскоупа: токен без scope, лимиты недоступны" \
    env CLAUDE_CONFIG_DIR="$noscope" CLAUDE_CODE_OAUTH_TOKEN=tok-без \
    python3 "$CC" --statusline
out="$(CLAUDE_CONFIG_DIR="$noscope" CLAUDE_CODE_OAUTH_TOKEN=tok-без python3 "$CC" --statusline 2>&1)"
if printf '%s' "$out" | grep -q "повтор через"; then
    fail=$((fail + 1)); printf 'ПАДЕНИЕ при отсутствии scope всё ещё обещает повтор\n'
else
    pass=$((pass + 1)); printf 'OK   при отсутствии scope повтор не обещается\n'
fi

# --- дорогой источник токена не должен опрашиваться на каждый ход
cmdacc="$TMP/cmdacc"
python3 "$HERE/fixture.py" "$cmdacc" "личный" "секретница" >/dev/null
cat > "$cmdacc/cc-limits.json" <<JSON
{"accounts": [
  {"name": "личный", "source": "token", "token": "tok-личный"},
  {"name": "секретница", "source": "command",
   "command": "echo вызов >> $cmdacc/calls.log; printf tok-секрет"}
]}
JSON
for _ in 1 2 3; do
    CLAUDE_CONFIG_DIR="$cmdacc" CLAUDE_CODE_OAUTH_TOKEN=tok-секрет \
        python3 "$CC" --statusline >/dev/null 2>&1
done
calls="$(wc -l < "$cmdacc/calls.log" | tr -d ' ')"
if [ "$calls" = "1" ]; then
    pass=$((pass + 1)); printf 'OK   source=command опрошен один раз на три вызова\n'
else
    fail=$((fail + 1)); printf 'ПАДЕНИЕ source=command опрошен %s раз вместо 1\n' "$calls"
fi
check "запомненный отпечаток: аккаунт тот же" 0 "| секретница" \
    env CLAUDE_CONFIG_DIR="$cmdacc" CLAUDE_CODE_OAUTH_TOKEN=tok-секрет \
    python3 "$CC" --statusline
if [ -f "$cmdacc/cache/cc-limits-window.json" ]; then
    pass=$((pass + 1)); printf 'OK   отпечаток токена окна закэширован\n'
else
    fail=$((fail + 1)); printf 'ПАДЕНИЕ файла с отпечатком токена окна нет\n'
fi
if grep -q "tok-" "$cmdacc/cache/cc-limits-window.json" 2>/dev/null; then
    fail=$((fail + 1)); printf 'ПАДЕНИЕ в кэш попал сам токен, а не отпечаток\n'
else
    pass=$((pass + 1)); printf 'OK   в кэше только отпечаток, токена нет\n'
fi
# смена токена окна должна переопределить запомненный аккаунт
check "другой токен окна - другой аккаунт" 0 "| личный" \
    env CLAUDE_CONFIG_DIR="$cmdacc" CLAUDE_CODE_OAUTH_TOKEN=tok-личный \
    python3 "$CC" --statusline

# --- битые конфиги: падаем сразу, в статуслайне без трейсбека
bad="$TMP/bad"; mkdir -p "$bad"
try_bad() {
    printf '%s' "$2" > "$bad/cc-limits.json"
    check "битый конфиг: $1" 1 "$3" env CLAUDE_CONFIG_DIR="$bad" python3 "$CC"
}
try_bad "accounts не список" '{"accounts": {}}' "непустым списком"
try_bad "без name" '{"accounts": [{"source": "keychain"}]}' "без name"
try_bad "дубль имени" '{"accounts": [{"name":"a","source":"env"},{"name":"a","source":"env"}]}' "описан дважды"
try_bad "совпадающие слаги" '{"accounts": [{"name":"Флот","source":"env"},{"name":"флот","source":"env"}]}' "одинаковые имена файлов"
try_bad "неизвестный source" '{"accounts": [{"name":"a","source":"vault"}]}' "ожидал один из"
try_bad "резерв вне диапазона" '{"accounts": [{"name":"a","source":"env","reserve":{"five_hour":150}}]}' "вне диапазона"
try_bad "резерв не того окна" '{"accounts": [{"name":"a","source":"env","reserve":{"ten_min":5}}]}' "нет такого окна"
try_bad "битый JSON" '{"accounts": [' "не разобрал"
printf '%s' '{"accounts": []}' > "$bad/cc-limits.json"
check "битый конфиг в статуслайне" 1 "битый конфиг" \
    env CLAUDE_CONFIG_DIR="$bad" python3 "$CC" --statusline

# --- недоступный источник токена: ошибка в блоке аккаунта, а не трейсбек
nosrc="$TMP/nosrc"; mkdir -p "$nosrc"
printf '%s' '{"accounts": [{"name":"f","source":"file"}]}' > "$nosrc/cc-limits.json"
check "source=file без path" 1 "source=file без path" \
    env CLAUDE_CONFIG_DIR="$nosrc" python3 "$CC"

printf '\nитог: %d прошло, %d упало\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
