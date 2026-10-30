#!/usr/bin/env python3
"""PostToolUse(Agent|Task) + SubagentStop: строка журнала токенов на каждый запуск субагента.

rule:model-routing v1, `rule:token-ledger v1`. Пишет одну JSON-строку в
`${XDG_CACHE_HOME:-$HOME/.cache}/claude-code-hooks/agent-routing/<project-sha256>/agent_tokens.jsonl` и best-effort вставляет её в таблицу
`agent_token_ledger` общей базы (миграция `scripts/sql/2026-10-17_agent_token_ledger.sql`
в ru-ubo-resolver).

Откуда данные (форма проверена по строкам схемы в бинаре Claude Code 17.10, не угадана):
- PostToolUse синхронного Agent несёт `tool_response` = {status:"completed", prompt, agentId,
  totalDurationMs, totalTokens, totalToolUseCount, usage:{input_tokens, output_tokens,
  cache_creation_input_tokens, cache_read_input_tokens}} - строка пишется сразу;
- фоновый запуск отвечает `status:"async_launched"` без usage. Тогда здесь кладётся
  отметка `${XDG_CACHE_HOME:-$HOME/.cache}/claude-code-hooks/agent-routing/<project-sha256>/pending/<agentId>.json` (тип, модель, override, начало задачи), а
  строку пишет SubagentStop, когда агент закончит: у него есть `agent_id`, `agent_type` и
  `agent_transcript_path`, по которому суммируется usage (по одному разу на message.id);
- SubagentStop без отметки - это синхронный агент, его строку уже пишет PostToolUse: пропуск,
  чтобы не посчитать дважды.

`override` - буквальный маркер `override: cost-justified` в брифе (его пропустил
agent_model_guard.py).

Отказ записи в базу - одна громкая строка в stderr; локальная строка остаётся. Хук не имеет
права уронить сессию: exit 0 всегда.

Обратный эксперимент (tests/test_agent_hooks.py::test_ledger_line_from_tool_response):
закомментировать `C.append_jsonl(...)` в `write_row()` - тест падает на "строка журнала не
дописана"; заменить `override = C.has_override(ti)` на `False` - падает
test_override_token_allows_and_marks_ledger.
"""
import hashlib
import json
import os
import pathlib
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _agent_common as C  # noqa: E402

DB_ENV = ("AGENT_LEDGER_DATABASE_URL", "DATABASE_URL")


def task_head(ti):
    text = str(ti.get("description") or ti.get("prompt") or "")
    return " ".join(text.split())[:80]  # обрезка ТОЛЬКО для журнала, ничего не решает


def repo_name(payload):
    return C.project_dir(payload).resolve().name


