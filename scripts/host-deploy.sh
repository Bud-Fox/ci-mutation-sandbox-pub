#!/usr/bin/env bash
#
# Deploy a REQUESTED COMMIT on the host, or refuse and say why.
#
# WHAT THIS REPLACES
# ------------------
# The live /opt/dnb-mcp/scripts/deploy.sh did:
#
#   git fetch origin main && git reset --hard origin/main
#   ...
#   curl -s .../health | grep -q "healthy" && echo "SUCCESS" || echo "WARNING"
#
# Both lines are the same defect in different clothes: the script cannot tell
# you what it deployed, and it cannot fail. The `sha` the deploy request
# carried was discarded and whatever origin/main pointed at that instant was
# shipped instead - two merges a minute apart deployed the identical tip and
# both reported success. Then `A && B || C` returned rc=0 when the health check
# failed (proven on that host: it printed WARNING and exited 0), so an
# unhealthy deploy answered the webhook with HTTP 200 and CI went green.
#
# So this script is built around two assertions that can actually fail:
#   - after checkout, HEAD must equal the requested SHA          (exit 12)
#   - after `up`, the service must be healthy AND report that SHA (14 / 15)
#
# ONE CODE PATH
# -------------
# There is no "SHA mode" and "branch mode". With no --sha, origin/$REF is
# resolved to a SHA once and the identical path runs. A branch deploy is
# merely how the SHA got chosen. Two paths means one of them is the one nobody
# exercised, and it is always the one that runs during an incident.
#
# EXIT CODES - the caller maps these onto HTTP. The table is the contract.
#
#   exit | meaning                                  | intended HTTP
#   -----|------------------------------------------|--------------
#     0  | deployed and healthy at the requested SHA | 200
#    10  | bad usage / config                        | 400
#    11  | requested SHA not fetchable               | 404
#    12  | tree assertion failed                     | 409
#    13  | docker teardown/build failed              | 409
#    14  | deployed, health assert failed            | 422
#    15  | deployed, healthy, wrong SHA              | 422
#
# A FAILED HEALTH ASSERT MUST NOT BE 5xx. This is the load-bearing property of
# the table. The caller retries 5xx with backoff; a health assert that failed
# is not a transient fault, so retrying it means running a full
# `compose up --build` three more times against a host that is already
# unhealthy. 422 says "I did the work, the result is wrong, a human decides".
# rc=1 from this script means an unhandled fault inside the script itself and
# is deliberately outside the 10-15 contract.
#
# OUTPUT DISCIPLINE
# All human-readable logging and every subprocess's chatter go to stderr.
# stdout carries exactly one line, and only on success:
#
#   DEPLOYED_SHA=<40-hex>
#
# so the webhook can read it back and record what actually shipped rather than
# what it hoped shipped.
#
# USAGE
#   host-deploy.sh [--sha <sha>] [--ref <ref>] [--dry-run]
#
# CONFIG - optional .deploy.conf at the repo root, sourced if present, the same
# precedent as .preflight.conf: the one place a repository states something
# only it can know, never a reason to edit this shared file.
#
#   DEPLOY_HEALTH_URL       internal health URL; absent -> assert skipped, loudly
#   DEPLOY_FALLBACK_REF     default: main
#   DEPLOY_META_FILE        default: .env
#   DEPLOY_HEALTH_TIMEOUT   default: 120 (seconds)
#
# HOOKS - run if present and executable, with DEPLOY_SHA exported:
#   scripts/deploy-pre.sh   before the containers are touched
#   scripts/deploy-post.sh  after the health assert has passed
#
set -Eeuo pipefail

TMPS=()
cleanup() { local t; for t in "${TMPS[@]:-}"; do if [ -n "$t" ]; then rm -f "$t"; fi; done; }
trap cleanup EXIT
# An unhandled failure is a bug in this file, not one of the seven documented
# outcomes, so it exits 1 and names the line and the command rather than
# borrowing a code the caller would translate into a confident HTTP answer.
trap 'printf "host-deploy: unhandled failure at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2; exit 1' ERR

