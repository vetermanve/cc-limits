"""Модульные проверки аккаунтов: слаги, файлы, токены, резервы, переключение."""
import importlib.util, json, os, pathlib, shutil, sys, tempfile

root = pathlib.Path(tempfile.mkdtemp(prefix="cc-unit-"))
os.environ["CLAUDE_CONFIG_DIR"] = str(root)
os.environ.pop("CLAUDE_CODE_OAUTH_TOKEN", None)
os.environ.pop("CC_LIMITS_RESERVE_5H", None)

cfg = {"reserve": {"seven_day": 10},
       "accounts": [
           {"name": "личный", "source": "token", "token": "tok-личный"},
           {"name": "флот", "source": "token", "token": "tok-флот",
            "reserve": {"five_hour": 40}},
       ]}
(root / "cc-limits.json").write_text(json.dumps(cfg, ensure_ascii=False))

from importlib.machinery import SourceFileLoader
HERE = pathlib.Path(__file__).resolve().parent
loader = SourceFileLoader("cclimits", str(HERE.parent / "cc-limits"))
spec = importlib.util.spec_from_loader("cclimits", loader)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

ok = []
def check(name, cond, extra=""):
    ok.append(cond)
    print(("OK  " if cond else "ПАДЕНИЕ ") + name + (f"  {extra}" if extra else ""))

# слаги
check("слаг из кириллицы", m.slugify("Личный Аккаунт") == "личный-аккаунт",
      m.slugify("Личный Аккаунт"))
check("слаг из пустого имени", m.slugify("///") == "acc", m.slugify("///"))

accs = m.accounts()
lich, fleet = accs
check("аккаунты прочитаны", [a.name for a in accs] == ["личный", "флот"])

# файлы у аккаунтов разные и не совпадают с дефолтными
check("кэш per-account", lich.cache_file != fleet.cache_file != m.CACHE_FILE,
      lich.cache_file.name + " / " + fleet.cache_file.name)
check("история per-account", lich.history_file.name == "cc-limits-history-личный.jsonl",
      lich.history_file.name)
check("throttle per-account", fleet.throttle_file.name == "cc-limits-throttle-флот",
      fleet.throttle_file.name)

# токены источников
check("токен из спеки", fleet.access_token() == "tok-флот")
creds = json.dumps({"claudeAiOauth": {"accessToken": "A", "expiresAt": 123}})
check("JSON-сессия разбирается",
      m.Account("x", {"source": "token", "token": creds}).token()["expiresAt"] == 123)
check("голый токен без срока",
      m.Account("y", {"source": "token", "token": "sk-raw"}).token()["expiresAt"] is None)

# запись кэша, истории и throttle идёт в файлы активного аккаунта
m.use_account(fleet)
m.save_cache({"five_hour": {"utilization": 7, "resets_at": None}})
m.append_history({"five_hour": {"utilization": 7, "resets_at": None},
                  "seven_day": {"utilization": 1, "resets_at": None}})
m.write_throttle(0.0, 3)
check("кэш записан в файл флота", fleet.cache_file.exists() and not lich.cache_file.exists())
check("история записана в файл флота",
      fleet.history_file.exists() and not lich.history_file.exists())
check("throttle записан в файл флота", m.read_throttle()["strikes"] == 3)
m.use_account(lich)
check("у личного throttle свой", m.read_throttle()["strikes"] == 0)
check("у личного истории нет", m.load_history() == [])

# резерв: общий из конфига + переопределение аккаунта, пересчёт при переключении
check("резерв личного", m.reserves() == {"five_hour": 0.0, "seven_day": 10.0},
      str(m.reserves()))
m.use_account(fleet)
check("резерв флота", m.reserves() == {"five_hour": 40.0, "seven_day": 10.0},
      str(m.reserves()))

# аккаунт окна: своя переменная окружения важнее родительских процессов
os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = "tok-флот"
acc, note = m.session_account()
check("окно опознано по своей переменной", acc is fleet and note == "", note)
os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = "tok-чужой"
acc, note = m.session_account()
check("чужой токен -> предупреждение", acc is None and "не описан" in note, note)
os.environ.pop("CLAUDE_CODE_OAUTH_TOKEN")

# окно без токена в окружении - это сессия из Keychain, и подписаться должен
# аккаунт с источником keychain/credentials/auto
saved_token, saved_accs = m.session_token, m._ACCOUNTS
m.session_token = lambda: ""
kc = m.Account("локальный", {"source": "keychain"})
m._ACCOUNTS = [m.Account("флот", {"source": "token", "token": "tok-флот"}), kc]
acc, note = m.session_account()
check("окно без токена -> keychain-аккаунт", acc is kc and note == "",
      f"{acc.name if acc else None} / {note}")
m._ACCOUNTS = saved_accs
acc, note = m.session_account()
check("нет keychain-аккаунта -> предупреждение",
      acc is None and "Keychain" in note, note)
m.session_token = saved_token

# приговор по scope: читается только для своего отпечатка и живёт у аккаунта
m.use_account(fleet)
m.write_scope_verdict(m.fingerprint("tok-флот"), False)
check("приговор по scope записан у аккаунта", fleet.scope_file.exists(),
      fleet.scope_file.name)
check("приговор читается по своему отпечатку",
      m.read_scope_verdict().get("profile") is False, str(m.read_scope_verdict()))
m.use_account(lich)
check("у другого аккаунта приговора нет", m.read_scope_verdict() == {},
      str(m.read_scope_verdict()))
m.use_account(fleet)
m.write_scope_verdict("другой-отпечаток", False)
check("чужой отпечаток приговор не отдаёт",
      m.profile_scope_known_missing.__name__ == "profile_scope_known_missing"
      and m.read_scope_verdict().get("fp") == "другой-отпечаток",
      str(m.read_scope_verdict()))

# два окна на разных токенах не вытесняют друг друга из карты отпечатков
m.write_window_map(m.fingerprint("tok-личный"), "личный")
m.write_window_map(m.fingerprint("tok-флот"), "флот")
check("карта отпечатков держит оба окна",
      m.window_map_lookup(m.fingerprint("tok-личный")) == "личный"
      and m.window_map_lookup(m.fingerprint("tok-флот")) == "флот",
      str(m.read_window_map()))

# statusline-подпись при одном аккаунте по умолчанию пустая (ничего не ищем)
m._ACCOUNTS = [m.Account(None, {"source": "auto"}, default=True)]
m.use_account(m._ACCOUNTS[0])
label, note = m.use_window_account()
check("дефолтный аккаунт без подписи", label == "" and note == "", label)

shutil.rmtree(root, ignore_errors=True)
print()
print("итог: %d из %d" % (sum(ok), len(ok)))
sys.exit(0 if all(ok) else 1)
