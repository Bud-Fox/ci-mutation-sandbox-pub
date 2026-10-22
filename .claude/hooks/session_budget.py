#!/usr/bin/env python3
"""SessionStart: одна строка расхода токенов субагентов за сутки (rule:token-ledger v2).

Строка: "токены сегодня: X (haiku a / sonnet b / opus c); жёсткий лимит только DaData",
за ней в скобках число запусков и источник числа.

Плана токенов НЕТ (решение владельца 2026-10-17: "По плану токенов не надо строить.
Жёсткий лимит только dadata + здравый смысл = приоритет на целевых покупателях, обьектах и
продавцах"). Журнал - учёт для недельного ROI по уровням, а не квота, поэтому хук ничего не
читает про план и ни с чем число не сравнивает. Прежние `plan.json` / `daily_tokens` (v1)
сняты целиком.

Источник числа: сначала таблица `agent_token_ledger` (если задан AGENT_LEDGER_DATABASE_URL
или DATABASE_URL; одно SELECT, connect_timeout 4 с), иначе локальный
`.claude/ledger/agent_tokens.jsonl` за текущие UTC-сутки. Отказ базы - одна громкая строка
в stderr и откат на локальный журнал с пометкой источника. Это поведение разрешено
именованным исключением в AGENT-CONTRACT.md (решение владельца 2026-10-17), и только этому
хуку и agent_token_ledger.py.

Хук не имеет права уронить сессию: exit 0 всегда.

Обратные эксперименты (tests/test_agent_hooks.py::test_session_budget_*, выполнены 17.10):
- убрать фильтр по дате в `local_totals()` - падает test_session_budget_sums_today_by_tier
  на сумме 101 099 вместо 1 100;
- убрать "; жёсткий лимит только DaData" из `line()` - падает
  test_session_budget_names_dadata_and_no_plan;
- убрать `C.loud(...)` в ветке отказа `db_totals()` - падает
  test_session_budget_db_failure_is_loud_and_falls_back.
"""
import datetime
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _agent_common as C  # noqa: E402

DB_ENV = ("AGENT_LEDGER_DATABASE_URL", "DATABASE_URL")


def today_utc():
    return datetime.datetime.now(datetime.timezone.utc).date().isoformat()


def local_totals(payload):
    path = C.ledger_dir(payload) / "agent_tokens.jsonl"
    day = today_utc()
    total, by_tier, n = 0, {}, 0
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return 0, {}, 0
    for line in lines:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if not str(row.get("finished_at") or "").startswith(day):
            continue
        tok = row.get("total_tokens")
        if tok is None:
            continue
        tier = row.get("tier") or C.tier_of(row.get("model")) or "unknown"
        by_tier[tier] = by_tier.get(tier, 0) + int(tok)
        total += int(tok)
        n += 1
    return total, by_tier, n


def db_totals():
    dsn = next((os.environ[k] for k in DB_ENV if os.environ.get(k)), None)
    if not dsn:
        return None
    sql = ("select model, coalesce(sum(total_tokens),0), count(*) from agent_token_ledger "
           "where finished_at >= date_trunc('day', now() at time zone 'utc') at time zone 'utc' "
           "group by model")
    try:
        try:
            import psycopg
            with psycopg.connect(dsn, prepare_threshold=None, connect_timeout=4) as conn:
                rows = conn.execute(sql).fetchall()
        except ImportError:
            import psycopg2
            conn = psycopg2.connect(dsn, connect_timeout=4)
            try:
                with conn.cursor() as cur:
                    cur.execute(sql)
                    rows = cur.fetchall()
            finally:
                conn.close()
    except Exception as e:
        C.loud(f"session_budget: база не ответила ({type(e).__name__}); число - из локального журнала")
        return None
    total, by_tier, n = 0, {}, 0
    for model, tok, cnt in rows:
        tier = C.tier_of(model) or "unknown"
        by_tier[tier] = by_tier.get(tier, 0) + int(tok)
        total += int(tok)
        n += int(cnt)
    return total, by_tier, n


def fmt(n):
    return f"{n:,}".replace(",", " ")


def line(payload):
    got = db_totals()
    source = "база agent_token_ledger"
    if got is None:
        got = local_totals(payload)
        source = "локальный журнал этого клона"
    total, by_tier, n = got
    tiers = ["haiku", "sonnet", "opus"] + sorted(t for t in by_tier if t not in ("haiku", "sonnet", "opus"))
    split = " / ".join(f"{t} {fmt(by_tier.get(t, 0))}" for t in tiers)
    return (f"токены сегодня: {fmt(total)} ({split}); жёсткий лимит только DaData "
            f"(запусков {n}; источник - {source}; сутки UTC)")


def main():
    raw = sys.stdin.read()
    payload = json.loads(raw) if raw.strip() else {}
    text = line(payload)
    sys.stdout.write(json.dumps({"systemMessage": text,
                                 "hookSpecificOutput": {"hookEventName": "SessionStart",
                                                        "additionalContext": text}},
                                ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        C.loud(f"session_budget: сбой хука, строка бюджета не напечатана: {type(e).__name__}: {e}")
    sys.exit(0)
