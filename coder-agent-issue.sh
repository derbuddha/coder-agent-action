#!/usr/bin/env bash
# =============================================================================
# coder-agent-issue.sh  —  the body of the "Coder Agent on Issue" action.
#
# Everything is configured through env vars, which action.yaml fills from the
# action inputs. The script is also runnable by hand on any box that can reach
# both Coder and Gitea (export the same vars, then: bash coder-agent-issue.sh).
#
# Flow:
#   1. resolve org / template / model names to UUIDs
#   2. make sure the deterministic git wrapper exists in the repo (bootstrap it
#      onto the issue branch if it's on neither branch — base branches are
#      commonly protected, so a bot token can't write there directly; it rides
#      into the base branch later via the normal PR merge)
#   3. read the issue (title + body + every comment + the attachments of
#      both) via the Gitea API
#   4. create a workspace from the template, passing the SSH clone URL as a
#      rich parameter so the repo is cloned before the agent starts
#   5. create a chat pinned to that workspace; prompt = issue text + instructions
#   6. poll status until running -> waiting (waiting is the idle/done state)
#   7. open a PR (head <branch-prefix>N -> base) and comment on the issue
#   8. apply the workspace lifecycle policy (STOP_AFTER)
#
# The Gitea token stays on THIS side. The workspace never sees it; the agent
# only commits + pushes the branch over the SSH key the template already has.
# =============================================================================
set -euo pipefail

# --- required ----------------------------------------------------------------
: "${CODER_URL:?e.g. https://coder.example.com}"
: "${CODER_SESSION_TOKEN:?service-account API token}"

# Gitea Actions forbids secrets named GITEA_*, so the token arrives as
# FORGE_TOKEN there; a plain shell can just export GITEA_TOKEN.
GITEA_TOKEN="${GITEA_TOKEN:-${FORGE_TOKEN:-}}"
: "${GITEA_TOKEN:?set GITEA_TOKEN (shell) or FORGE_TOKEN (CI) — needs repo+issue+PR scope}"

if [ -z "${AGENT_TEMPLATE_ID:-}" ] && [ -z "${AGENT_TEMPLATE:-}" ]; then
  echo "Set coder-template-name (or coder-template-id). In Actions this comes"
  echo "from the AGENT_TEMPLATE repo/org variable — check it is set and not empty."
  exit 1
fi

# --- defaults / fall-backs from the runner environment -----------------------
CODER_URL="${CODER_URL%/}"
CODER_ORG="${CODER_ORG:-coder}"
GITEA_URL="${GITEA_URL:-${GITHUB_SERVER_URL:-}}"
GITEA_URL="${GITEA_URL%/}"
: "${GITEA_URL:?could not determine the Gitea URL — set gitea-url}"

# Resolve ACTION_PATH up-front so every later reference (template bootstrap
# source, finish-script bootstrap, etc.) sees a defined value under `set -u`.
# $GITHUB_ACTION_PATH is set by the Actions runner inside the action's own
# step shell; when the script is invoked from a caller-defined workflow step
# (`.action/coder-agent-issue.sh`), it stays unset and we fall back to the
# script's own directory.
ACTION_PATH="${ACTION_PATH:-${GITHUB_ACTION_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"

REPO_OWNER="${REPO_OWNER:-${GITHUB_REPOSITORY%%/*}}"
REPO_NAME="${REPO_NAME:-${GITHUB_REPOSITORY##*/}}"
: "${REPO_OWNER:?}"; : "${REPO_NAME:?}"

ISSUE_NUM="${ISSUE_NUM:-}"
if [ -z "$ISSUE_NUM" ] && [ -f "${GITHUB_EVENT_PATH:-/nonexistent}" ]; then
  ISSUE_NUM=$(jq -r '.issue.number // .pull_request.number // empty' "$GITHUB_EVENT_PATH")
fi
: "${ISSUE_NUM:?no issue number — set issue-number or trigger on an issue event}"

GITEA_SSH_HOST="${GITEA_SSH_HOST:-}"
GITEA_SSH_PORT="${GITEA_SSH_PORT:-}"

BASE_BRANCH="${BASE_BRANCH:-main}"
BRANCH_PREFIX="${BRANCH_PREFIX:-ai/issue-}"
BRANCH="${BRANCH_PREFIX}${ISSUE_NUM}"
FINISH_SCRIPT_PATH="${FINISH_SCRIPT_PATH:-.gitea/scripts/finish-issue.sh}"
BOOTSTRAP_FINISH="${BOOTSTRAP_FINISH:-true}"
COMMENT_ON_ISSUE="${COMMENT_ON_ISSUE:-true}"
# Issue attachments. The runner can read them (it holds the Gitea token), the
# workspace cannot — so text files are pulled here and inlined into the prompt,
# and anything binary or oversized is listed by name so the agent at least
# knows it exists. Two budgets keep a 50 MB log out of the context window: a
# per-file cap and a total across all inlined files.
INCLUDE_ATTACHMENTS="${INCLUDE_ATTACHMENTS:-true}"
ATTACHMENT_MAX_BYTES="${ATTACHMENT_MAX_BYTES:-65536}"
ATTACHMENT_TOTAL_BYTES="${ATTACHMENT_TOTAL_BYTES:-262144}"
# What can't be inlined (images, PDFs, big logs) is handed over as files: the
# runner commits them to a throwaway side branch and the agent extracts that
# into WS_ATTACHMENT_DIR — outside the clone, so nothing lands in the PR. The
# side branch is deleted when the run ends. Per-file cap; 0 = off.
ATTACHMENT_PUSH_MAX_BYTES="${ATTACHMENT_PUSH_MAX_BYTES:-10485760}"
ATT_BRANCH_SUFFIX="${ATT_BRANCH_SUFFIX:--attachments}"
ATT_BRANCH_SUBDIR=".issue-attachments"
ATT_BRANCH="${BRANCH}${ATT_BRANCH_SUFFIX}"
WS_ATTACHMENT_DIR="${WS_ATTACHMENT_DIR:-/tmp/coder-agent-attachments/issue-${ISSUE_NUM}}"
# Comment paging. Gitea caps `limit` at MAX_RESPONSE_ITEMS (50 by default), so
# the fetch below walks pages until one comes back short.
COMMENT_PAGE_SIZE="${COMMENT_PAGE_SIZE:-50}"
COMMENT_MAX_PAGES="${COMMENT_MAX_PAGES:-20}"
# Path the agent writes its 5-sentence change summary to. The action reads this
# from the branch after the agent pushes and pastes it into the PR body
# between "Automated by the Coder Agent." and "Closes #N". Empty = skip.
SUMMARY_PATH="${SUMMARY_PATH:-.gitea/agent-summary.md}"
# Opt-in PR-template support. PR_TEMPLATE_PATH is the repo path of the template
# (e.g. `.gitea/PULL_REQUEST_TEMPLATE.md` or `.gitea/pull_request_template.yaml`).
# Empty = no template, use the built-in body. PR_TEMPLATE_TYPE is documentary:
# both formats are treated as text and the `<!-- AI_SUMMARY -->` /
# `{{ AI_SUMMARY }}` markers are substituted in either case. Required fields in
# a YAML form template are NOT enforced — those are for human reviewers.
PR_TEMPLATE_PATH="${PR_TEMPLATE_PATH:-.gitea/PULL_REQUEST_TEMPLATE.yaml}"
PR_TEMPLATE_TYPE="${PR_TEMPLATE_TYPE:-yaml}"
# The shipped PR template, used to bootstrap the consumer repo when
# $PR_TEMPLATE_PATH is missing on $BASE_BRANCH. Mirrors the finish-issue.sh
# bootstrap: the file rides into $BASE_BRANCH via the PR the action opens, so
# the bot token never has to write to a protected branch directly.
for c in "$ACTION_PATH/templates/PULL_REQUEST_TEMPLATE.yaml" \
         "$ACTION_PATH/PULL_REQUEST_TEMPLATE.yaml" \
         "$ACTION_PATH/pull_request_template.yaml"; do
  if [ -f "$c" ]; then PR_TEMPLATE_BOOTSTRAP_SRC="$c"; break; fi
done
# Optional in-script label guard. Empty by default, unlike refine-issue-action:
# the README documents wiring a SECOND label to its own job and template, and a
# hardcoded default would make that job skip itself. Set it to double-check the
# workflow's own `if:` guard — worth it, since a mistaken run costs a workspace.
REQUIRE_LABEL="${REQUIRE_LABEL-}"
# Off by default: dropping the label is itself a label_updated event, and Gitea
# starts a run of every label-triggered workflow for it — all of them skipping,
# but all of them showing up in the run list.
REMOVE_LABEL="${REMOVE_LABEL:-false}"
WS_CHECKOUT_DIR="${WS_CHECKOUT_DIR:-/home/coder/GIT}"
# Marker lines that gitea/refine-issue-action writes around its generated
# section. Kept in sync with that action's section-begin / section-end inputs;
# used to split that section out of the body as the agent's specification.
SECTION_BEGIN="${SECTION_BEGIN:-<!-- agent:begin -->}"
SECTION_END="${SECTION_END:-<!-- agent:end -->}"
GIT_REPO_PARAM="${GIT_REPO_PARAM:-git_repo_url}"
WS_NAME_PREFIX="${WS_NAME_PREFIX:-agent}"
CODER_CHAT_PATH="${CODER_CHAT_PATH:-/agents/}"
POLL_TIMEOUT="${POLL_TIMEOUT:-3600}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-900}"
# Some models end their turn mid-task (a reasoning-only reply, no tool call),
# which Coder reports as `waiting` just like a finished run. When the chat goes
# idle but the branch has not moved, post a follow-up telling the agent to
# carry on — at most MAX_NUDGES times, then give up as before. 0 = off.
MAX_NUDGES="${MAX_NUDGES:-3}"
STOP_AFTER="${STOP_AFTER:-1h}"
# Attempts per GET when the host is unreachable (HTTP 000). 1 = no retry.
API_RETRIES="${API_RETRIES:-3}"
FAIL_ON_NO_PR="${FAIL_ON_NO_PR:-true}"
RUN_ID="${RUN_ID:-${GITHUB_RUN_ID:-$(date +%s)}}"

