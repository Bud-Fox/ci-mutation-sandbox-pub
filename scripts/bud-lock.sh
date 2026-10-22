#!/usr/bin/env bash
#
# Per-clone lease: $(git rev-parse --git-path BUD-LOCK). THE ONE FILE that
# says who owns this clone.
#
# WHY THIS EXISTS
# ---------------
# 2026-10-19 (au-bot session 20260919 note, state.db): sibling sessions ran
# `pull --rebase`, `merge origin` and `reset --hard` in a clone they did not
# create and did not hold, under the working feet of the session that did.
# 2026-10-20: outcrop PR #426 was watched simultaneously by two duty subagents
# sharing one clone. Both are the same defect with two symptoms: nothing in
# the tree said whose clone this was.
# 2026-10-21 rewrite: the first version parsed the lease with sed (owners
# containing `,` `"` `}` were read wrong), treated an unparseable lease as
# free (a truncated lock silently unlocked the clone), read-then-wrote the
# file without a mutex (two acquirers could both see "free"), and took over
# a fresh foreign lease whenever the holder pid looked dead - pid recycling
# made that a silent steal. All four are fixed below.
#
# THE LEASE
# ---------
# One JSON file inside the git directory - never staged, never pushed, and
# located via `git rev-parse --git-path BUD-LOCK` so a linked worktree locks
# its own gitdir (.git/worktrees/<name>/BUD-LOCK), not the main .git:
#
#   BUD-LOCK   {"owner":"<user>@<host>:<session-pid>","ts":1699999999,"ttl":3600}
#
#   owner  who holds the clone. BUD_LOCK_OWNER overrides the default - a
#          harness running parallel sessions in one clone gives each session
#          a distinct owner string. Any bytes are legal: the file is written
#          and read by python3's json, never by shell string surgery.
#   ts     unix seconds of the last acquire/refresh.
#   ttl    seconds after ts the lease is stale. Exactly: the lease is stale
#          when now >= ts + ttl. Default 3600; BUD_LOCK_TTL must be a
#          positive integer - anything else is a usage error, never a silent
#          default.
#
# THE RULES THAT ARE NOT NEGOTIABLE
# ---------------------------------
#   A held lease is refused BY NAME - the holder's owner string and the time
#   left are printed, never a bare nonzero, never a silent wait.
#   The ONLY clock that frees a foreign lease is the ttl: a lease past
#   ts + ttl is taken over OUT LOUD (the takeover names the previous owner
#   and the age). A holder pid that looks dead is NOT grounds for takeover -
#   pids recycle, "kill -0 says no" is not proof of death - so a fresh
#   foreign lease is refused even if its pid is not running.
#   A lease that fails strict schema validation (exactly owner:str nonempty,
#   ts:int >= 0, ttl:int > 0 - no extra keys, no string numbers) makes the
#   script FAIL CLOSED: no acquire, no check pass, no release without
#   --force. A lock nobody can read must lock, not unlock.
#   Modification (acquire/release) is serialized across processes by a
#   mkdir guard next to the lock - mkdir is atomic and exclusive on every
#   filesystem we run on - so two concurrent acquirers cannot both see
#   "free". Readers never see a half-written file: writes go through a
#   temp file + rename.
#
# USAGE
# -----
#   scripts/bud-lock.sh acquire            take or refresh the lease (the gate
#                                          calls this as its first stage)
#   scripts/bud-lock.sh check              refuse (rc 1) if a foreign live
#                                          session holds the clone; write nothing
#   scripts/bud-lock.sh release [--force]  drop own/stale lease; a foreign live
#                                          lease is refused without --force;
#                                          --force drops any lease, loudly
#   scripts/bud-lock.sh status             print the parsed lease, rc 0 always
#
# Exit codes: 0 free/mine/stale as requested; 1 a foreign live lease (or a
# corrupt lease - fail closed) blocks the command; 2 usage/environment error.
set -uo pipefail

die2() { echo "bud-lock: $*" >&2; exit 2; }

# --- ttl: positive integer, fail closed on garbage ---------------------------
TTL="${BUD_LOCK_TTL:-3600}"
case "$TTL" in
  ''|*[!0-9]*) die2 "BUD_LOCK_TTL must be a positive integer (seconds), got: '$TTL'" ;;
esac
[ "$TTL" -gt 0 ] || die2 "BUD_LOCK_TTL must be > 0, got: '$TTL'"

# --- lock path: --git-path so linked worktrees lock their own gitdir ---------
GIT_PATH_LOCK="$(git rev-parse --git-path BUD-LOCK 2>/dev/null)" \
  || die2 "not a git repository (git rev-parse --git-path BUD-LOCK failed)"
