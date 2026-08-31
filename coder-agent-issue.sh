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
#   3. read the issue (title + body + comments) via the Gitea API
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
WS_CHECKOUT_DIR="${WS_CHECKOUT_DIR:-/home/coder/GIT}"
GIT_REPO_PARAM="${GIT_REPO_PARAM:-git_repo_url}"
WS_NAME_PREFIX="${WS_NAME_PREFIX:-agent}"
CODER_CHAT_PATH="${CODER_CHAT_PATH:-/agents/}"
POLL_TIMEOUT="${POLL_TIMEOUT:-2400}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-900}"
STOP_AFTER="${STOP_AFTER:-1h}"
FAIL_ON_NO_PR="${FAIL_ON_NO_PR:-true}"
RUN_ID="${RUN_ID:-${GITHUB_RUN_ID:-$(date +%s)}}"
ACTION_PATH="${ACTION_PATH:-${GITHUB_ACTION_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"

# --- tiny API helpers --------------------------------------------------------
coder_api() { # method path [body]
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sSf -X "$m" "$CODER_URL$p" \
      -H "Coder-Session-Token: $CODER_SESSION_TOKEN" \
      -H "Content-Type: application/json" -d "$b"
  else
    curl -sSf -X "$m" "$CODER_URL$p" -H "Coder-Session-Token: $CODER_SESSION_TOKEN"
  fi
}
gitea_api() { # method path [body]
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sSf -X "$m" "$GITEA_URL/api/v1$p" \
      -H "Authorization: token $GITEA_TOKEN" \
      -H "Content-Type: application/json" -d "$b"
  else
    curl -sSf -X "$m" "$GITEA_URL/api/v1$p" -H "Authorization: token $GITEA_TOKEN"
  fi
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

echo "==> Repo ${REPO_OWNER}/${REPO_NAME}  issue #${ISSUE_NUM}  branch ${BRANCH}"

# --- 0. the SSH clone URL the workspace will use -----------------------------
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
    RAW=$(gitea_api GET "/repos/$REPO_OWNER/$REPO_NAME" | jq -r '.ssh_url // empty')
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
echo "==> Sanity: at least one LLM model configured?"
# The endpoint returns an object ({providers, unsupported_providers}); count the
# actual models recursively rather than the number of top-level keys.
[ "$(coder_api GET /api/experimental/chats/models \
      | jq '[.providers[]? | (.. | objects | select(has("id")))] | length')" -gt 0 ] \
  || { echo "No model configured on $CODER_URL (check the provider)."; exit 1; }

if [[ "$CODER_ORG" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}- ]]; then
  CODER_ORG_ID="$CODER_ORG"
else
  echo "==> Resolving organization '$CODER_ORG' -> UUID"
  CODER_ORG_ID=$(coder_api GET "/api/v2/organizations/$CODER_ORG" | jq -r '.id // empty')
  [ -n "$CODER_ORG_ID" ] || { echo "Unknown organization '$CODER_ORG'."; exit 1; }
fi
echo "    organization_id=$CODER_ORG_ID"

if [ -z "${AGENT_TEMPLATE_ID:-}" ]; then
  echo "==> Resolving template '$AGENT_TEMPLATE' -> UUID"
  AGENT_TEMPLATE_ID=$(coder_api GET \
    "/api/v2/organizations/$CODER_ORG_ID/templates/$AGENT_TEMPLATE" | jq -r '.id // empty')
  [ -n "$AGENT_TEMPLATE_ID" ] \
    || { echo "Could not resolve template '$AGENT_TEMPLATE' in org $CODER_ORG."; exit 1; }
fi
echo "    template_id=$AGENT_TEMPLATE_ID"

