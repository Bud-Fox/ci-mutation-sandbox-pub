#!/usr/bin/env python3
"""PreToolUse(Agent|Task): дорогая модель на дешёвом уровне ОТКЛОНЯЕТСЯ (rule:model-routing v1).

Решение владельца 2026-10-17, его словами: "по шагам мое решение - жестко хук может
ОТКАЗЫВАТЬ". Это заменило первоначальный мягкий режим (только предупреждение) того же дня.

Что делает:
- `subagent_type` из {mechanic, scout, researcher} и модель класса opus или выше (явный
  аргумент `model` либо `model:` в определении агента) -> permissionDecision "deny" с одной
  строкой причины;
- то же, но в тексте брифа есть буквальный маркер `override: cost-justified` -> запуск
  пропускается, решение пишется в журнал (`override=true`), а строку журнала токенов
  `agent_token_ledger.py` пометит тем же признаком;
- модель не названа ни в вызове, ни в определении (наследуется модель сессии) -> запуск
  пропускается с предупреждением в контекст: цену хук не знает, поэтому не отклоняет;
- implementer-hard / architect / reviewer и любые другие типы -> без вывода.

Каждое решение, кроме молчаливого пропуска дешёвой модели, - строка в
`.claude/ledger/agent_guard.jsonl` (вход, ветвление, итог - core.md, правило 1).

Хук не имеет права уронить сессию: любой сбой - одна строка в stderr и exit 0 (пропуск).

Обратный эксперимент (tests/test_agent_hooks.py::test_opus_on_mechanic_denied_without_override):
заменить в `decide()` условие `tier in EXPENSIVE_TIERS` на `False` - тест падает на
"ожидался deny"; убрать проверку `has_override` - падает
test_override_token_allows_and_marks_ledger на "ожидался пропуск".
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _agent_common as C  # noqa: E402


def decide(payload):
    """(решение, причина, запись_журнала) или None - молчаливый пропуск."""
    ti = payload.get("tool_input") or {}
    agent_type = ti.get("subagent_type") or ""
    if agent_type not in C.CHEAP_TYPES:
        return None
    model, source = C.effective_model(ti, payload)
    tier = C.tier_of(model)
    row = {
        "ts": C.now_iso(), "event": "guard", "session_id": payload.get("session_id"),
        "agent_type": agent_type, "model": model, "model_source": source, "tier": tier,
        "override": False,
    }
    if tier in C.EXPENSIVE_TIERS:
        if C.has_override(ti):
            row.update(decision="allow_override", override=True)
            ctx = (f"model-routing: {agent_type} на {model} пропущен по маркеру "
                   f"'{C.OVERRIDE_TOKEN}'; строка журнала токенов получит override=true.")
            return "allow", ctx, row
        row.update(decision="deny")
        reason = (f"model-routing v1: {agent_type} - дешёвый уровень, модель {model} "
                  f"({source}) класса {tier} отклонена; уберите model (определение задаёт "
                  f"дешёвую), выберите другой тип агента или добавьте в бриф "
                  f"'{C.OVERRIDE_TOKEN}' с одной строкой обоснования.")
        return "deny", reason, row
    if tier is None:
        row.update(decision="allow_unknown_model")
        ctx = (f"model-routing: у {agent_type} модель не названа ни в вызове, ни в "
               f"определении ({source}) - наследуется модель сессии, цена неизвестна. "
               f"Передайте model явно.")
        return "allow", ctx, row
    return None


def main():
    raw = sys.stdin.read()
    payload = json.loads(raw) if raw.strip() else {}
    verdict = decide(payload)
    if verdict is None:
        return
    decision, text, row = verdict
    try:
        C.append_jsonl(C.ledger_dir(payload) / "agent_guard.jsonl", row)
    except Exception as e:  # журнал не должен менять решение
        C.loud(f"agent_model_guard: журнал решений не записан: {type(e).__name__}: {e}")
    if decision == "deny":
        out = {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                      "permissionDecision": "deny",
                                      "permissionDecisionReason": text}}
    else:
        out = {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                      "additionalContext": text}}
    sys.stdout.write(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        C.loud(f"agent_model_guard: сбой хука, запуск пропущен без проверки: {type(e).__name__}: {e}")
    sys.exit(0)