# --- tiny API helpers --------------------------------------------------------
# api_call writes the response body to stdout and returns non-zero on any
# non-2xx, like `curl -f` did — but it also reports the status and the server's
# message on stderr, so an expired token reads as "HTTP 401" instead of
# surfacing three steps later as an empty jq result. A 404 stays quiet: several
# call sites use it as an existence probe.
api_call() { # label url auth-header method path [body]
  local label="$1" base="$2" auth="$3" m="$4" p="$5" b="${6:-}" resp code body
  if [ -n "$b" ]; then
    # A body of "@<file>" is sent from that file: attachment uploads run to
    # megabytes, far past the 128 KiB Linux allows a single argument.
    local data=(-d "$b")
    case "$b" in @*) data=(--data-binary "$b") ;; esac
    resp=$(curl -sS -w $'\n%{http_code}' -X "$m" "$base$p" \
      -H "$auth" -H "Content-Type: application/json" "${data[@]}" 2>&1) || resp=$'\n000'
  else
    # GETs are safe to repeat, so a connection failure (HTTP 000: DNS, refused,
    # TLS, timeout) gets API_RETRIES attempts with a short backoff — runners
    # sometimes come up before their network does.
    local try=1 tries=1
    [ "$m" = GET ] && tries="$API_RETRIES"
    while :; do
      resp=$(curl -sS -w $'\n%{http_code}' -X "$m" "$base$p" -H "$auth" 2>&1) || resp=$'\n000'
      [ "${resp##*$'\n'}" = 000 ] && [ "$try" -lt "$tries" ] || break
      echo "    $label API: $m $p unreachable (attempt $try/$tries), retrying in $((try * 5))s..." >&2
      sleep $((try * 5)); try=$((try + 1))
    done
  fi
  code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
  case "$code" in
    2??) printf '%s' "$body"; : > "$API_ERR_FILE"; return 0 ;;
    404) return 1 ;;
  esac
  local detail hint=""
  detail=$(printf '%s' "$body" | jq -r '.message // .detail // empty' 2>/dev/null || true)
  [ -n "$detail" ] || detail=$(printf '%s' "$body" | tr '\n' ' ' | head -c 300)
  case "$code" in
    000) hint="could not reach $base — check the URL and the runner network" ;;
    401) hint="the $label token is missing, expired or from another deployment" ;;
    403) hint="the $label token authenticated but lacks permission for this call" ;;
  esac
  # Kept in a FILE, not a variable: nearly every call site is a $( ) capture,
  # and a global assigned in that subshell would never reach the exit trap.
  local msg="$label API: $m $p -> HTTP $code"
  [ -n "$detail" ] && msg="$msg
    $detail"
  [ -n "$hint" ] && msg="$msg
    ($hint)"
  printf '%s\n' "$msg" > "$API_ERR_FILE"
  printf '%s\n' "$msg" >&2
  return 1
}
coder_api() { # method path [body]
  api_call Coder "$CODER_URL" "Coder-Session-Token: $CODER_SESSION_TOKEN" "$@"
}
gitea_api() { # method path [body]
  api_call Gitea "$GITEA_URL/api/v1" "Authorization: token $GITEA_TOKEN" "$@"
}
# Attachment bodies live on Gitea's WEB routes (/attachments/<uuid>), not under
# /api/v1, so they can't go through api_call. --max-filesize stops a huge file
# before it lands on the runner; curl drops the Authorization header when a
# redirect leaves the Gitea host (object-storage backends hand out a signed
# URL), which is exactly what we want — the token never follows the file.
gitea_download() { # url outfile max-bytes
  curl -fsSL --max-time 60 --max-filesize "$3" \
    -H "Authorization: token $GITEA_TOKEN" -o "$2" "$1" 2>/dev/null
}
# The attachments side branch only has to live until the agent has fetched it;
# called once the chat goes idle and again from the exit trap. Best effort.
drop_att_branch() {
  [ "$ATT_BRANCH_CREATED" = true ] || return 0
  if gitea_api DELETE "/repos/$REPO_OWNER/$REPO_NAME/branches/$ATT_BRANCH" >/dev/null 2>&1; then
    echo "==> Deleted attachments branch $ATT_BRANCH"
  else
    echo "!! Could not delete attachments branch $ATT_BRANCH — delete it by hand."
  fi
  ATT_BRANCH_CREATED=false
  : > "$API_ERR_FILE"  # not the run's failure reason
}
# A NUL byte is the cheap, portable "don't paste this into a prompt" test: it
# catches images, archives and compiled blobs without an extension allowlist.
is_binary() { # file
  local total nulless
  total=$(wc -c < "$1" | tr -d ' ')
  nulless=$(LC_ALL=C tr -d '\000' < "$1" | wc -c | tr -d ' ')
  [ "$total" != "$nulless" ]
}
human_size() { # bytes -> "12.3 KiB"
  awk -v b="${1:-0}" 'BEGIN {
    split("B KiB MiB GiB", u, " "); i = 1
    while (b >= 1024 && i < 4) { b /= 1024; i++ }
    printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i]
  }'
}
issue_comment() { # body — best effort, never fails the run
  [ "$COMMENT_ON_ISSUE" = "true" ] || return 0
  gitea_api POST "/repos/$REPO_OWNER/$REPO_NAME/issues/$ISSUE_NUM/comments" \
    "$(jq -n --arg b "$1" '{body:$b}')" >/dev/null 2>&1 || true
}
link_html() { # url text -> <a target=_blank> anchor (Gitea markdown ignores the
              # {:target="_blank"} shorthand but sanitizes-through raw <a> HTML)
  printf '<a href="%s" target="_blank" rel="noopener noreferrer">%s</a>' "$1" "$2"
}
set_output() { # name value
  [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  return 0
}

# --- failure reporting -------------------------------------------------------
# Every non-zero exit lands in on_exit, which repeats the reason where people
# actually look — the job summary and a comment on the issue that triggered the
# run — instead of leaving it in a runner log nobody opens. `die` is the same
# thing with a reason attached; a failure that never calls it still gets
# reported, just with the script line instead of a sentence.
LAST_API_ERROR=""; FAIL_REASON=""; FAIL_HINT=""; FAIL_LINE=""; REPORTED=false
# AGENT_LIVE: a chat was started and is not idle (waiting/error) yet.
# WS_HALTED:  halt_agent already stopped the workspace (step 7 then skips).
# CAUGHT_SIGNAL: the runner cancelled the job (timeout-minutes, manual cancel).
AGENT_LIVE=false; WS_HALTED=false; CAUGHT_SIGNAL=""
ATT_TMPDIR=""; ATT_BRANCH_CREATED=false
API_ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/coder-agent-api-err.XXXXXX")

die() { # reason [hint]
  FAIL_REASON="$1"; FAIL_HINT="${2:-}"
  printf '%s\n' "$FAIL_REASON" >&2
  [ -n "$FAIL_HINT" ] && printf '%s\n' "$FAIL_HINT" >&2
  exit 1
}

# The same as pressing the stop button in the Coder UI, plus stopping the
# workspace so nothing the agent already queued can still commit or push.
# Best effort throughout: this also runs from the exit trap. CHAT_ID is only
# ever set after the sanity step has picked CHAT_API.
halt_agent() { # why
  echo "==> Stopping the agent ($1)"
  if [ -n "${CHAT_ID:-}" ]; then
    if coder_api POST "$CHAT_API/chats/$CHAT_ID/interrupt" >/dev/null 2>&1; then
      echo "    chat interrupted"
    else
      echo "!! Could not interrupt the chat — stop it by hand: $CHAT_URL"
    fi
  fi
  if [ -n "${WORKSPACE_ID:-}" ]; then
    if coder_api POST "/api/v2/workspaces/$WORKSPACE_ID/builds" '{"transition":"stop"}'          >/dev/null 2>&1; then
      echo "    workspace stop queued"
    else
      echo "!! Could not stop the workspace — stop it by hand: $WORKSPACE_URL"
    fi
  fi
  AGENT_LIVE=false; WS_HALTED=true
  : > "$API_ERR_FILE"  # a failed best-effort call is not the run's failure reason
}

on_exit() {
  local code=$? reason="" links=""
  # Cancelled or aborted mid-run: don't leave an agent working on a job nobody
  # watches. A cancel during the build has no chat yet, but its workspace would
  # never get the stop-after deadline either.
  if [ "$AGENT_LIVE" = true ] || { [ -n "$CAUGHT_SIGNAL" ] && [ "$WS_HALTED" != true ]; }; then
    if [ -n "$CAUGHT_SIGNAL" ]; then
      halt_agent "job cancelled ($CAUGHT_SIGNAL)" || true
      [ -n "$FAIL_REASON" ]         || FAIL_REASON="The job was cancelled ($CAUGHT_SIGNAL) — the agent and its workspace were stopped."
    else
      halt_agent "run aborted" || true
    fi
  fi
  LAST_API_ERROR=$(cat "$API_ERR_FILE" 2>/dev/null || true)
  drop_att_branch || true
  rm -f "$API_ERR_FILE"
  if [ -n "${ATT_TMPDIR:-}" ]; then rm -rf "$ATT_TMPDIR"; fi
  if [ "$code" -eq 0 ]; then return 0; fi
  reason="$FAIL_REASON"
  if [ -z "$reason" ]; then
    reason="The action failed unexpectedly${FAIL_LINE:+ (coder-agent-issue.sh line $FAIL_LINE)}."
  fi
  set_output result "${RESULT:-failed}"

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "## ❌ Coder Agent failed"
      echo
      echo "$reason"
      if [ -n "$FAIL_HINT" ];      then echo; echo "$FAIL_HINT"; fi
      if [ -n "$LAST_API_ERROR" ]; then echo; echo '```'; echo "$LAST_API_ERROR"; echo '```'; fi
      echo
      echo "Issue #${ISSUE_NUM} · branch \`${BRANCH}\`"
      if [ -n "${CHAT_URL:-}" ];      then echo "· Agent chat: ${CHAT_URL}"; fi
      if [ -n "${WORKSPACE_URL:-}" ]; then echo "· Workspace: ${WORKSPACE_URL}"; fi
    } >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
  fi

  # The end-of-run path posts its own verdict; don't say it twice.
  if [ "$REPORTED" != true ]; then
    if [ -n "${CHAT_URL:-}" ]; then links="🔗 $(link_html "$CHAT_URL" "Agent chat")"; fi
    if [ -n "${WORKSPACE_URL:-}" ]; then
      links="${links:+$links · }$(link_html "$WORKSPACE_URL" "Workspace")"
    fi
    issue_comment "❌ **Coder Agent failed.**

${reason}${FAIL_HINT:+

${FAIL_HINT}}${LAST_API_ERROR:+

\`\`\`
${LAST_API_ERROR}
\`\`\`}${links:+

${links}}"
  fi
  return 0
}
trap 'FAIL_LINE=$LINENO' ERR
trap on_exit EXIT
# Without these, a cancel kills bash before the EXIT trap can clean up.
trap 'CAUGHT_SIGNAL=SIGTERM; exit 143' TERM
trap 'CAUGHT_SIGNAL=SIGINT;  exit 130' INT
trap 'CAUGHT_SIGNAL=SIGHUP;  exit 129' HUP

echo "==> Repo ${REPO_OWNER}/${REPO_NAME}  issue #${ISSUE_NUM}  branch ${BRANCH}"

# --- 0. label guard ----------------------------------------------------------
# Runs before anything is resolved, created or committed: a wrong trigger should
# cost one API call, not a workspace. $ISSUE is reused by step 3.
ISSUE=""
if [ -n "$REQUIRE_LABEL" ]; then
  ISSUE=$(gitea_api GET "/repos/$REPO_OWNER/$REPO_NAME/issues/$ISSUE_NUM") \
    || die "Could not read issue #$ISSUE_NUM from Gitea." \
           "The token needs read access to $REPO_OWNER/$REPO_NAME; in Actions it arrives as \`FORGE_TOKEN\`."
  if ! echo "$ISSUE" | jq -e --arg l "$REQUIRE_LABEL" 'any(.labels[]?; .name == $l)' >/dev/null; then
    echo "Issue #${ISSUE_NUM} does not carry label '${REQUIRE_LABEL}' — nothing to do."
    set_output result skipped
    exit 0
  fi
fi

# Which label a successful run drops: the one that was required, or failing that
# the one that actually triggered this run — so a second label wired to its own
# job removes itself rather than the first job's label.
TRIGGER_LABEL="$REQUIRE_LABEL"
if [ -z "$TRIGGER_LABEL" ] && [ -f "${GITHUB_EVENT_PATH:-/nonexistent}" ]; then
  TRIGGER_LABEL=$(jq -r '.changes.added_labels[0].name // empty' "$GITHUB_EVENT_PATH" 2>/dev/null || true)
fi

# --- 0b. the SSH clone URL the workspace will use ----------------------------
# Gitea already tells us this: the event payload carries .repository.ssh_url,
# and the API returns the same. It is built from SSH_DOMAIN / SSH_PORT in
# app.ini, so it is only correct if that is reachable *from the Coder
# workspace* — a different network than this runner. When it isn't, override
# with gitea-ssh-host / gitea-ssh-port.
to_ssh_scheme() { # accepts ssh://git@host[:port]/o/r.git or git@host:o/r.git
  local u="$1" hp host path
  case "$u" in
    ssh://*) printf '%s' "$u" ;;
    *@*:*)   hp="${u#*@}"; host="${hp%%:*}"; path="${hp#*:}"
             printf 'ssh://git@%s/%s' "$host" "${path#/}" ;;
    *)       printf '%s' "$u" ;;
  esac
}

if [ -n "$GITEA_SSH_HOST" ]; then
  GIT_REPO_SSH="ssh://git@${GITEA_SSH_HOST}:${GITEA_SSH_PORT:-22}/${REPO_OWNER}/${REPO_NAME}.git"
  echo "    clone url (from inputs): $GIT_REPO_SSH"
else
  RAW=""
  [ -f "${GITHUB_EVENT_PATH:-/nonexistent}" ] && \
    RAW=$(jq -r '.repository.ssh_url // empty' "$GITHUB_EVENT_PATH" 2>/dev/null || true)
  [ -n "$RAW" ] || \
    RAW=$(gitea_api GET "/repos/$REPO_OWNER/$REPO_NAME" | jq -r '.ssh_url // empty') || RAW=""
  if [ -n "$RAW" ]; then
    GIT_REPO_SSH=$(to_ssh_scheme "$RAW")
    echo "    clone url (from Gitea): $GIT_REPO_SSH"
  else
    GIT_REPO_SSH="ssh://git@$(printf '%s' "$GITEA_URL" | sed -E 's#^[a-z]+://##; s#/.*$##; s#:.*$##')/${REPO_OWNER}/${REPO_NAME}.git"
    echo "    clone url (guessed from gitea-url): $GIT_REPO_SSH"
  fi
  # An explicit port still wins, e.g. when SSH_PORT in app.ini is wrong.
  if [ -n "$GITEA_SSH_PORT" ]; then
    GIT_REPO_SSH=$(printf '%s' "$GIT_REPO_SSH" \
      | sed -E "s#^(ssh://[^/]*@[^:/]+)(:[0-9]+)?#\1:${GITEA_SSH_PORT}#")
    echo "    port overridden: $GIT_REPO_SSH"
  fi
fi

# --- 1. sanity + name -> UUID resolution -------------------------------------
echo "==> Sanity: does the Coder token work?"
coder_api GET /api/v2/users/me >/dev/null \
  || die "Could not authenticate to $CODER_URL." \
         "HTTP 401 means the token is stale — mint a new one (\`coder tokens create --name gitea-actions --lifetime 1y\`) and update the \`coder-token\` secret. HTTP 000 means the runner cannot reach \`coder-url\` at all."

if [[ "$CODER_ORG" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}- ]]; then
  CODER_ORG_ID="$CODER_ORG"
else
  echo "==> Resolving organization '$CODER_ORG' -> UUID"
  CODER_ORG_ID=$(coder_api GET "/api/v2/organizations/$CODER_ORG" | jq -r '.id // empty') \
    || CODER_ORG_ID=""
  [ -n "$CODER_ORG_ID" ] || die "Unknown Coder organization '$CODER_ORG'." \
    "Set the \`CODER_ORG\` variable to an organization name or UUID that exists on $CODER_URL."
fi
echo "    organization_id=$CODER_ORG_ID"

echo "==> Sanity: at least one LLM model configured?"
# Coder 2.37 promoted chats to /api/v2 and made models organization-scoped
# ({models, providers, ...}); older releases only have the deployment-wide
# /api/experimental list ({providers, unsupported_providers}), where the models
# are counted recursively. Whichever answers picks the prefix for every chat call.
if CHAT_MODELS=$(coder_api GET "/api/v2/organizations/$CODER_ORG_ID/chats/models"); then
  CHAT_API=/api/v2
  MODEL_COUNT=$(echo "$CHAT_MODELS" | jq '[.models[]? | select(.enabled)] | length')
elif CHAT_MODELS=$(coder_api GET /api/experimental/chats/models); then
  CHAT_API=/api/experimental
  MODEL_COUNT=$(echo "$CHAT_MODELS" \
    | jq '[.providers[]? | (.. | objects | select(has("id")))] | length')
else
  die "No Chats API found on $CODER_URL." \
      "Neither /api/v2/organizations/<org>/chats/models nor /api/experimental/chats/models answered — the Coder release may predate Coder Agents, or the feature is disabled."
fi
echo "    chat_api=$CHAT_API"
[ "${MODEL_COUNT:-0}" -gt 0 ] \
  || die "No enabled LLM model is configured on $CODER_URL." \
         "Add a provider and model to the Coder deployment (organization '$CODER_ORG'), then re-run."

if [ -z "${AGENT_TEMPLATE_ID:-}" ]; then
  echo "==> Resolving template '$AGENT_TEMPLATE' -> UUID"
  AGENT_TEMPLATE_ID=$(coder_api GET \
    "/api/v2/organizations/$CODER_ORG_ID/templates/$AGENT_TEMPLATE" | jq -r '.id // empty') \
    || AGENT_TEMPLATE_ID=""
  [ -n "$AGENT_TEMPLATE_ID" ] \
    || die "Could not resolve template '$AGENT_TEMPLATE' in organization '$CODER_ORG'." \
           "Check the \`AGENT_TEMPLATE\` variable against the template names on $CODER_URL/templates."
fi
echo "    template_id=$AGENT_TEMPLATE_ID"

# Optional model pinning. MODEL_CONFIG_ID (UUID) wins; else AGENT_MODEL is looked
# up among the chat models by .model or .display_name, preferring enabled entries.
# On /api/v2 the org model list already carries the configs; older releases
# keep them under /model-configs.
if [ -z "${MODEL_CONFIG_ID:-}" ] && [ -n "${AGENT_MODEL:-}" ]; then
  echo "==> Resolving model '$AGENT_MODEL' -> model_config_id"
  if [ "$CHAT_API" = /api/v2 ]; then
    MC="$CHAT_MODELS"
  else
    MC=$(coder_api GET "/api/experimental/chats/model-configs") || MC='{}'
  fi
  read -r MODEL_CONFIG_ID MODEL_CTX <<<"$(echo "$MC" | jq -r --arg m "$AGENT_MODEL" '
    [ .. | objects
      | select(((.id? // "") | tostring | test("^[0-9a-f]{8}-")))
      | select((.model? == $m) or (.display_name? == $m)) ]
    | (map(select(.enabled == true)) + map(select(.enabled != true)))
    | (.[0] // {}) | "\(.id // "") \(.context_limit // "")"')"
  [ -n "$MODEL_CONFIG_ID" ] \
    || die "Could not resolve model '$AGENT_MODEL' among the chat models on $CODER_URL." \
           "Use a model or display name the deployment lists, or clear the \`AGENT_MODEL\` variable to take the default."
  echo "    model_config_id=$MODEL_CONFIG_ID (context_limit=${MODEL_CTX:-?})"
fi

# --- 2. the deterministic git wrapper must exist in the repo -----------------
# The agent only edits files; this wrapper does all git, so a model that forgets
# `git add` or stops mid-thought cannot break the pipeline. It has to live in
# the repository because the workspace clones the repo, not this action.
#
# $BASE_BRANCH is commonly protected, so a bot token often can't write there
# directly (a 403 from the contents API). $BRANCH isn't protected — the agent
# already pushes to it over its own SSH key — so bootstrap lands there instead.
# It then rides into $BASE_BRANCH the normal way, as part of this issue's PR;
# once merged, later issues find it already on $BASE_BRANCH and skip this step.
FINISH_PRESENT_REF=""
if gitea_api GET "/repos/$REPO_OWNER/$REPO_NAME/contents/$FINISH_SCRIPT_PATH?ref=$BASE_BRANCH" \
     >/dev/null 2>&1; then
  FINISH_PRESENT_REF="$BASE_BRANCH"
elif gitea_api GET "/repos/$REPO_OWNER/$REPO_NAME/contents/$FINISH_SCRIPT_PATH?ref=$BRANCH" \
     >/dev/null 2>&1; then
  FINISH_PRESENT_REF="$BRANCH"
fi

echo "==> Checking for $FINISH_SCRIPT_PATH on $BASE_BRANCH / $BRANCH"
NEED_BRANCH_CHECKOUT=false
if [ -n "$FINISH_PRESENT_REF" ]; then
  echo "    present on $FINISH_PRESENT_REF"
  [ "$FINISH_PRESENT_REF" = "$BRANCH" ] && NEED_BRANCH_CHECKOUT=true
elif [ "$BOOTSTRAP_FINISH" = "true" ]; then
  echo "    missing -> committing the copy shipped with this action onto $BRANCH"
  # Layout-independent: works whether finish-issue.sh sits in scripts/ or at the
  # repo root next to action.yaml.
  SRC=""
  for c in "$ACTION_PATH/scripts/finish-issue.sh" \
           "$ACTION_PATH/finish-issue.sh" \
           "$(dirname "${BASH_SOURCE[0]}")/finish-issue.sh"; do
    [ -f "$c" ] && { SRC="$c"; break; }
  done
  [ -n "$SRC" ] || die "Bootstrap source finish-issue.sh not found under $ACTION_PATH." \
    "The action repo was checked out incompletely — check the actions/checkout step."
  echo "    source: $SRC"
  B64=$(base64 -w0 < "$SRC" 2>/dev/null || base64 < "$SRC" | tr -d '\n')
  # $BRANCH may already exist (a previous run of this same issue bootstrapped it
  # but its PR hasn't merged yet) — commit onto it directly rather than trying
  # to (re-)create it, which the contents API would reject.
  if gitea_api GET "/repos/$REPO_OWNER/$REPO_NAME/branches/$BRANCH" >/dev/null 2>&1; then
    BOOT_BODY=$(jq -n --arg c "$B64" --arg b "$BRANCH" \
        '{content:$c, branch:$b, message:"ci: add finish-issue helper for the Coder Agent action"}')
  else
    BOOT_BODY=$(jq -n --arg c "$B64" --arg base "$BASE_BRANCH" --arg nb "$BRANCH" \
        '{content:$c, branch:$base, new_branch:$nb, message:"ci: add finish-issue helper for the Coder Agent action"}')
  fi
  gitea_api POST "/repos/$REPO_OWNER/$REPO_NAME/contents/$FINISH_SCRIPT_PATH" "$BOOT_BODY" \
    >/dev/null || die "Could not commit $FINISH_SCRIPT_PATH to branch $BRANCH." \
      "The Gitea token needs write access to this repository, and \`$BRANCH\` must not be protected."
  echo "    committed to $BRANCH"
  NEED_BRANCH_CHECKOUT=true
else
  die "$FINISH_SCRIPT_PATH is missing and bootstrap-finish-script is off." \
      "Commit the finish script to the repo, or set \`bootstrap-finish-script: true\`."
fi

# --- 3. read the issue -------------------------------------------------------
echo "==> Reading issue"
[ -n "$ISSUE" ] || ISSUE=$(gitea_api GET "/repos/$REPO_OWNER/$REPO_NAME/issues/$ISSUE_NUM") \
  || die "Could not read issue #$ISSUE_NUM from Gitea." \
         "The token needs read access to $REPO_OWNER/$REPO_NAME; in Actions it arrives as \`FORGE_TOKEN\`."
ITITLE=$(echo "$ISSUE" | jq -r '.title')
IBODY=$(echo "$ISSUE"  | jq -r '.body // ""')

# gitea/refine-issue-action wraps its generated description in marker lines and
# signs it off with a "Review before implementing" footer. That description is
# a reviewed implementation plan — proposed change, scope, acceptance criteria
# — so it is split out of the body and handed to the agent as its primary
# brief, with the human-written rest of the body kept as the original request.
# The footer is addressed to a human reviewer, not to the agent, and is dropped.
# Markers are matched as whole lines, ignoring trailing whitespace and the CR
# of CRLF bodies; an unclosed begin marker runs to the end of the body.
split_section() { # in|out — print the lines inside or outside the marker pairs
  awk -v want="$1" -v b="$SECTION_BEGIN" -v e="$SECTION_END" '
    { l = $0; sub(/[ \t\r]+$/, "", l) }
    l == b { inside = 1; next }
    l == e { inside = 0; next }
    (want == "in") == (inside == 1)'
}
ISPEC=$(printf '%s\n' "$IBODY" | split_section in \
  | grep -v '^_Generated from the repository context by .*Review before implementing\._[[:space:]]*$' \
  || true)
if [ -n "${ISPEC//[[:space:]]/}" ]; then
  IBODY=$(printf '%s\n' "$IBODY" | split_section out)
  [ -n "${IBODY//[[:space:]]/}" ] || IBODY=""
  echo "    refined specification found ($(printf '%s\n' "$ISPEC" | wc -l) lines)"
else
  ISPEC=""
fi

# --- comments ----------------------------------------------------------------
# Walk every page: Gitea's default paging is 30, so a single unpaged call fed
# the agent the OLDEST 30 comments and silently dropped the newest ones — the
# exact opposite of what a long discussion needs.
echo "==> Reading comments"
COMMENTS_JSON="[]"; cpage=1
while [ "$cpage" -le "$COMMENT_MAX_PAGES" ]; do
  chunk=$(gitea_api GET \
    "/repos/$REPO_OWNER/$REPO_NAME/issues/$ISSUE_NUM/comments?page=${cpage}&limit=${COMMENT_PAGE_SIZE}" \
    2>/dev/null) || break
  n=$(printf '%s' "$chunk" | jq 'length' 2>/dev/null) || break
  [ "$n" -gt 0 ] || break
  COMMENTS_JSON=$(printf '%s\n%s\n' "$COMMENTS_JSON" "$chunk" | jq -c -s 'add')
  if [ "$n" -lt "$COMMENT_PAGE_SIZE" ]; then break; fi
  cpage=$((cpage + 1))
done

# Rendered verbatim — newlines and all. The old one-line-per-comment form
# collapsed every code block, diff and stack trace into an unreadable run-on.
# The action's own start/result/failure comments are filtered out: on a re-run
# the agent would otherwise read its predecessor's chat links as instructions.
ICOMMENTS=$(printf '%s' "$COMMENTS_JSON" | jq -r '
  [ .[]?
    | select(((.body // "") | test("^[[:space:]]*(🤖|⚠️|❌)[[:space:]]*\\*{0,2}Coder Agent")) | not)
    | select(((.body // "") | gsub("[[:space:]]"; "")) != "")
    | "@" + (.user.login // "unknown") + " wrote on "
      + ((.created_at // "") | split("T")[0]) + ":\n" + (.body // "")
  ] | join("\n\n----------\n\n")' 2>/dev/null || echo "")
echo "    $(printf '%s' "$COMMENTS_JSON" | jq 'length') comment(s) fetched"

# --- attachments -------------------------------------------------------------
# The runner holds the Gitea token and the workspace never does, so an
# attachment can only reach the agent through the prompt: text files are
# inlined verbatim, everything else is named so the agent knows it exists.
IATTACH=""
if [ "$INCLUDE_ATTACHMENTS" = "true" ]; then
  echo "==> Collecting attachments"
  # Issue-level uploads have their own endpoint (older Gitea) and are also
  # embedded in the issue object (newer Gitea); comment uploads only ever
  # arrive embedded. Both shapes are normalised into one list that remembers
  # where each file was posted.
  IASSETS=$(gitea_api GET "/repos/$REPO_OWNER/$REPO_NAME/issues/$ISSUE_NUM/assets" 2>/dev/null) \
    || IASSETS=$(printf '%s' "$ISSUE" | jq -c '.assets // []' 2>/dev/null || echo '[]')
  ALL_ASSETS=$( {
      printf '%s\n' "${IASSETS:-[]}" | jq -c '[ .[]? |
        { name: (.name // "attachment"), size: (.size // 0),
          url: (.browser_download_url // ""), origin: "the issue" } ]'
      printf '%s\n' "$COMMENTS_JSON" | jq -c '[ .[]? | . as $c | (.assets // [])[]? |
        { name: (.name // "attachment"), size: (.size // 0),
          url: (.browser_download_url // ""),
          origin: ("a comment by @" + ($c.user.login // "unknown")) } ]'
    } | jq -c -s 'add // []' 2>/dev/null ) || ALL_ASSETS='[]'

  ATT_BODIES=""; ATT_USED=0; ATT_PUSHED=0
  # One entry per file; a pushed file's note is only settled once the side
  # branch exists, so the list is rendered after the loop.
  ATT_NAMES=(); ATT_NOTES=(); ATT_URLS=(); ATT_STAGED=()
  ATT_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/coder-agent-att.XXXXXX")
  mkdir -p "$ATT_TMPDIR/stage"
  # Download up to whichever cap is bigger: inline or push.
  fetch_cap=$ATTACHMENT_MAX_BYTES
  [ "$ATTACHMENT_PUSH_MAX_BYTES" -gt "$fetch_cap" ] && fetch_cap=$ATTACHMENT_PUSH_MAX_BYTES
  idx=0
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    idx=$((idx + 1))
    aname=$(printf '%s' "$a" | jq -r '.name')
    asize=$(printf '%s' "$a" | jq -r '.size | floor? // 0')
    aurl=$(printf '%s' "$a"  | jq -r '.url')
    aorigin=$(printf '%s' "$a" | jq -r '.origin')
    # Numbered: pasted screenshots are all called image.png.
    safe=$(printf '%02d-%s' "$idx" "$(printf '%s' "$aname" | tr -c 'A-Za-z0-9._-' '_')")
    afile="$ATT_TMPDIR/$safe"
    note=""; staged=""
    if [ -z "$aurl" ]; then
      note="no download URL — not available"
    elif [ "$asize" -gt "$fetch_cap" ]; then
      note="over the $(human_size "$fetch_cap") cap — not available"
    elif ! gitea_download "$aurl" "$afile" "$fetch_cap"; then
      note="could not be downloaded — not available"
    else
      fsize=$(wc -c < "$afile" | tr -d ' ')
      why=""
      if is_binary "$afile"; then
        why="binary"
      elif [ "$fsize" -gt "$ATTACHMENT_MAX_BYTES" ]; then
        why="over the $(human_size "$ATTACHMENT_MAX_BYTES") inline cap"
      elif [ $((ATT_USED + fsize)) -gt "$ATTACHMENT_TOTAL_BYTES" ]; then
        why="the $(human_size "$ATTACHMENT_TOTAL_BYTES") total inline budget is spent"
      fi
      if [ -z "$why" ]; then
        ATT_USED=$((ATT_USED + fsize))
        note="inlined below"
        ATT_BODIES="${ATT_BODIES}
===== BEGIN ATTACHMENT ${aname} (from ${aorigin}) =====
$(cat "$afile")
===== END ATTACHMENT ${aname} =====
"
      elif [ "$fsize" -le "$ATTACHMENT_PUSH_MAX_BYTES" ]; then
        mv "$afile" "$ATT_TMPDIR/stage/$safe"
        staged="$safe"
        note="${why} — not inlined"   # settled after the push
      else
        note="${why}, and over the $(human_size "$ATTACHMENT_PUSH_MAX_BYTES") file cap — not available"
      fi
    fi
    ATT_NAMES+=("${aname} ($(human_size "$asize"), from ${aorigin})")
    ATT_NOTES+=("$note"); ATT_URLS+=("$aurl"); ATT_STAGED+=("$staged")
  done <<<"$(printf '%s' "$ALL_ASSETS" | jq -c '.[]?')"

  # --- hand the non-inlined files over via a side branch ---------------------
  # One commit through the multi-file contents API (Gitea >= 1.20), built in a
  # file because the base64 runs to megabytes. A stale branch from an earlier
  # run of this issue is dropped first so the commit starts clean.
  if [ -n "$(ls -A "$ATT_TMPDIR/stage")" ]; then
    echo "==> Pushing $(ls -A "$ATT_TMPDIR/stage" | wc -l | tr -d ' ') attachment(s) to $ATT_BRANCH"
    gitea_api DELETE "/repos/$REPO_OWNER/$REPO_NAME/branches/$ATT_BRANCH" >/dev/null 2>&1 || true
    : > "$ATT_TMPDIR/files.jsonl"
    for f in "$ATT_TMPDIR/stage"/*; do
      base64 -w0 < "$f" 2>/dev/null > "$ATT_TMPDIR/b64" || base64 < "$f" | tr -d '\n' > "$ATT_TMPDIR/b64"
      jq -nc --rawfile c "$ATT_TMPDIR/b64" --arg p "$ATT_BRANCH_SUBDIR/$(basename "$f")" \
        '{operation:"create", path:$p, content:$c}' >> "$ATT_TMPDIR/files.jsonl"
    done
    # [skip ci]: the side branch is not code, don't let push workflows run on it.
    jq -s --arg base "$BASE_BRANCH" --arg nb "$ATT_BRANCH" \
      --arg msg "chore: attachments of issue #${ISSUE_NUM} for the Coder Agent [skip ci]" \
      '{branch:$base, new_branch:$nb, message:$msg, files:.}' \
      "$ATT_TMPDIR/files.jsonl" > "$ATT_TMPDIR/body.json"
    if gitea_api POST "/repos/$REPO_OWNER/$REPO_NAME/contents" "@$ATT_TMPDIR/body.json" >/dev/null; then
      ATT_BRANCH_CREATED=true
      echo "    committed to $ATT_BRANCH (deleted again when the run ends)"
    else
      # Best effort: the agent still gets names and sizes, as before.
      echo "!! Could not push the attachments — the agent only gets their names."
      : > "$API_ERR_FILE"
    fi
  fi

  ATT_LIST=""
  for i in "${!ATT_NAMES[@]}"; do
    note="${ATT_NOTES[$i]}"
    if [ -n "${ATT_STAGED[$i]}" ]; then
      if [ "$ATT_BRANCH_CREATED" = true ]; then
        note="${note}, saved as ${WS_ATTACHMENT_DIR}/${ATT_STAGED[$i]}"
        ATT_PUSHED=$((ATT_PUSHED + 1))
      else
        note="${note}, not available"
      fi
    fi
    echo "    ${ATT_NAMES[$i]} — ${note}"
    ATT_LIST="${ATT_LIST}- ${ATT_NAMES[$i]} — ${note}${ATT_URLS[$i]:+
  ${ATT_URLS[$i]}}
"
  done
  rm -rf "$ATT_TMPDIR"; ATT_TMPDIR=""

  if [ -n "$ATT_LIST" ]; then IATTACH="${ATT_LIST}${ATT_BODIES}"; fi
fi

REPO_DIR="${WS_CHECKOUT_DIR%/}/${REPO_NAME}"
COMMIT_MSG="agent: ${ITITLE} (refs #${ISSUE_NUM})"

CHECKOUT_STEP=""
if [ "$NEED_BRANCH_CHECKOUT" = "true" ]; then
  CHECKOUT_STEP="- Before anything else, run this EXACT command once to switch onto the work
  branch — the workspace cloned ${BASE_BRANCH}, which doesn't have the
  finish-issue helper yet, but ${BRANCH} does:
    cd ${REPO_DIR} && git fetch origin ${BRANCH} && git checkout ${BRANCH}
"
fi
if [ "${ATT_PUSHED:-0}" -gt 0 ]; then
  # Extracted OUTSIDE the clone, so finish-issue.sh's `git add -A` can't pick
  # the files up; the side branch itself is deleted after the run.
  CHECKOUT_STEP="${CHECKOUT_STEP}- Before you start on the issue, run this EXACT command once to fetch the
  attachments marked \"saved as\" below into ${WS_ATTACHMENT_DIR}:
    mkdir -p ${WS_ATTACHMENT_DIR} && git -C ${REPO_DIR} fetch origin ${ATT_BRANCH} && git -C ${REPO_DIR} archive FETCH_HEAD:${ATT_BRANCH_SUBDIR} | tar -x -C ${WS_ATTACHMENT_DIR}
  Then open the files that matter — look at screenshots and images, they often
  carry the actual requirement. By default, do not copy them into the
  repository — they are reference material. Exception: if the issue asks for
  an attachment to become part of the project (e.g. \"add the image\", a logo,
  a photo for a page), copy exactly those files to the right place, following
  the project's conventions for location, file name and format.
"
fi

# --- skill -------------------------------------------------------------------
# The agent's working rules come from a skill file: a custom one from the
# consumer repo (read over the API — the runner has no checkout of it), else
# skills/default.md shipped with this action. Only the rules are replaceable;
# the pipeline steps in the prompt below stay fixed, because the branch check,
# the nudges and the PR step depend on them.
SKILL_FILE="${SKILL_FILE:-}"
SKILL_RAW=""
if [ -n "$SKILL_FILE" ]; then
  for ref in "$BASE_BRANCH" "$BRANCH"; do
    if SKILL_JSON=$(gitea_api GET "/repos/$REPO_OWNER/$REPO_NAME/contents/${SKILL_FILE#./}?ref=$ref" 2>/dev/null) \
       && [ -n "$SKILL_JSON" ]; then
      SKILL_RAW=$(printf '%s' "$SKILL_JSON" | jq -r '.content // ""' | tr -d '\n' | base64 -d 2>/dev/null || true)
      if [ -n "$SKILL_RAW" ]; then echo "==> Skill: ${SKILL_FILE} (on ${ref})"; break; fi
    fi
  done
  [ -n "$SKILL_RAW" ] || echo "!! skill-file '${SKILL_FILE}' not found on ${BASE_BRANCH} or ${BRANCH} — using the default skill."
  : > "$API_ERR_FILE"  # a missing custom skill is not the run's failure reason
fi
if [ -z "$SKILL_RAW" ]; then
  DEFAULT_SKILL="$ACTION_PATH/skills/default.md"
  [ -f "$DEFAULT_SKILL" ] || DEFAULT_SKILL="$(dirname "${BASH_SOURCE[0]}")/skills/default.md"
  [ -f "$DEFAULT_SKILL" ] || die "Default skill skills/default.md not found under $ACTION_PATH." \
    "The action repo was checked out incompletely — check the actions/checkout step."
  SKILL_RAW=$(cat "$DEFAULT_SKILL")
  echo "==> Skill: default ($DEFAULT_SKILL)"
fi

# --- issue text --------------------------------------------------------------
# With a refined specification the prompt shows the original request and the
# specification as two clearly fenced parts, and adds rules on how to work
# from the specification. Without one the body goes in as before.
SPEC_RULES=""
if [ -n "$ISPEC" ]; then
  ISSUE_TEXT="The issue carries a refined SPECIFICATION, generated from the repository by
refine-issue-agent and reviewed by a maintainer before this run. It is your
primary brief; the original issue text is the request it was derived from.

Original issue text:

${IBODY:-(none — the issue body consists only of the specification)}

=== SPECIFICATION BEGIN ===
${ISPEC}
=== SPECIFICATION END ==="
  SPEC_RULES="- Work from the SPECIFICATION. Its sections are \"Summary\", \"Context\",
  \"Proposed change\", \"Affected files\", \"Acceptance criteria\" and
  \"Assumptions and open questions\" (the headings may be translated into the
  issue's language). Read the whole specification before you start.
- \"Proposed change\" is your plan: carry it out step by step and honour every
  constraint it states (e.g. \"documentation-only\", \"do not modify …\",
  \"smallest necessary edits\").
- \"Affected files\" is the expected scope, not a hard limit: touch other files
  only when the change genuinely needs them, and say so in your summary.
- The specification was written from the file tree, READMEs, docs and
  manifests only — not from the source code — and possibly from a partial
  tree. Check every factual claim it makes (paths, counts, file names,
  commands, existing behaviour) against the actual checkout before relying on
  it. Where it is wrong, follow the repository and mention the discrepancy in
  your summary. Verify by reading files and git history; do not install
  dependencies, start servers or contact live/production hosts just to
  confirm a claim, unless the specification explicitly asks for it.
- Once you have the facts you need, stop investigating and make the change.
  Do not re-audit what you have already checked.
- \"Acceptance criteria\" is your checklist: before finishing, go through every
  item, verify it against your result and fix whatever is not met.
- \"Assumptions and open questions\" cannot be answered during this run:
  proceed on the stated assumptions, and where one proves false choose the
  most conservative option consistent with the specification. If it asks you
  to record something as a follow-up instead of fixing it, do not fix it —
  mention it in your summary.
- Precedence: a comment that explicitly corrects the specification wins over
  it; the specification wins over the original issue text where they differ.
- Anything the specification wants reported in the pull request or a
  completion note goes into the summary file described below, within its
  five-sentence limit; name any acceptance criterion left unmet in sentence 5.
"
else
  ISSUE_TEXT="$IBODY"
fi
# Strip a leading YAML frontmatter block (--- ... ---).
SKILL_TEXT=$(printf '%s\n' "$SKILL_RAW" \
  | awk 'NR == 1 && $0 == "---" { fm = 1; next } fm && $0 == "---" { fm = 0; next } !fm')
[ -n "${SKILL_TEXT//[[:space:]]/}" ] || die "The skill file is empty." \
  "Fill ${SKILL_FILE:-skills/default.md} with the agent's working rules, or clear skill-file."

read -r -d '' PROMPT <<TXT || true
You are working in a checked-out clone of ${REPO_OWNER}/${REPO_NAME} located at
${REPO_DIR}. Implement the change requested in the Gitea issue below.

ISSUE #${ISSUE_NUM}: ${ITITLE}

${ISSUE_TEXT}
${ICOMMENTS:+
Comments on the issue, oldest first:

${ICOMMENTS}
}${IATTACH:+
Attachments uploaded to the issue or its comments. Text files are reproduced
in full between the BEGIN/END markers below. Files marked "saved as" are
fetched into the workspace by an instruction further down. Files marked
"not available" cannot be opened — their URLs need a Gitea login — so work
from what the issue text says about them and say so in your summary if
something you needed was unreadable:

${IATTACH}
}
Working rules:
${SKILL_TEXT}

Instructions (these always apply, whatever the working rules say):
${CHECKOUT_STEP}${SPEC_RULES}- Before the final commit-and-push below, write EXACTLY five sentences (no more,
  no fewer) describing what you changed and how you verified it to
  ${SUMMARY_PATH} (plain Markdown, no front-matter, no headings). Sentence 1:
  the goal. Sentence 2-3: what you changed. Sentence 4: how you verified it.
  Sentence 5: any caveats / follow-ups. The action reads this file from the
  branch and pastes it into the PR description for reviewers.
- As your FINAL action, run EXACTLY this one command and no other git commands:
    bash ${REPO_DIR}/${FINISH_SCRIPT_PATH} "${BRANCH}" "${COMMIT_MSG}"
  It creates the branch, stages everything (including ${SUMMARY_PATH}), commits
  and pushes. Do not run any git commands yourself, do not chmod anything, and
  do not open a pull request.
${EXTRA_PROMPT:+
Project-specific notes:
${EXTRA_PROMPT}}
TXT

# --- 4. workspace ------------------------------------------------------------
# Coder workspace names: lowercase alphanumerics and hyphens, <= 32 chars.
WS_NAME=$(printf '%s-i%s-%s' "$WS_NAME_PREFIX" "$ISSUE_NUM" "$RUN_ID" \
          | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | cut -c1-32)
WS_NAME="${WS_NAME%%-}"

echo "==> Creating workspace '$WS_NAME' (clone $GIT_REPO_SSH)"
echo "    rich parameter sent to Coder: $GIT_REPO_PARAM=$GIT_REPO_SSH"
WS_BODY=$(jq -n --arg t "$AGENT_TEMPLATE_ID" --arg n "$WS_NAME" \
               --arg p "$GIT_REPO_PARAM" --arg u "$GIT_REPO_SSH" '
  { template_id: $t, name: $n,
    rich_parameter_values: [ { name: $p, value: $u } ] }')
WS_RESP=$(coder_api POST "/api/v2/users/me/workspaces" "$WS_BODY") \
  || die "Could not create workspace '$WS_NAME' from template '$AGENT_TEMPLATE'." \
         "A rich parameter the template requires may be missing, or \`$GIT_REPO_PARAM\` is not the name it uses for the clone URL."
WORKSPACE_ID=$(echo "$WS_RESP" | jq -r '.id')
WS_NAME=$(echo "$WS_RESP" | jq -r '.name')
WS_OWNER=$(echo "$WS_RESP" | jq -r '.owner_name // empty')
[ -z "$WS_OWNER" ] && WS_OWNER=$(coder_api GET "/api/v2/users/me" | jq -r '.username')
WORKSPACE_URL="${CODER_URL}/@${WS_OWNER}/${WS_NAME}"
echo "    workspace_id=$WORKSPACE_ID"
echo "    workspace_url=$WORKSPACE_URL"
set_output workspace-id "$WORKSPACE_ID"
set_output workspace-url "$WORKSPACE_URL"
set_output branch "$BRANCH"

echo "==> Waiting for the build to reach 'running' (timeout ${BUILD_TIMEOUT}s)"
deadline=$(( $(date +%s) + BUILD_TIMEOUT ))
while :; do
  st=$(coder_api GET "/api/v2/workspaces/$WORKSPACE_ID" | jq -r '.latest_build.status') \
    || die "Lost contact with Coder while waiting for the workspace build." "$WORKSPACE_URL"
  echo "    build status=$st"
  case "$st" in
    running) break ;;
    failed|canceled)
      die "The workspace build $st." \
          "Open the workspace and read the build log — usually a template or provisioner problem." ;;
  esac
  [ "$(date +%s)" -ge "$deadline" ] \
    && die "The workspace build did not reach 'running' within ${BUILD_TIMEOUT}s." \
           "Raise \`build-timeout\`, or check the provisioner on $CODER_URL."
  sleep 8 & wait $!
done

# --- 5. chat -----------------------------------------------------------------
echo "==> Creating chat pinned to the workspace"
CHAT_BODY=$(jq -n --arg org "$CODER_ORG_ID" --arg ws "$WORKSPACE_ID" \
  --arg text "$PROMPT" --arg mc "${MODEL_CONFIG_ID:-}" '
  { organization_id: $org, workspace_id: $ws,
    content: [ { type: "text", text: $text } ] }
  + (if $mc == "" then {} else { model_config_id: $mc } end)')
CHAT_ID=$(coder_api POST "$CHAT_API/chats" "$CHAT_BODY" | jq -r '.id') \
  || die "Could not create the chat on $CODER_URL." \
         "The workspace is up — check that the Chats API is enabled and the model is still configured."
CHAT_URL="${CODER_URL}${CODER_CHAT_PATH}${CHAT_ID}"
echo "    chat_id=$CHAT_ID"
echo "    chat_url=$CHAT_URL"
set_output chat-id "$CHAT_ID"
set_output chat-url "$CHAT_URL"
AGENT_LIVE=true

# Post the live links right away, so the run can be followed while it happens.
issue_comment "🤖 Coder Agent started on this issue.

🔗 $(link_html "$CHAT_URL" "Agent chat") · $(link_html "$WORKSPACE_URL" "Workspace")"

# Head of $BRANCH, empty when it does not exist. The branch can already be
# there before the agent starts (finish-script bootstrap, an earlier run), so
# "done" means the head MOVED, not merely that the branch exists.
branch_sha() {
  gitea_api GET "/repos/$REPO_OWNER/$REPO_NAME/branches/$BRANCH" 2>/dev/null \
    | jq -r '.commit.id // empty' 2>/dev/null || true
}
BRANCH_SHA_BEFORE=$(branch_sha)

NUDGE_TEXT="You stopped before finishing the task. The branch ${BRANCH} has not been pushed yet. \
Continue implementing the issue from where you left off — make the edits, write the summary file, \
and as your FINAL action run EXACTLY: bash ${REPO_DIR}/${FINISH_SCRIPT_PATH} \"${BRANCH}\" \"${COMMIT_MSG}\" \
Do not stop until that command has run."

echo "==> Polling chat (timeout ${POLL_TIMEOUT}s, max ${MAX_NUDGES} nudge(s)); waiting for running -> waiting"
poll_start=$(date +%s)
deadline=$(( poll_start + POLL_TIMEOUT )); seen_active=0; nudges=0; nudged_at=0; TIMED_OUT=false
while :; do
  st=$(coder_api GET "$CHAT_API/chats/$CHAT_ID" | jq -r '.status') \
    || die "Lost contact with Coder while polling the chat." "$CHAT_URL"
  elapsed=$(( $(date +%s) - poll_start ))
  printf '    [%s] chat status=%s (elapsed %dm%02ds)\n' \
    "$(date +%H:%M:%S)" "$st" $(( elapsed / 60 )) $(( elapsed % 60 ))
  case "$st" in
    pending|running|requires_action|interrupting) seen_active=1; nudged_at=0 ;;
    error) echo "Agent reported an error."; FAIL=1; break ;;
    waiting)
      # A nudged turn can start and finish between two polls; after 60s of
      # uninterrupted `waiting`, judge it by the branch anyway.
      [ "$nudged_at" -gt 0 ] && [ $(( $(date +%s) - nudged_at )) -ge 60 ] && seen_active=1
      if [ "$seen_active" -eq 1 ]; then
        sha=$(branch_sha)
        if [ -n "$sha" ] && [ "$sha" != "$BRANCH_SHA_BEFORE" ]; then
          FAIL=0; break
        fi
        if [ "$nudges" -ge "$MAX_NUDGES" ]; then
          # Leave the verdict to the branch check below, as before nudging.
          FAIL=0; break
        fi
        nudges=$((nudges + 1))
        echo "    agent went idle without pushing $BRANCH — nudge ${nudges}/${MAX_NUDGES}"
        coder_api POST "$CHAT_API/chats/$CHAT_ID/messages" \
          "$(jq -n --arg t "$NUDGE_TEXT" '{content: [{type: "text", text: $t}]}')" >/dev/null \
          || { echo "    could not post the nudge; giving up on nudging"; FAIL=0; break; }
        seen_active=0; nudged_at=$(date +%s)
      fi
      ;;
  esac
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "Agent timed out after ${POLL_TIMEOUT}s"
    FAIL=1; TIMED_OUT=true
    halt_agent "poll-timeout reached"
    break
  fi
  # Backgrounded so a cancel signal is handled now, not after the sleep.
  sleep 10 & wait $!
done
# Every other way out of the loop leaves the chat idle (waiting or error).
AGENT_LIVE=false
drop_att_branch
set_output nudges "$nudges"

# --- 6. pull request ---------------------------------------------------------
PR_URL=""
BRANCH_URL=""
if [ "${FAIL:-1}" -eq 0 ]; then
  if gitea_api GET "/repos/$REPO_OWNER/$REPO_NAME/branches/$BRANCH" >/dev/null 2>&1; then
    BRANCH_URL="${GITEA_URL}/${REPO_OWNER}/${REPO_NAME}/src/branch/${BRANCH}"

    # Populate the issue's "Branch/Tag" sidebar field (Issue.Ref) so it links
    # straight to this branch instead of showing "No Branch/Tag Specified".
    # Best effort: never fails the run.
    echo "==> Linking issue #${ISSUE_NUM} to branch ${BRANCH}"
    gitea_api PATCH "/repos/$REPO_OWNER/$REPO_NAME/issues/$ISSUE_NUM" \
      "$(jq -n --arg r "refs/heads/$BRANCH" '{ref:$r}')" >/dev/null 2>&1 || true

    PR_LINKS="🔗 $(link_html "$CHAT_URL" "Agent chat") · $(link_html "$WORKSPACE_URL" "Workspace") · $(link_html "$BRANCH_URL" "Branch")"

    # Read the agent's 5-sentence change summary back from the branch, so the
    # PR description carries it between "Coder Agent." and "Closes #N". Best
    # effort: a missing file is normal on a bootstrap commit (finish-issue.sh
    # only, no agent work yet) — fall back to a one-liner so reviewers still
    # see *something* happened and don't mistake the PR for an empty run.
    AGENT_SUMMARY=""
    if [ -n "$SUMMARY_PATH" ] \
      && SUMMARY_JSON=$(gitea_api GET "/repos/$REPO_OWNER/$REPO_NAME/contents/${SUMMARY_PATH}?ref=${BRANCH}" 2>/dev/null) \
      && [ -n "$SUMMARY_JSON" ]; then
      AGENT_SUMMARY=$(printf '%s' "$SUMMARY_JSON" \
        | jq -r '.content // ""' | tr -d '\n' \
        | base64 -d 2>/dev/null \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    fi
    [ -n "$AGENT_SUMMARY" ] || AGENT_SUMMARY="*The agent did not produce a summary file at \`${SUMMARY_PATH}\`.*"

    # The block the action pastes in place of the template marker. Same shape
    # whether we use the built-in body or a template: header, summary, ref and
    # links. Markers tried in either template type:
    #   `<!-- AI_SUMMARY -->` and `{{ AI_SUMMARY }}`.
    AGENT_BLOCK="Automated by the Coder Agent.

📝 **Summary**

${AGENT_SUMMARY}

Closes #${ISSUE_NUM}

${PR_LINKS}"

    # Probe the PR template. Mirrors finish-issue.sh: BASE_BRANCH first, then
    # BRANCH (a previous run may have bootstrapped it), then commit the copy
    # shipped with this action onto BRANCH so the consumer repo gets a
    # starter template on its first run.
    PR_TEMPLATE_RAW=""
    if [ -n "$PR_TEMPLATE_PATH" ]; then
      for ref in "$BASE_BRANCH" "$BRANCH"; do
        if PR_TEMPLATE_JSON=$(gitea_api GET \
             "/repos/$REPO_OWNER/$REPO_NAME/contents/${PR_TEMPLATE_PATH}?ref=$ref" 2>/dev/null) \
           && [ -n "$PR_TEMPLATE_JSON" ]; then
          PR_TEMPLATE_RAW=$(printf '%s' "$PR_TEMPLATE_JSON" \
            | jq -r '.content // ""' | tr -d '\n' | base64 -d 2>/dev/null)
          echo "==> Using PR template at ${PR_TEMPLATE_PATH} (on ${ref})"
          break
        fi
      done
      if [ -z "$PR_TEMPLATE_RAW" ] && [ -n "${PR_TEMPLATE_BOOTSTRAP_SRC:-}" ] \
         && [ -f "$PR_TEMPLATE_BOOTSTRAP_SRC" ]; then
        echo "==> PR template ${PR_TEMPLATE_PATH} missing -> committing the shipped copy onto $BRANCH"
        # Use the local copy directly — saves a round-trip.
        PR_TEMPLATE_RAW=$(cat "$PR_TEMPLATE_BOOTSTRAP_SRC")
        B64=$(base64 -w0 < "$PR_TEMPLATE_BOOTSTRAP_SRC" 2>/dev/null \
              || base64 < "$PR_TEMPLATE_BOOTSTRAP_SRC" | tr -d '\n')
        if gitea_api GET "/repos/$REPO_OWNER/$REPO_NAME/branches/$BRANCH" >/dev/null 2>&1; then
          BOOT_BODY=$(jq -n --arg c "$B64" --arg b "$BRANCH" \
              '{content:$c, branch:$b, message:"ci: add PR template for the Coder Agent action"}')
        else
          BOOT_BODY=$(jq -n --arg c "$B64" --arg base "$BASE_BRANCH" --arg nb "$BRANCH" \
              '{content:$c, branch:$base, new_branch:$nb, message:"ci: add PR template for the Coder Agent action"}')
        fi
        gitea_api POST "/repos/$REPO_OWNER/$REPO_NAME/contents/$PR_TEMPLATE_PATH" "$BOOT_BODY" \
          >/dev/null || die "Could not commit $PR_TEMPLATE_PATH to branch $BRANCH." \
            "The Gitea token needs write access to this repository, and \`$BRANCH\` must not be protected."
        echo "    committed to $BRANCH"
      fi
      if [ -z "$PR_TEMPLATE_RAW" ]; then
        echo "    PR template ${PR_TEMPLATE_PATH} not found on ${BASE_BRANCH} or ${BRANCH} — using built-in body"
      fi
    fi

    # Initialize before the template guard so the post-render check below
    # is safe under `set -u` even when no template was found (warning path)
    # — in that case neither variable is set inside the block.
    YAML_RENDERED=false
    PR_BODY=""
    if [ -n "$PR_TEMPLATE_RAW" ]; then
      # Two template flavours:
      #   * YAML form: parse with PyYAML and render each field the same way
      #     Gitea's web UI does (RenderToMarkdown in
      #     modules/issue/template/template.go). The body we POST is the
      #     rendered markdown, NOT the template source — otherwise Gitea
      #     stores the raw YAML and reviewers see it verbatim.
      #   * Markdown template: simple text substitution of `<!-- AI_SUMMARY -->`
      #     or `{{ AI_SUMMARY }}` — the user picks one and puts it where they
      #     want the block to land.
      #
      # The agent's block lands inside the `ai-summary` field's value for
      # YAML when the renderer is available. If it isn't (minimal container,
      # no apt/apk/pip3, the action's first-step install couldn't help), we
      # do NOT post the raw YAML template — reviewers would see the field
      # definitions verbatim. Instead we fall back to the default body, which
      # carries the agent's summary block and the standard links. Better to
      # post a clean, minimal body than raw YAML.
      #
      # Markdown templates use literal `<!-- AI_SUMMARY -->` / `{{ AI_SUMMARY }}`
      # substitution — that path is independent of python3.
      if [ "$PR_TEMPLATE_TYPE" = "yaml" ] \
         && command -v python3 >/dev/null \
         && python3 -c 'import yaml' >/dev/null 2>&1; then
        YAML_RENDERED=true
        TPL_TMP=$(mktemp "${TMPDIR:-/tmp}/pr-template.XXXXXX.yaml")
        printf '%s' "$PR_TEMPLATE_RAW" > "$TPL_TMP"
        if ! RENDERED=$(AGENT_BLOCK="$AGENT_BLOCK" python3 - "$TPL_TMP" <<'PY' 2>"$TPL_TMP.err"
import os, sys, yaml, re

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    tpl = yaml.safe_load(fh)

agent_block = os.environ["AGENT_BLOCK"]
fields      = tpl.get("body") or []

def blank_placeholder():
    return "_No response_\n"

def min_quotes(value):
    """Match Gitea: pick fence length one greater than any backtick run."""
    longest = 0
    for m in re.finditer(r"`{3,}", value):
        if len(m.group(0)) > longest:
            longest = len(m.group(0))
    return "`" * max(3, longest + 1)

def render_value(field):
    ftype = field.get("type")
    attrs = field.get("attributes") or {}
    fid   = field.get("id") or ""
    if ftype == "markdown":
        v = attrs.get("value") or ""
        return (v.rstrip() + "\n") if v else ""
    if ftype == "textarea":
        v = agent_block if fid == "ai-summary" else ""
        v = v.strip()
        if not v:
            return blank_placeholder()
        render = attrs.get("render")
        if render:
            fence = min_quotes(v)
            return "%s%s\n%s\n%s\n" % (fence, render, v, fence)
        return v + "\n"
    if ftype == "input":
        return blank_placeholder()
    if ftype == "dropdown":
        return blank_placeholder()
    if ftype == "checkboxes":
        opts = attrs.get("options") or []
        out = []
        for opt in opts:
            label = opt.get("label", "") if isinstance(opt, dict) else str(opt)
            out.append("- [ ] %s" % label)
        return "\n".join(out) + ("\n" if out else "")
    return ""

def visible_in_content(field):
    ftype = field.get("type")
    visible = field.get("visible")
    if not visible:
        # mirrors IssueFormField.VisibleInContent(): default is [form] for
        # markdown (so the value is hidden in the rendered content) and
        # [form, content] for everything else.
        return ftype != "markdown"
    return "content" in visible

def hide_label(field):
    if field.get("type") == "markdown":
        return True
    return bool((field.get("attributes") or {}).get("hide_label"))

def label_of(field):
    return (field.get("attributes") or {}).get("label") or ""

out = []
for field in fields:
    fid = field.get("id") or ""
    if not fid or not visible_in_content(field):
        continue
    label = label_of(field)
    value = render_value(field)
    if not label or hide_label(field):
        out.append(value)
    else:
        out.append("### %s\n\n%s" % (label, value))

sys.stdout.write("\n".join(out))
PY
); then
          ERR=$(cat "$TPL_TMP.err" 2>/dev/null)
          rm -f "$TPL_TMP" "$TPL_TMP.err"
          die "PR template YAML render failed." \
              "PyYAML reported: ${ERR:-no stderr}; the template at ${PR_TEMPLATE_PATH} is probably invalid."
        fi
        rm -f "$TPL_TMP" "$TPL_TMP.err"
        if [ -z "$RENDERED" ]; then
          die "PR template YAML rendered empty." \
              "The template at ${PR_TEMPLATE_PATH} has no `body` fields or they are all hidden — check `visible: [content]`."
        fi
        PR_BODY=$(jq -n --arg body "$RENDERED" --arg h "$BRANCH" \
          --arg b "$BASE_BRANCH" --arg t "$ITITLE" --arg n "$ISSUE_NUM" '
          { head: $h, base: $b, title: ("[agent] " + $t), body: $body }')
      elif [ "$PR_TEMPLATE_TYPE" = "markdown" ]; then
        # Markdown template: literal text substitution of the markers.
        FILLED="$PR_TEMPLATE_RAW"
        FILLED=${FILLED//<!-- AI_SUMMARY -->/$AGENT_BLOCK}
        FILLED=${FILLED//\{\{ AI_SUMMARY \}\}/$AGENT_BLOCK}
        PR_BODY=$(jq -n --arg body "$FILLED" --arg h "$BRANCH" \
          --arg b "$BASE_BRANCH" --arg t "$ITITLE" --arg n "$ISSUE_NUM" '
          { head: $h, base: $b, title: ("[agent] " + $t), body: $body }')
      fi
    fi

    # Warn when a YAML template was requested but the renderer is missing —
    # the PR is still going to open with a summary-only body, but the user
    # should know the rendered form they configured isn't being used.
    if [ "$YAML_RENDERED" = false ] && [ "$PR_TEMPLATE_TYPE" = "yaml" ]; then
      echo "    ⚠️  PR template is YAML but python3 + PyYAML are unavailable on this runner."
      echo "       The PR body will fall back to the summary-only template — reviewers"
      echo "       will NOT see the YAML form fields. Install python3 + PyYAML on the"
      echo "       runner image (the action's first step tries to, but a minimal container"
      echo "       without apt/apk/pip3 cannot)."
      if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        {
          echo "### ⚠️ PR template fallback"
          echo
          echo "PR template type is \`yaml\` but \`python3\` + \`PyYAML\` are unavailable on this runner."
          echo "Opened with the summary-only body instead of the rendered YAML form."
          echo
          echo "> Install \`python3\` and \`PyYAML\` on the runner image to render YAML PR templates."
        } >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
      fi
    fi

    # Fallback body: used when no template was supplied, OR when the
    # template is YAML but PyYAML is unavailable on this runner. Either
    # way we post a clean, minimal body that carries the agent's summary
    # block plus the standard chat/workspace/branch links. Posting raw
    # YAML to a PR is never the right answer.
    if [ -z "$PR_BODY" ]; then
      PR_BODY=$(jq -n --arg h "$BRANCH" --arg b "$BASE_BRANCH" \
        --arg t "$ITITLE" --arg n "$ISSUE_NUM" --arg links "$PR_LINKS" \
        --arg sum "$AGENT_SUMMARY" '
        { head: $h, base: $b, title: ("[agent] " + $t),
          body: (  "Automated by the Coder Agent.\n\n"
                 + "📝 **Summary**\n\n"
                 + $sum + "\n\n"
                 + "Closes #" + $n + "\n\n"
                 + $links) }')
    fi

    echo "==> Opening PR $BRANCH -> $BASE_BRANCH"
    if PR=$(gitea_api POST "/repos/$REPO_OWNER/$REPO_NAME/pulls" "$PR_BODY" 2>/dev/null); then
      PR_URL=$(echo "$PR" | jq -r '.html_url')
      echo "    PR: $PR_URL"
    else
      # Most common cause on a re-run: a PR for this branch is already open.
      # Refresh its body too, so a stale chat/workspace link (e.g. a stopped
      # workspace from a previous run) doesn't linger on it.
      PR_NUM=$(gitea_api GET "/repos/$REPO_OWNER/$REPO_NAME/pulls?state=open&limit=50" \
        | jq -r --arg b "$BRANCH" '[.[] | select(.head.ref == $b)][0].number // empty')
      if [ -n "$PR_NUM" ]; then
        echo "    reusing the PR that is already open (#$PR_NUM) — refreshing its links"
        PR_URL=$(gitea_api PATCH "/repos/$REPO_OWNER/$REPO_NAME/pulls/$PR_NUM" \
          "$(echo "$PR_BODY" | jq '{body}')" 2>/dev/null | jq -r '.html_url // empty')
        [ -n "$PR_URL" ] || PR_URL=$(gitea_api GET "/repos/$REPO_OWNER/$REPO_NAME/pulls/$PR_NUM" \
          | jq -r '.html_url // empty')
      else
        echo "    PR creation failed. Check Gitea."
        FAIL=1
      fi
    fi
  else
    echo "    Branch $BRANCH is not on the remote — the agent did not run"
    echo "    $FINISH_SCRIPT_PATH, or it made no changes. Check the chat."
    FAIL=1
  fi
fi
set_output pr-url "$PR_URL"
set_output branch-url "$BRANCH_URL"

if [ -n "$PR_URL" ]; then
  RESULT="success"; MSG="🤖 Coder Agent opened a PR: $PR_URL"
elif [ "${FAIL:-1}" -eq 0 ]; then
  RESULT="no-pr"; MSG="🤖 Coder Agent finished but no PR was created — branch \`$BRANCH\` may be missing."
elif [ "$TIMED_OUT" = true ]; then
  RESULT="failed"; MSG="⏱️ Coder Agent did not finish within ${POLL_TIMEOUT}s — it was stopped. Open the chat to see how far it got."
else
  RESULT="failed"; MSG="⚠️ Coder Agent did not complete. Open the chat to see what happened."
fi
set_output result "$RESULT"

echo "==> Commenting back on the issue"
RESULT_LINKS="🔗 $(link_html "$CHAT_URL" "Agent chat") · $(link_html "$WORKSPACE_URL" "Workspace")"
[ -n "$BRANCH_URL" ] && RESULT_LINKS="$RESULT_LINKS · $(link_html "$BRANCH_URL" "Branch")"
issue_comment "$MSG

$RESULT_LINKS"
REPORTED=true

# --- drop the trigger label (opt-in) -----------------------------------------
# Only on success: a failed run keeps its label, so the issue still shows it
# needs attention. Best effort — never fails the run.
if [ "$REMOVE_LABEL" = "true" ] && [ -n "$TRIGGER_LABEL" ] && [ "$RESULT" = "success" ]; then
  [ -n "$ISSUE" ] || ISSUE=$(gitea_api GET "/repos/$REPO_OWNER/$REPO_NAME/issues/$ISSUE_NUM")
  LABEL_ID=$(echo "$ISSUE" | jq -r --arg l "$TRIGGER_LABEL" \
    '[.labels[]? | select(.name == $l) | .id][0] // ""')
  if [ -n "$LABEL_ID" ]; then
    if gitea_api DELETE "/repos/$REPO_OWNER/$REPO_NAME/issues/$ISSUE_NUM/labels/$LABEL_ID" \
         >/dev/null 2>&1; then
      echo "==> Removed label '${TRIGGER_LABEL}' — re-apply it to run the agent again."
    else
      echo "!! Could not remove label '${TRIGGER_LABEL}' — leaving it in place."
    fi
  fi
fi

# --- 7. workspace lifecycle --------------------------------------------------
# Parse STOP_AFTER into seconds (-1 = leave running, 0 = stop now).
case "$STOP_AFTER" in
  ""|0|off|false|no) stop_secs=-1 ;;
  now)               stop_secs=0  ;;
  *h) stop_secs=$(( ${STOP_AFTER%h} * 3600 )) ;;
  *m) stop_secs=$(( ${STOP_AFTER%m} * 60 )) ;;
  *s) stop_secs=${STOP_AFTER%s} ;;
  *[!0-9]*) echo "!! Unrecognised STOP_AFTER='$STOP_AFTER' — leaving the workspace running."; stop_secs=-1 ;;
  *)  stop_secs=$STOP_AFTER ;;
