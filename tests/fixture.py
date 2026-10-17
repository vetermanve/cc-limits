"""Готовит изолированный CLAUDE_CONFIG_DIR с кэшем и историей под аккаунты."""
import json, os, sys, time, datetime, pathlib

root = pathlib.Path(sys.argv[1])
slugs = sys.argv[2:]          # "" -> дефолтные имена файлов
cache = root / "cache"
cache.mkdir(parents=True, exist_ok=True)

def usage(h5, d7):
    now = time.time()
    r5 = datetime.datetime.fromtimestamp(now + 2 * 3600, datetime.timezone.utc)
    r7 = datetime.datetime.fromtimestamp(now + 4 * 86400, datetime.timezone.utc)
    return {
        "five_hour": {"utilization": h5, "resets_at": r5.isoformat()},
        "seven_day": {"utilization": d7, "resets_at": r7.isoformat()},
        "limits": [], "seven_day_breakdown": {"rows": []},
        "extra_usage": {"is_enabled": False},
    }

for i, slug in enumerate(slugs):
    h5, d7 = 40 + i * 20, 10 + i * 5
    data = usage(h5, d7)
    cfile = cache / (f"cc-limits-cache-{slug}.json" if slug else "cc-limits-cache.json")
    hfile = cache / (f"cc-limits-history-{slug}.jsonl" if slug else "cc-limits-history.jsonl")
    cfile.write_text(json.dumps(data))
    # два замера с разбросом 40 минут, чтобы считалась скорость расхода 5ч
    now = time.time()
    r5 = datetime.datetime.fromisoformat(data["five_hour"]["resets_at"]).timestamp()
    r7 = datetime.datetime.fromisoformat(data["seven_day"]["resets_at"]).timestamp()
    rows = [
        {"t": now - 2400, "h5": h5 - 6, "d7": d7 - 1, "h5_reset": r5, "d7_reset": r7},
        {"t": now - 60, "h5": h5, "d7": d7, "h5_reset": r5, "d7_reset": r7},
    ]
    hfile.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
print("фикстура готова:", root)
