"""Общая часть трёх хуков маршрутизации моделей (rule:model-routing v1).

Не хук. Здесь только то, что нужно всем трём одинаково: где лежит журнал, какую модель
объявляет определение агента, к какому уровню цены относится идентификатор модели.

Все строковые операции здесь - над ТИПИЗИРОВАННЫМИ значениями: идентификатор модели,
имя типа агента, путь, ключ frontmatter, буквальный маркер протокола. Свободный текст
человека здесь не судится (core.md, правило 4).
"""
import datetime
import json
import os
import pathlib
import sys

# Дешёвые уровни: на них модель класса opus и выше хук ОТКЛОНЯЕТ (решение владельца
# 2026-10-17: "по шагам мое решение - жестко хук может ОТКАЗЫВАТЬ").
CHEAP_TYPES = ("mechanic", "scout", "researcher")

# Буквальный маркер явного исключения. Протокольный токен, а не смысл текста.
OVERRIDE_TOKEN = "override: cost-justified"

# Уровни цены по семейству в идентификаторе модели. Порядок - от дорогого к дешёвому:
# идентификатор относится к первому совпавшему семейству.
TIERS = (("fable", "fable"), ("opus", "opus"), ("sonnet", "sonnet"), ("haiku", "haiku"))
EXPENSIVE_TIERS = ("opus", "fable")


def project_dir(payload=None):
    env = os.environ.get("CLAUDE_PROJECT_DIR")
    if env:
        return pathlib.Path(env)
    if payload and payload.get("cwd"):
        return pathlib.Path(payload["cwd"])
    return pathlib.Path(".")


def ledger_dir(payload=None):
    """`.claude/ledger/` is local state. sync.sh distributes the hooks but not
    .gitignore, so the directory ignores itself: a `*` .gitignore is dropped on
    first use. Without it every synced repository would show the journal as
    untracked and the Stop hook would nag about files no commit should hold."""
    d = project_dir(payload) / ".claude" / "ledger"
    try:
        d.mkdir(parents=True, exist_ok=True)
        gi = d / ".gitignore"
        if not gi.exists():
            gi.write_text("*\n", encoding="utf-8")
    except OSError:
        pass
    return d


def tier_of(model):
    """haiku / sonnet / opus / fable по идентификатору; None - модель не названа."""
    if not model:
        return None
    m = str(model).lower()
    for needle, tier in TIERS:
        if needle in m:
            return tier
    return "other"


def definition_model(agent_type, payload=None):
    """Значение `model:` из frontmatter `.claude/agents/<type>.md`; None - нет файла или ключа."""
    if not agent_type:
        return None
    p = project_dir(payload) / ".claude" / "agents" / f"{agent_type}.md"
    try:
        text = p.read_text(encoding="utf-8")
    except OSError:
        return None
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None
    for line in lines[1:]:
        if line.strip() == "---":
            break
        key, sep, value = line.partition(":")
        if sep and key.strip() == "model":
            return value.strip() or None
    return None


def effective_model(tool_input, payload=None):
    """(модель, откуда): явный аргумент вызова главнее определения агента."""
    explicit = (tool_input or {}).get("model")
    if explicit:
        return str(explicit), "explicit"
    d = definition_model((tool_input or {}).get("subagent_type"), payload)
    if d and d != "inherit":
        return d, "definition"
    return None, ("inherit" if d == "inherit" else "no_definition")


def has_override(tool_input):
    return OVERRIDE_TOKEN in str((tool_input or {}).get("prompt") or "")


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def append_jsonl(path, row):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def loud(msg):
    """Одна громкая строка в stderr (core.md, правило 5)."""
    try:
        sys.stderr.write(msg.rstrip("\n") + "\n")
    except Exception:
        pass