if [ -t 2 ]; then B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; N=$'\033[0m'
else B=""; R=""; G=""; Y=""; N=""; fi

say()  { printf '\n%s== %s%s\n' "$B" "$1" "$N" >&2; }
ok()   { printf '  %sok%s   %s\n'   "$G" "$N" "$1" >&2; }
warn() { printf '  %sWARN%s %s\n'   "$Y" "$N" "$1" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
# die <exit-code> <message...> - every refusal in this file goes through here,
# so the code and the reason are emitted together and never drift apart.
die()  { local c="$1"; shift; printf '  %sFAIL%s %s\n  %shost-deploy: exit %s%s\n' \
           "$R" "$N" "$*" "$R" "$c" "$N" >&2; exit "$c"; }

usage() {
  sed -n '/^# USAGE/,/^set -Eeuo/p' "$0" | sed -e 's/^# \{0,1\}//' -e '/^set -Eeuo/d' >&2
}

# ------------------------------------------------------------------ args --
REQ_SHA=""
REQ_REF=""
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sha)     [ $# -ge 2 ] || die 10 "--sha needs a value"; REQ_SHA="$2"; shift 2 ;;
    --ref)     [ $# -ge 2 ] || die 10 "--ref needs a value"; REQ_REF="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         usage; die 10 "unknown argument: $1" ;;
  esac
done

# A webhook payload commonly carries both a branch and the head SHA of the
# merge that fired it. That is not a usage error: the SHA is the precise
# request and wins, the ref is only how a SHA would have been chosen without
# one. Saying so out loud beats silently ignoring half the request.
if [ -n "$REQ_SHA" ] && [ -n "$REQ_REF" ]; then
  warn "both --sha and --ref given; --sha wins, --ref $REQ_REF is informational"
fi
if [ -n "$REQ_SHA" ] && ! printf '%s' "$REQ_SHA" | grep -qE '^[0-9a-fA-F]{7,40}$'; then
  die 10 "--sha must be 7-40 hex characters, got: $REQ_SHA"
fi

# ------------------------------------------------------------- context --
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] || die 10 "not inside a git work tree: $PWD"
cd "$ROOT" || die 10 "cannot cd to repo root $ROOT"

if [ -f "$ROOT/.deploy.conf" ]; then
  set -a; . "$ROOT/.deploy.conf"; set +a
  ok ".deploy.conf sourced"
fi

DEPLOY_HEALTH_URL="${DEPLOY_HEALTH_URL:-}"
DEPLOY_FALLBACK_REF="${DEPLOY_FALLBACK_REF:-main}"
DEPLOY_META_FILE="${DEPLOY_META_FILE:-.env}"
DEPLOY_HEALTH_TIMEOUT="${DEPLOY_HEALTH_TIMEOUT:-120}"
if [ -n "$REQ_REF" ]; then DEPLOY_FALLBACK_REF="$REQ_REF"; fi

printf '%s' "$DEPLOY_HEALTH_TIMEOUT" | grep -qE '^[0-9]+$' \
  || die 10 "DEPLOY_HEALTH_TIMEOUT must be a whole number of seconds, got: $DEPLOY_HEALTH_TIMEOUT"

git remote get-url origin >/dev/null 2>&1 \
  || die 10 "no 'origin' remote in $ROOT - nothing to deploy from"

if [ "$DRY_RUN" -eq 1 ]; then say "host-deploy (dry run)"; else say "host-deploy"; fi
ok "repo $ROOT"