# Optional model pinning. MODEL_CONFIG_ID (UUID) wins; else AGENT_MODEL is looked
# up in /model-configs by .model or .display_name, preferring enabled entries.
if [ -z "${MODEL_CONFIG_ID:-}" ] && [ -n "${AGENT_MODEL:-}" ]; then
  echo "==> Resolving model '$AGENT_MODEL' -> model_config_id"
  MC=$(coder_api GET "/api/experimental/chats/model-configs")
  read -r MODEL_CONFIG_ID MODEL_CTX <<<"$(echo "$MC" | jq -r --arg m "$AGENT_MODEL" '
    [ .. | objects
      | select(((.id? // "") | tostring | test("^[0-9a-f]{8}-")))
      | select((.model? == $m) or (.display_name? == $m)) ]
    | (map(select(.enabled == true)) + map(select(.enabled != true)))
    | (.[0] // {}) | "\(.id // "") \(.context_limit // "")"')"
  [ -n "$MODEL_CONFIG_ID" ] \
    || { echo "Could not resolve model '$AGENT_MODEL' in /model-configs."; exit 1; }
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
  [ -n "$SRC" ] || { echo "Bootstrap source finish-issue.sh not found under $ACTION_PATH."; exit 1; }
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
    >/dev/null || { echo "Could not commit $FINISH_SCRIPT_PATH to $BRANCH — is the token allowed to write?"; exit 1; }
  echo "    committed to $BRANCH"
  NEED_BRANCH_CHECKOUT=true
else
  echo "$FINISH_SCRIPT_PATH is missing and bootstrap-finish-script is off."; exit 1
fi

# --- 3. read the issue -------------------------------------------------------
echo "==> Reading issue"
ISSUE=$(gitea_api GET "/repos/$REPO_OWNER/$REPO_NAME/issues/$ISSUE_NUM")
ITITLE=$(echo "$ISSUE" | jq -r '.title')
IBODY=$(echo "$ISSUE"  | jq -r '.body // ""')
ICOMMENTS=$(gitea_api GET "/repos/$REPO_OWNER/$REPO_NAME/issues/$ISSUE_NUM/comments" \
  | jq -r '[.[] | "- " + (.user.login) + ": " + ((.body // "") | gsub("\n";" "))] | join("\n")' \
  2>/dev/null || echo "")

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

read -r -d '' PROMPT <<TXT || true
You are working in a checked-out clone of ${REPO_OWNER}/${REPO_NAME} located at
${REPO_DIR}. Implement the change requested in the Gitea issue below.

ISSUE #${ISSUE_NUM}: ${ITITLE}

${IBODY}

Comments:
${ICOMMENTS}

Instructions:
${CHECKOUT_STEP}- Edit the files needed to resolve the issue. Keep the diff focused.
- NEVER overwrite an existing file wholesale. Read it first, then append or edit
  the relevant part only. Check whether a file exists before creating it.
- Run the project's build/tests if present.
- As your FINAL action, run EXACTLY this one command and no other git commands:
    bash ${REPO_DIR}/${FINISH_SCRIPT_PATH} "${BRANCH}" "${COMMIT_MSG}"
  It creates the branch, stages everything, commits and pushes. Do not run any
  git commands yourself, do not chmod anything, and do not open a pull request.
- Then summarise which files you changed and how you verified them.
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
WS_BODY=$(jq -n --arg t "$AGENT_TEMPLATE_ID" --arg n "$WS_NAME" \
               --arg p "$GIT_REPO_PARAM" --arg u "$GIT_REPO_SSH" '
  { template_id: $t, name: $n,
    rich_parameter_values: [ { name: $p, value: $u } ] }')
WS_RESP=$(coder_api POST "/api/v2/users/me/workspaces" "$WS_BODY")
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
  st=$(coder_api GET "/api/v2/workspaces/$WORKSPACE_ID" | jq -r '.latest_build.status')
  echo "    build status=$st"
  case "$st" in
    running) break ;;
    failed|canceled)
      issue_comment "⚠️ Coder Agent: the workspace build $st. [Workspace]($WORKSPACE_URL)"
      echo "Workspace build $st"; exit 1 ;;
  esac
  [ "$(date +%s)" -ge "$deadline" ] && { echo "Build timed out"; exit 1; }
  sleep 8
done

# --- 5. chat -----------------------------------------------------------------
echo "==> Creating chat pinned to the workspace"
CHAT_BODY=$(jq -n --arg org "$CODER_ORG_ID" --arg ws "$WORKSPACE_ID" \
  --arg text "$PROMPT" --arg mc "${MODEL_CONFIG_ID:-}" '
  { organization_id: $org, workspace_id: $ws,
    content: [ { type: "text", text: $text } ] }
  + (if $mc == "" then {} else { model_config_id: $mc } end)')
CHAT_ID=$(coder_api POST "/api/experimental/chats" "$CHAT_BODY" | jq -r '.id')
CHAT_URL="${CODER_URL}${CODER_CHAT_PATH}${CHAT_ID}"
echo "    chat_id=$CHAT_ID"
echo "    chat_url=$CHAT_URL"
set_output chat-id "$CHAT_ID"
set_output chat-url "$CHAT_URL"

# Post the live links right away, so the run can be followed while it happens.
issue_comment "🤖 Coder Agent started on this issue.

🔗 $(link_html "$CHAT_URL" "Agent chat") · $(link_html "$WORKSPACE_URL" "Workspace")"

echo "==> Polling chat (timeout ${POLL_TIMEOUT}s); waiting for running -> waiting"
deadline=$(( $(date +%s) + POLL_TIMEOUT )); seen_active=0
while :; do
  st=$(coder_api GET "/api/experimental/chats/$CHAT_ID" | jq -r '.status')
  echo "    chat status=$st"
  case "$st" in
    pending|running|requires_action) seen_active=1 ;;
    error) echo "Agent reported an error."; FAIL=1; break ;;
    waiting) [ "$seen_active" -eq 1 ] && { FAIL=0; break; } ;;
  esac
  [ "$(date +%s)" -ge "$deadline" ] && { echo "Agent timed out"; FAIL=1; break; }
  sleep 10
done

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
    PR_BODY=$(jq -n --arg h "$BRANCH" --arg b "$BASE_BRANCH" \
      --arg t "$ITITLE" --arg n "$ISSUE_NUM" --arg links "$PR_LINKS" '
      { head: $h, base: $b, title: ("[agent] " + $t),
        body: ("Automated by the Coder Agent.\n\nRefs #" + $n + "\n\n" + $links) }')

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
else
  RESULT="failed"; MSG="⚠️ Coder Agent did not complete. Open the chat to see what happened."
fi
set_output result "$RESULT"

echo "==> Commenting back on the issue"
RESULT_LINKS="🔗 $(link_html "$CHAT_URL" "Agent chat") · $(link_html "$WORKSPACE_URL" "Workspace")"
[ -n "$BRANCH_URL" ] && RESULT_LINKS="$RESULT_LINKS · $(link_html "$BRANCH_URL" "Branch")"
issue_comment "$MSG

$RESULT_LINKS"

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

if [ "$stop_secs" -eq 0 ] 2>/dev/null; then
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
[ "$FAIL_ON_NO_PR" = "true" ] && exit 1
exit 0