esac

if [ "$WS_HALTED" = true ]; then
  echo "==> Workspace already stopped with the agent — skipping stop-after"
elif [ "$stop_secs" -eq 0 ] 2>/dev/null; then
  echo "==> Stopping the workspace now"
  coder_api POST "/api/v2/workspaces/$WORKSPACE_ID/builds" '{"transition":"stop"}' >/dev/null || true
elif [ "$stop_secs" -gt 0 ] 2>/dev/null; then
  DEADLINE=$(date -u -d "+${stop_secs} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
             || date -u -v "+${stop_secs}S" +%Y-%m-%dT%H:%M:%SZ)  # GNU or BSD date
  echo "==> Scheduling auto-stop at $DEADLINE (in $STOP_AFTER)"
  coder_api PUT "/api/v2/workspaces/$WORKSPACE_ID/ttl" \
    "$(jq -n --argjson ms "$(( stop_secs * 1000 ))" '{ttl_ms:$ms}')" >/dev/null 2>&1 || true
  if ! coder_api PUT "/api/v2/workspaces/$WORKSPACE_ID/extend" \
        "$(jq -n --arg d "$DEADLINE" '{deadline:$d}')" >/dev/null 2>&1; then
    echo "   (could not set the deadline — the template may have autostop disabled;"
    echo "    set a default TTL on the template, or use stop-after: now.)"
  fi
else
  echo "==> Leaving the workspace running (stop-after=$STOP_AFTER)"
fi

if [ "$RESULT" = "success" ]; then
  echo "==> Done (PR created)."
  exit 0
fi
echo "==> Done WITHOUT a pull request. Agent chat: $CHAT_URL"
if [ "$FAIL_ON_NO_PR" = "true" ]; then
  die "$MSG" "The agent chat holds the full transcript: $CHAT_URL"
fi
exit 0