# --------------------------------------------- 1. refspec, additive only --
# 11 of 32 repositories on this host carry a narrow remote.origin.fetch, and 4
# of those have no origin/main at all - a deploy from main there fails for a
# structural reason that used to surface as a confusing `reset --hard` error.
#
# ADDITIVE, NEVER --replace-all. A repo may carry a second refspec on purpose
# (PR refs, a mirrored fork). Destroying a configuration you did not come here
# to fix, in order to fix a different one, is precisely how the next incident
# gets made. `git config --add` after an exact-line check is idempotent.
say "origin refspec"
WIDE_REFSPEC='+refs/heads/*:refs/remotes/origin/*'
if git config --get-all remote.origin.fetch 2>/dev/null | grep -Fqx -- "$WIDE_REFSPEC"; then
  ok "remote.origin.fetch already covers all branches"
elif [ "$DRY_RUN" -eq 1 ]; then
  # Skipped under --dry-run so the whole read-only path can be exercised on a
  # host where .git is write-protected.
  warn "narrow remote.origin.fetch; would 'git config --add remote.origin.fetch $WIDE_REFSPEC'"
else
  git config --add remote.origin.fetch "$WIDE_REFSPEC"
  ok "added $WIDE_REFSPEC (existing refspecs left intact)"
fi

# ------------------------------------------------------------- 2. fetch --
say "fetch"
if [ "$DRY_RUN" -eq 1 ]; then
  warn "dry run: no fetch, resolving against the refs already on disk"
else
  git fetch --prune origin >&2 || die 11 "git fetch --prune origin failed"
  # Second chance for a commit that is not reachable from any branch head -
  # a force-push landed after the webhook fired, or the request names a commit
  # on a ref this clone does not track. Failure here is not fatal: the resolve
  # below is what decides, and it reports the ref that could not be found.
  if [ -n "$REQ_SHA" ]; then
    git fetch origin "$REQ_SHA" >/dev/null 2>&1 || true
  fi
  ok "fetched"
fi

# ------------------------------------------------------------ 3. resolve --
# The structural fix for the narrow-refspec repos: name the missing ref at
# second 2 with exit 11 (-> 404, "you asked for something I cannot get"),
# instead of letting it appear four steps later as a checkout error.
say "resolve"
if [ -n "$REQ_SHA" ]; then
  TARGET="$REQ_SHA"
  ORIGIN_DESC="requested sha $REQ_SHA"
else
  TARGET="refs/remotes/origin/${DEPLOY_FALLBACK_REF}"
  ORIGIN_DESC="origin/${DEPLOY_FALLBACK_REF}"
fi
SHA="$(git rev-parse --verify --quiet "${TARGET}^{commit}" || true)"
[ -n "$SHA" ] || die 11 "cannot resolve ${ORIGIN_DESC} in $ROOT"
ok "$ORIGIN_DESC -> $SHA"

# ------------------------------------------------------- 4. object exists --
# rev-parse can answer from a ref or a packed index while the object itself is
# missing (a partial/promisor clone, an interrupted fetch). cat-file -e is the
# question "is the commit really here", and it is cheap.
git cat-file -e "${SHA}^{commit}" 2>/dev/null \
  || die 11 "commit $SHA is named but not present in the object store"
ok "commit object present"

# --------------------------------------------------- 5. detach, not reset --
# `git reset --hard <sha>` while sitting on main MOVES LOCAL main to that
# commit. If the SHA is not on main - a tag, a hotfix, a re-deploy of an older
# build - the repo then agrees with itself about a history that never existed,
# and the next `git status` reports a clean tree at the wrong commit. Detaching
# touches no branch ref at all, so the worst case stays "HEAD points somewhere
# odd" and never becomes "main is a lie".
#
# --force because a deploy work tree is disposable and a previous deploy may
# have scribbled in it; --force discards those local edits WITHOUT moving any
# branch, which is the whole distinction being drawn here.
#
# After this, `git rev-parse --abbrev-ref HEAD` returns the literal string
# `HEAD`. That is by design, not damage - anything reading the branch name to
# decide what is deployed should read DEPLOYED_SHA from the metadata instead.
say "checkout"
if [ "$DRY_RUN" -eq 1 ]; then
  warn "dry run: would 'git checkout --force --detach $SHA' then 'git clean -fd'"
