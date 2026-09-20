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
# Path the agent writes its 5-sentence change summary to. The action reads this
# from the branch after the agent pushes and pastes it into the PR body
# between "Automated by the Coder Agent." and "Refs #N". Empty = skip.
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
# only used to strip the scaffolding out of the prompt.
SECTION_BEGIN="${SECTION_BEGIN:-<!-- agent:begin -->}"
SECTION_END="${SECTION_END:-<!-- agent:end -->}"
GIT_REPO_PARAM="${GIT_REPO_PARAM:-git_repo_url}"
WS_NAME_PREFIX="${WS_NAME_PREFIX:-agent}"
CODER_CHAT_PATH="${CODER_CHAT_PATH:-/agents/}"
POLL_TIMEOUT="${POLL_TIMEOUT:-2400}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-900}"
STOP_AFTER="${STOP_AFTER:-1h}"
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
    resp=$(curl -sS -w $'\n%{http_code}' -X "$m" "$base$p" \
      -H "$auth" -H "Content-Type: application/json" -d "$b" 2>&1) || resp=$'\n000'
  else
    resp=$(curl -sS -w $'\n%{http_code}' -X "$m" "$base$p" -H "$auth" 2>&1) || resp=$'\n000'
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
API_ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/coder-agent-api-err.XXXXXX")

die() { # reason [hint]
  FAIL_REASON="$1"; FAIL_HINT="${2:-}"
  printf '%s\n' "$FAIL_REASON" >&2
  [ -n "$FAIL_HINT" ] && printf '%s\n' "$FAIL_HINT" >&2
  exit 1
}

on_exit() {
  local code=$? reason="" links=""
  LAST_API_ERROR=$(cat "$API_ERR_FILE" 2>/dev/null || true)
  rm -f "$API_ERR_FILE"
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

echo "==> Sanity: at least one LLM model configured?"
# The endpoint returns an object ({providers, unsupported_providers}); count the
# actual models recursively rather than the number of top-level keys.
MODEL_COUNT=$(coder_api GET /api/experimental/chats/models \
  | jq '[.providers[]? | (.. | objects | select(has("id")))] | length') || exit 1
[ "${MODEL_COUNT:-0}" -gt 0 ] \
  || die "No LLM model is configured on $CODER_URL." \
         "Add a provider and model to the Coder deployment, then re-run."

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
# up in /model-configs by .model or .display_name, preferring enabled entries.
if [ -z "${MODEL_CONFIG_ID:-}" ] && [ -n "${AGENT_MODEL:-}" ]; then
  echo "==> Resolving model '$AGENT_MODEL' -> model_config_id"
  MC=$(coder_api GET "/api/experimental/chats/model-configs") || MC='{}'
  read -r MODEL_CONFIG_ID MODEL_CTX <<<"$(echo "$MC" | jq -r --arg m "$AGENT_MODEL" '
    [ .. | objects
      | select(((.id? // "") | tostring | test("^[0-9a-f]{8}-")))
      | select((.model? == $m) or (.display_name? == $m)) ]
    | (map(select(.enabled == true)) + map(select(.enabled != true)))
    | (.[0] // {}) | "\(.id // "") \(.context_limit // "")"')"
  [ -n "$MODEL_CONFIG_ID" ] \
    || die "Could not resolve model '$AGENT_MODEL' in /model-configs." \
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
# signs it off with a "Review before implementing" footer. The description
# itself is exactly what the agent should read, so keep it — but drop the
# scaffolding, which is addressed to a human reviewer, not to the agent.
IBODY=$(printf '%s\n' "$IBODY" \
  | grep -vxF -e "$SECTION_BEGIN" -e "$SECTION_END" \
  | grep -v '^_Generated from the repository context by .*Review before implementing\._$' \
  || true)
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
- Before the final commit-and-push below, write EXACTLY five sentences (no more,
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
  sleep 8
done

# --- 5. chat -----------------------------------------------------------------
echo "==> Creating chat pinned to the workspace"
CHAT_BODY=$(jq -n --arg org "$CODER_ORG_ID" --arg ws "$WORKSPACE_ID" \
  --arg text "$PROMPT" --arg mc "${MODEL_CONFIG_ID:-}" '
  { organization_id: $org, workspace_id: $ws,
    content: [ { type: "text", text: $text } ] }
  + (if $mc == "" then {} else { model_config_id: $mc } end)')
CHAT_ID=$(coder_api POST "/api/experimental/chats" "$CHAT_BODY" | jq -r '.id') \
  || die "Could not create the chat on $CODER_URL." \
         "The workspace is up — check that the Chats API is enabled and the model is still configured."
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
  st=$(coder_api GET "/api/experimental/chats/$CHAT_ID" | jq -r '.status') \
    || die "Lost contact with Coder while polling the chat." "$CHAT_URL"
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

    # Read the agent's 5-sentence change summary back from the branch, so the
    # PR description carries it between "Coder Agent." and "Refs #N". Best
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

Refs #${ISSUE_NUM}

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
                 + "Refs #" + $n + "\n\n"
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
if [ "$FAIL_ON_NO_PR" = "true" ]; then
  die "$MSG" "The agent chat holds the full transcript: $CHAT_URL"
fi
exit 0