case "$GIT_PATH_LOCK" in
  /*) LOCK="$GIT_PATH_LOCK" ;;
  *)  LOCK="$(pwd)/$GIT_PATH_LOCK" ;;
esac
GUARD="${LOCK}.guard"

now() { date +%s; }
this_host() { hostname -s 2>/dev/null || hostname; }

# --- owner identity -----------------------------------------------------------
# BUD_LOCK_OWNER wins wholesale. The default must answer "which session is
# this?" with a value stable across short-lived processes. $$ changes every
# invocation; a common daemon ancestor would collapse independent agents.
# Direct siblings can use PPID, but nested tools must export BUD_LOCK_OWNER.
# Direct invocations share their parent, not a common daemon ancestor.
# Export BUD_LOCK_OWNER for a real agent session across nested hooks/processes.
OWNER="${BUD_LOCK_OWNER:-${HERMES_SESSION_ID:-$(id -un 2>/dev/null || echo unknown)@$(this_host):$PPID}}"
case "$OWNER" in
  *$'\x1f'*) die2 "BUD_LOCK_OWNER must not contain the reserved field separator" ;;
esac

# --- the lease as a foreign lease refusal block, on stderr where hooks show it
refuse() {  # refuse <owner> <age> <ttl> <wanted>
  cat >&2 <<EOF
BUD-LOCK: this clone is leased to a live session - not touching it
  holder : $1
  held   : $2 s ago (ttl $3 s, $(( $3 - $2 )) s left)
  lease  : $LOCK
Refused for: $4
Wait for the lease to expire or be released, work in your own clone, or -
only if you are the holder's session - run: scripts/bud-lock.sh release
EOF
}

refuse_corrupt() {  # the lock nobody can read must lock, not unlock
  cat >&2 <<EOF
BUD-LOCK: lease file $LOCK is corrupt (fails strict schema
  {\"owner\": nonempty str, \"ts\": int >= 0, \"ttl\": int > 0} - exactly these keys)
Refused for: $1 - failing closed rather than guessing free.
Inspect the file, or drop it explicitly: scripts/bud-lock.sh release --force
EOF
}

# --- json in/out via python3: real parsing, real escaping, no sed -----------
command -v python3 >/dev/null 2>&1 \
  || die2 "python3 is required to read/write $LOCK safely (no sed parsing)"

# read_lease: sets STATE (FREE | CORRUPT | OK) and on OK sets O T L.
# Fields are separated by \x1f; owners containing \x1f would degrade the
# split - the writer below accepts any bytes, this reader draws the line
# there and no real owner string contains it.
read_lease() {
  O=""; T=""; L=""
  STATE="$(python3 - "$LOCK" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
except FileNotFoundError:
    print("FREE"); raise SystemExit(0)
except Exception:
    print("CORRUPT"); raise SystemExit(0)
ok = (isinstance(d, dict) and set(d) == {"owner", "ts", "ttl"}
      and isinstance(d["owner"], str) and d["owner"] != "" and "\x1f" not in d["owner"]
      and isinstance(d["ts"], int) and not isinstance(d["ts"], bool) and d["ts"] >= 0
      and isinstance(d["ttl"], int) and not isinstance(d["ttl"], bool) and d["ttl"] > 0)
if not ok:
    print("CORRUPT"); raise SystemExit(0)
print("OK\x1f%s\x1f%d\x1f%d" % (d["owner"], d["ts"], d["ttl"]))
PY
)" || die2 "python3 failed while reading $LOCK"
  case "$STATE" in
    OK$'\x1f'*)
      local rest="${STATE#OK$'\x1f'}"          # "owner<0x1f>ts<0x1f>ttl"
      O="${rest%%$'\x1f'*}"
      rest="${rest#*$'\x1f'}"
      T="${rest%%$'\x1f'*}"
      L="${rest#*$'\x1f'}"
      STATE="OK"
      ;;
  esac
}

# write_lease: json.dump escapes the owner whatever it contains; temp + rename
# means a concurrent reader never sees a half-written file.
write_lease() {
  python3 - "$LOCK" "$OWNER" "$TTL" <<'PY' || { echo "bud-lock: cannot write $LOCK" >&2; exit 2; }
import json, os, sys, time
path, owner, ttl = sys.argv[1], sys.argv[2], int(sys.argv[3])
tmp = "%s.tmp.%d" % (path, os.getpid())
with open(tmp, "w", encoding="utf-8") as f:
    json.dump({"owner": owner, "ts": int(time.time()), "ttl": ttl}, f)
    f.write("\n")
os.replace(tmp, path)
PY
}

# --- cross-process mutex: mkdir is atomic and exclusive everywhere ----------
GUARD_HELD=0
guard_take() {
  local waited=0
  until mkdir "$GUARD" 2>/dev/null; do
    waited=$((waited + 1))
    if [ "$waited" -ge 100 ]; then
      echo "BUD-LOCK: guard busy: $GUARD; inspect holder before explicit recovery; refusing automatic deletion" >&2
      return 1
    fi
    sleep 0.1
  done
  GUARD_HELD=1
}
guard_drop() { [ "$GUARD_HELD" = 1 ] && rmdir "$GUARD" 2>/dev/null; }
trap guard_drop EXIT

# classify the loaded lease. Sets WHY, returns:
#   0 free or mine (refresh)   1 foreign and live
#   2 stale (now >= ts + ttl)  4 corrupt - caller must fail closed
classify() {
  case "$STATE" in
    FREE)    WHY="free (no lease at $LOCK)"; return 0 ;;
    CORRUPT) WHY="corrupt lease at $LOCK"; return 4 ;;
  esac
  if [ "$O" = "$OWNER" ]; then WHY="mine ($O) - refreshing"; return 0; fi
  local age=$(( $(now) - T ))
  # exact expiry: stale the moment now >= ts + ttl
  if [ "$age" -ge "$L" ]; then
    WHY="stale: held ${age}s by $O, ttl ${L}s"
    return 2
  fi
  # NOTE: no pid-liveness test here on purpose. A dead-looking pid is not
  # proof the session is gone (pids recycle); the ttl is the only takeover
  # clock. Fresh foreign lease => refused, pid or no pid.
  WHY="held ${age}s by $O (ttl ${L}s, $(( L - age ))s left)"
  return 1
}

cmd="${1:-}"
case "$cmd" in
  acquire)
    guard_take || { echo "bud-lock: another process holds $GUARD for too long" >&2; exit 2; }
    read_lease
    classify; rc=$?
    case $rc in
      0) write_lease
         echo "BUD-LOCK: lease acquired by $OWNER (ttl ${TTL}s${O:+; previous: $WHY})"
         ;;
      2) echo "BUD-LOCK: STALE LEASE TAKEN OVER (not silent) - $WHY"
         write_lease
         ;;
      1) refuse "$O" "$(( $(now) - T ))" "$L" "acquire"
         exit 1
         ;;
      4) refuse_corrupt "acquire"
         exit 1
         ;;
    esac
    ;;
  check)  # read-only: the rename in write_lease makes reads safe without the guard
    read_lease
    classify; rc=$?
    case $rc in
      0) [ -n "$O" ] && echo "BUD-LOCK: $WHY"; exit 0 ;;
      2) echo "BUD-LOCK: STALE LEASE - $WHY (take it over with: scripts/bud-lock.sh acquire)"; exit 0 ;;
      1) refuse "$O" "$(( $(now) - T ))" "$L" "check"; exit 1 ;;
      4) refuse_corrupt "check"; exit 1 ;;
    esac
    ;;
  release)
    if [ "${2:-}" = "--force" ]; then
      guard_take || { echo "bud-lock: another process holds $GUARD for too long" >&2; exit 2; }
      read_lease
      case "$STATE" in
        OK) echo "BUD-LOCK: --force release of $O's lease by $OWNER" ;;
        *)  echo "BUD-LOCK: --force release of unreadable lease at $LOCK by $OWNER" ;;
      esac
      rm -f "$LOCK" || die2 "cannot remove $LOCK"
      exit 0
    fi
    [ -z "${2:-}" ] || die2 "usage: bud-lock.sh release [--force]"
    guard_take || { echo "bud-lock: another process holds $GUARD for too long" >&2; exit 2; }
    read_lease
    classify; rc=$?
    case $rc in
      0) if [ "$STATE" = "OK" ]; then
           rm -f "$LOCK" || die2 "cannot remove $LOCK"
           echo "BUD-LOCK: released ($WHY)"
         fi
         exit 0 ;;
      2) rm -f "$LOCK" || die2 "cannot remove $LOCK"
         echo "BUD-LOCK: released stale foreign lease - $WHY"
         exit 0 ;;
      1) refuse "$O" "$(( $(now) - T ))" "$L" "release without --force"; exit 1 ;;
      4) refuse_corrupt "release without --force"; exit 1 ;;
    esac
    ;;
  status)
    read_lease
    case "$STATE" in
      FREE)    echo "BUD-LOCK: no lease ($LOCK)" ;;
      CORRUPT) echo "BUD-LOCK: CORRUPT lease ($LOCK) - fails strict schema; release --force to drop it" ;;
      OK)      echo "BUD-LOCK: owner=$O ts=$T ttl=$L age=$(( $(now) - T ))s file=$LOCK" ;;
    esac
    exit 0
    ;;
  *)
    echo "usage: bud-lock.sh {acquire|check|release [--force]|status}" >&2
    echo "  env: BUD_LOCK_OWNER=<session id>  BUD_LOCK_TTL=<positive integer seconds>" >&2
    exit 2
    ;;
esac