else
  git checkout --force --detach "$SHA" >&2 \
    || die 12 "git checkout --force --detach $SHA failed"
  # -fd, never -fdx. `-x` also deletes ignored files, which on a deploy host
  # means .env, credentials and bind-mounted state - the running stack's own
  # footing. That is the shape of the 2026-08-23 incident, where a deploy
  # overwrote the live webhook listener with a stale copy and the pipeline
  # locked itself out with 401s for two deploys.
  git clean -fd >&2 || die 12 "git clean -fd failed"
  ok "detached at $SHA, untracked files cleaned"
fi

# ------------------------------------------------- 6. the tree assertion --
# Three lines that turn "we built the wrong tree for four minutes" into "we
# refused in one second".
say "assert tree"
if [ "$DRY_RUN" -eq 1 ]; then
  # No checkout happened, so HEAD cannot be compared. The equivalent read-only
  # question is whether the object the request names really resolves to itself
  # - that is exactly the identity the post-checkout assert tests.
  RESOLVED="$(git rev-parse --verify --quiet "${SHA}^{commit}" || true)"
  [ "$RESOLVED" = "$SHA" ] || die 12 "dry run: $SHA does not resolve to itself (got '${RESOLVED:-none}')"
  ok "dry run: $SHA is the commit that would be checked out"
else
  HEAD_SHA="$(git rev-parse HEAD)"
  [ "$HEAD_SHA" = "$SHA" ] || die 12 "HEAD is $HEAD_SHA, expected $SHA"
  ok "HEAD == $SHA"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  say "dry run complete"
  ok "steps 1-6 passed; no container was touched"
  exit 0
fi

# --------------------------------------------------------- 7. pre-hook --
say "pre-deploy hook"
export DEPLOY_SHA="$SHA"
if [ -x scripts/deploy-pre.sh ]; then
  ./scripts/deploy-pre.sh >&2 || die 13 "scripts/deploy-pre.sh failed; containers untouched"
  ok "scripts/deploy-pre.sh ok"
else
  ok "no scripts/deploy-pre.sh"
fi

# --------------------------------------------------------- 8. metadata --
# The old script APPENDED DEPLOYED_GIT_SHA= on every deploy, so the file grew
# two lines per deploy forever and compose's last-wins parsing hid it. This
# filters the pair out and writes it once.
#
# `cat tmp > "$META"`, never `mv tmp "$META"`. mv replaces the inode: the new
# file arrives with default permissions (losing 0600 on a file full of
# secrets) and every bind mount of that path in a running container is left
# pointing at the old, now-orphaned inode. Truncate-and-write keeps both.
say "metadata"
META="$DEPLOY_META_FILE"
META_TMP="$(mktemp)"; TMPS+=("$META_TMP")
if [ -f "$META" ]; then
  grep -vE '^DEPLOYED_GIT_SHA=|^DEPLOYED_AT=' "$META" > "$META_TMP" || true
  # A file whose last line has no newline would otherwise swallow the first
  # line appended after it.
  if [ -s "$META_TMP" ]; then
    if [ "$(tail -c 1 "$META_TMP" | wc -l)" -eq 0 ]; then printf '\n' >> "$META_TMP"; fi
  fi
else
  # Only a file this script creates gets its mode chosen here. Never chmod an
  # existing one: its permissions are part of what the running stack depends on.
  (umask 077; : > "$META")
  warn "$META did not exist; created 0600"
fi
printf 'DEPLOYED_GIT_SHA=%s\nDEPLOYED_AT=%s\n' "$SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$META_TMP"
cat "$META_TMP" > "$META"
ok "$META: DEPLOYED_GIT_SHA replaced, not appended"