def usage_from_response(tr):
    u = tr.get("usage") if isinstance(tr, dict) else None
    if not isinstance(u, dict):
        return None
    inp = sum(int(u.get(k) or 0) for k in
              ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
    out = int(u.get("output_tokens") or 0)
    total = tr.get("totalTokens")
    return {"input_tokens": inp, "output_tokens": out,
            "total_tokens": int(total) if total is not None else inp + out,
            "cache_read_tokens": int(u.get("cache_read_input_tokens") or 0)}


def usage_from_transcript(path):
    """Сумма usage по транскрипту субагента: (usage, модель, начало, конец) или None."""
    try:
        lines = pathlib.Path(path).read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    per_msg, model, first, last = {}, None, None, None
    for line in lines:
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        ts = rec.get("timestamp")
        if ts:
            first = first or ts
            last = ts
        msg = rec.get("message") if isinstance(rec.get("message"), dict) else {}
        if rec.get("type") == "assistant" and isinstance(msg.get("usage"), dict):
            per_msg[msg.get("id") or len(per_msg)] = msg["usage"]  # стрим повторяет usage
            model = msg.get("model") or model
    if not per_msg:
        return None
    inp = out = cr = 0
    for u in per_msg.values():
        inp += sum(int(u.get(k) or 0) for k in
                   ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
        out += int(u.get("output_tokens") or 0)
        cr += int(u.get("cache_read_input_tokens") or 0)
    return ({"input_tokens": inp, "output_tokens": out, "total_tokens": inp + out,
             "cache_read_tokens": cr}, model, first, last)


def _iso_minus(seconds):
    import datetime
    t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=seconds or 0)
    return t.isoformat(timespec="seconds")


def row_id(session_id, agent_id, finished_at, head):
    key = f"{session_id}|{agent_id}|{finished_at}|{head}"
    return hashlib.sha256(key.encode("utf-8")).hexdigest()[:32]


def db_insert(row):
    dsn = next((os.environ[k] for k in DB_ENV if os.environ.get(k)), None)
    if not dsn:
        C.loud("agent_token_ledger: в базу не записано: нет AGENT_LEDGER_DATABASE_URL/DATABASE_URL "
               "(строка осталась в ${XDG_CACHE_HOME:-$HOME/.cache}/claude-code-hooks/agent-routing/<project-sha256>/agent_tokens.jsonl)")
        return False
    cols = ("id", "session_id", "agent_id", "started_at", "finished_at", "agent_type", "model",
            "input_tokens", "output_tokens", "total_tokens", "duration_s", "task_head", "repo",
            "override", "token_source")
    sql = (f"insert into agent_token_ledger ({', '.join(cols)}) values "
           f"({', '.join(['%s'] * len(cols))}) on conflict (id) do nothing")
    vals = [row.get(c) for c in cols]
    try:
        try:
            import psycopg
            with psycopg.connect(dsn, prepare_threshold=None, connect_timeout=4) as conn:
                conn.execute(sql, vals)
        except ImportError:
            import psycopg2
            conn = psycopg2.connect(dsn, connect_timeout=4)
            try:
                with conn, conn.cursor() as cur:
                    cur.execute(sql, vals)
            finally:
                conn.close()
        return True
    except Exception as e:
        C.loud(f"agent_token_ledger: в базу не записано: {type(e).__name__}: {str(e)[:160]} "
               f"(строка осталась в ${XDG_CACHE_HOME:-$HOME/.cache}/claude-code-hooks/agent-routing/<project-sha256>/agent_tokens.jsonl)")
        return False


def write_row(row, payload):
    C.append_jsonl(C.ledger_dir(payload) / "agent_tokens.jsonl", row)
    row["db"] = db_insert(row)


def pending_path(payload, agent_id):
    # Tool IDs are data, never filesystem paths; sessions may reuse an ID.
    key = json.dumps([payload.get("session_id"), agent_id], ensure_ascii=False)
    name = hashlib.sha256(key.encode()).hexdigest() + ".json"
    return C.ledger_dir(payload) / "pending" / name


def on_post_tool_use(payload):
    ti = payload.get("tool_input") or {}
    tr = payload.get("tool_response")
    tr = tr if isinstance(tr, dict) else {}
    model, model_source = C.effective_model(ti, payload)
    override = C.has_override(ti)
    agent_id = tr.get("agentId")
    base = {"session_id": payload.get("session_id"), "agent_id": agent_id,
            "agent_type": ti.get("subagent_type") or "general-purpose",
            "model": model, "model_source": model_source, "tier": C.tier_of(model),
            "override": override, "task_head": task_head(ti), "repo": repo_name(payload)}
    if tr.get("status") == "async_launched" and agent_id:
        base["launched_at"] = C.now_iso()
        pend = pending_path(payload, agent_id)
        pend.parent.mkdir(parents=True, exist_ok=True)
        pend.write_text(json.dumps(base, ensure_ascii=False), encoding="utf-8")
        return
    usage = usage_from_response(tr)
    finished = C.now_iso()
    dur = (tr.get("totalDurationMs") or 0) / 1000.0 if tr.get("totalDurationMs") else None
    row = dict(base, finished_at=finished, started_at=_iso_minus(dur) if dur else None,
               duration_s=dur, token_source="tool_response" if usage else "unavailable",
               **(usage or {"input_tokens": None, "output_tokens": None, "total_tokens": None}))
    if not usage:
        C.loud(f"agent_token_ledger: в ответе Agent нет usage (status={tr.get('status')}); "
               f"строка записана с пустыми токенами")
    row["id"] = row_id(row["session_id"], agent_id, finished, row["task_head"])
    write_row(row, payload)


def on_subagent_stop(payload):
    agent_id = payload.get("agent_id")
    if not agent_id:
        return
    pend = pending_path(payload, agent_id)
    if not pend.exists():
        return  # синхронный агент: строку пишет PostToolUse
    base = json.loads(pend.read_text(encoding="utf-8"))
    got = usage_from_transcript(payload.get("agent_transcript_path") or "")
    finished = C.now_iso()
    if got:
        usage, tmodel, first, last = got
        if tmodel:
            base.update(model=tmodel, model_source="transcript", tier=C.tier_of(tmodel))
        src = "transcript"
    else:
        usage, first, last = {"input_tokens": None, "output_tokens": None,
                              "total_tokens": None}, base.get("launched_at"), None
        src = "unavailable"
        C.loud("agent_token_ledger: транскрипт фонового агента не прочитан; токены пустые")
    dur = None
    try:
        import datetime
        a = datetime.datetime.fromisoformat(str(first).replace("Z", "+00:00"))
        b = datetime.datetime.fromisoformat(str(last or finished).replace("Z", "+00:00"))
        dur = round((b - a).total_seconds(), 1)
    except Exception:
        pass
    row = dict(base, finished_at=finished, started_at=first, duration_s=dur,
               token_source=src, **usage)
    row.pop("launched_at", None)
    row["id"] = row_id(row["session_id"], agent_id, finished, row["task_head"])
    write_row(row, payload)
    done = pend.parent / "done"
    done.mkdir(exist_ok=True)
    pend.rename(done / pend.name)  # отметка не удаляется, а уходит в done/


def main():
    raw = sys.stdin.read()
    payload = json.loads(raw) if raw.strip() else {}
    event = payload.get("hook_event_name")
    if event == "SubagentStop":
        on_subagent_stop(payload)
    elif payload.get("tool_name") in ("Agent", "Task"):
        on_post_tool_use(payload)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        C.loud(f"agent_token_ledger: сбой хука, строка журнала не записана: {type(e).__name__}: {e}")
    sys.exit(0)