# ----------------------------------------------------------- 9. docker --
# Teardown first: `up` alone leaves a renamed or orphaned container holding the
# name and the port, and the failure that produces reads like a build error.
#
# --wait is the reason this is Compose v5 (host runs Docker 29.4.3 / Compose
# v5.1.3): its exit code means HEALTHY, not "started". Note the limit - a
# service with no `healthcheck:` block is not waited on at all, it only has to
# be running, which is why step 10 exists as an independent assert.
say "docker"
have docker || die 10 "docker is not on PATH"
docker compose down --remove-orphans >&2 || die 13 "docker compose down failed"
ok "torn down"
if ! docker compose up -d --build --wait --wait-timeout "$DEPLOY_HEALTH_TIMEOUT" >&2; then
  die 13 "docker compose up failed or a service never became healthy within ${DEPLOY_HEALTH_TIMEOUT}s"
fi
ok "up and healthy per compose"

# --------------------------------------------- 10. the health assertion --
# `if ! ...; then` and never `A && B || C`. The list form returns the status of
# the LAST command, so the failure branch's own success became the script's
# exit status - that single line is why an unhealthy stack reported HTTP 200.
say "health assert"
if [ -z "$DEPLOY_HEALTH_URL" ]; then
  # Loud, because a silent skip is indistinguishable from a pass, and the
  # whole point of this file is that a green result means something.
  warn "DEPLOY_HEALTH_URL is not set in .deploy.conf - HEALTH ASSERT SKIPPED"
  warn "this deploy is reported as successful WITHOUT any health evidence"
else
  have curl || die 10 "DEPLOY_HEALTH_URL is set but curl is not on PATH - the assert cannot be honoured, and reporting an unverified deploy as healthy is the bug this file exists to prevent"
  BODY="$(mktemp)"; TMPS+=("$BODY")
  DEADLINE=$(( $(date +%s) + DEPLOY_HEALTH_TIMEOUT ))
  HEALTHY=0
  while :; do
    if curl -fsS -m 10 -o "$BODY" "$DEPLOY_HEALTH_URL" 2>/dev/null; then HEALTHY=1; break; fi
    if [ "$(date +%s)" -ge "$DEADLINE" ]; then break; fi
    sleep 3
  done
  [ "$HEALTHY" -eq 1 ] \
    || die 14 "no 2xx from $DEPLOY_HEALTH_URL within ${DEPLOY_HEALTH_TIMEOUT}s (containers are up at $SHA)"
  ok "2xx from $DEPLOY_HEALTH_URL"

  # Healthy is not the same as healthy AT THE REQUESTED COMMIT: a container
  # that failed to rebuild and kept serving the previous image answers 200 all
  # day. Only a hex run that follows a sha/commit/revision key is considered,
  # so an unrelated request id in the body cannot fake a mismatch.
  REPORTED="$(grep -oiE '(git[_-]?)?(sha|commit|revision)"?[^0-9a-fA-F]{1,6}[0-9a-fA-F]{7,40}' "$BODY" 2>/dev/null \
              | grep -oiE '[0-9a-fA-F]{7,40}$' | head -1 || true)"
  REPORTED="$(printf '%s' "$REPORTED" | tr 'A-F' 'a-f')"
  if [ -z "$REPORTED" ]; then
    warn "health body reports no sha/commit field - deployed SHA could not be cross-checked"
  else
    case "$SHA" in
      "$REPORTED"*) ok "health endpoint reports $REPORTED" ;;
      *)            die 15 "health endpoint is healthy but reports $REPORTED, deployed $SHA" ;;
    esac
  fi
fi

# -------------------------------------------------------- 11. post-hook --
say "post-deploy hook"
if [ -x scripts/deploy-post.sh ]; then
  ./scripts/deploy-post.sh >&2 \
    || die 13 "scripts/deploy-post.sh failed - the stack IS live and healthy at $SHA, so this needs a human, not a redeploy"
  ok "scripts/deploy-post.sh ok"
else
  ok "no scripts/deploy-post.sh"
fi

# ------------------------------------------------- 12. machine-readable --
say "done"
ok "deployed and healthy at $SHA"
printf 'DEPLOYED_SHA=%s\n' "$SHA"
