# coder-agent-action

A Gitea composite action that runs a **Coder Agent** (experimental Chats API)
against an issue and opens a pull request. It replaces `coder-create-task-action`,
which used the older Tasks API and a template *preset* instead of a model.

Gitea Actions' cross-repo `uses: <url>/coder-agent-action.git@main` only works
when the runner's automatic per-job token can read that repo — fine if the
action lives in the same repo or a public one, but the per-job token is
scoped to the *current* repo only. If the action lives elsewhere (its own
repo, a different org), fetch it explicitly instead — see the workflow file
below.

## Repo layout

```
action.yaml               # inputs/outputs, thin composite wrapper
coder-agent-issue.sh      # all the logic, env-driven, runnable by hand
finish-issue.sh           # the in-repo git wrapper, bootstrapped on demand
coder-agent.yaml          # the consumer workflow, one job per label
```

## Setup

### 1. Secrets & variables

Set these on the repo (or org, so every consumer repo inherits them) that
will **run** the workflow — not on the action's own repo.

| name | kind | notes |
|---|---|---|
| `CODER_TOKEN` | secret | Coder service-account session token (`Coder-Session-Token` header) |
| `GITEA_TOKEN` | *(automatic)* | Gitea provides this per job — nothing to create, but it's scoped to the current repo only |
| `ACTION_CLONE_TOKEN` | secret, optional | Fallback PAT (scope `read:repository`) used only if `GITEA_TOKEN` can't read the action's repo — e.g. the action lives in a different repo or org. Set it at the **org** level so it's a one-time thing |
| `CODER_URL` | var | Base URL of the Coder deployment, e.g. `https://coder.example.com` |
| `CODER_ORG_ID` | var | Coder organization name or UUID |
| `AGENT_TEMPLATE` | var | Coder template name to build the workspace from, e.g. `dockerUbuntuPython-agent`. Set it at the **org** level and override per repo where a project needs a different image |
| `AGENT_MODEL` | var, optional | Model name to pin (resolved via `/model-configs`); empty = deployment default |

For a second label wired to a second template, copy the job in the workflow
below and give it its own variable, e.g. `AGENT_TEMPLATE_CLAUDE` — same idea,
one variable per job.

### 2. The workflow file

Save `coder-agent.yaml` from this repo as `.gitea/workflows/coder-agent.yaml`
in the consumer repo, then create a label named **`coder-agent`** in
*Issues → Labels*. Point `repository:` at wherever this action's repo actually
lives, and the `actions/checkout` URL at your instance.

```yaml
name: Coder Agent on Issue
# .gitea/workflows/coder-agent.yaml — drop this into any repo that should get
# an agent when an issue is labelled.
#
# run-name overrides the run title so it shows the ISSUE instead of main's
# latest commit message. (If your Gitea version ignores run-name — see
# go-gitea/gitea#34247 — the commit message will still show; that's the bug,
# not this config.)
#
# The action repo is fetched with actions/checkout, not `uses:` — see above.
#
# Token: the automatic per-job token is minted for THIS repository and will be
# refused on the action repo, so ACTION_CLONE_TOKEN carries the fetch and the
# job token is only a fallback for the day the action repo goes public.
#
# ACTION_CLONE_TOKEN:
#   a PAT with read:repository scope, from an account that can see the action
#   repo. Set it ONCE on the org so every repo inherits it.
#   Gitea rejects secret names starting with GITEA_ or GITHUB_.

run-name: "Coder Agent · issue #${{ gitea.event.issue.number }} — ${{ gitea.event.issue.title }}"

on:
  issues:
    types: [labeled]

permissions:
  contents: write
  issues: write
  pull-requests: write

jobs:
  # One job per label: to wire a second label to another template or model,
  # copy this job, change the label in `if:` and point AGENT_TEMPLATE at its
  # own variable (e.g. vars.AGENT_TEMPLATE_CLAUDE).
  agent:
    runs-on: ubuntu-24.04
    # Gitea maps `labeled` to action `label_updated`; the added label's name is
    # in changes.added_labels[0] (empty on unrelated events, so they skip).
    if: ${{ gitea.event.action == 'label_updated' && gitea.event.changes.added_labels[0].name == 'coder-agent' }}
    steps:
      - name: Fetch the action
        # Absolute URL on purpose: it pins the fetch to your own mirror of
        # actions/checkout (pull-mirrored from GitHub) regardless of the
        # instance's [actions] DEFAULT_ACTIONS_URL. A bare `actions/checkout@v4`
        # resolves to github.com unless that is set to `self` — an internet call
        # you may not want.
        uses: https://gitea.example.com/actions/checkout@v4
        with:
          repository: gitea/coder-agent-action
          ref: main
          # PAT first; the per-job token only works if the repo becomes public.
          token: ${{ secrets.ACTION_CLONE_TOKEN || secrets.GITEA_TOKEN }}
          path: .action
          # Don't leave the PAT in .action/.git/config for the agent to find.
          persist-credentials: false
          # Only if the runner's GITHUB_SERVER_URL is wrong (e.g. Gitea behind
          # a subpath — go-gitea/gitea#33629):
          # github-server-url: https://gitea.example.com

      - name: Run Coder Agent on this issue
        env:
          CODER_URL:           ${{ vars.CODER_URL }}
          CODER_SESSION_TOKEN: ${{ secrets.CODER_TOKEN }}
          CODER_ORG:           ${{ vars.CODER_ORG_ID }}
          # Template name comes from the repo (or org) variable, so switching
          # templates is a settings change, not a commit.
          AGENT_TEMPLATE:      ${{ vars.AGENT_TEMPLATE }}
          # Optional: pin a model by name (empty = deployment default).
          AGENT_MODEL:         ${{ vars.AGENT_MODEL }}
          FORGE_TOKEN:         ${{ secrets.GITEA_TOKEN }}   # automatic per-job token
          STOP_AFTER:          "1h"    # keep the workspace for debugging
          # The clone URL comes from the repo's own ssh_url. Only set these if
          # the clone inside the workspace fails — the log prints the URL it
          # used just before creating the workspace:
          # GITEA_SSH_HOST:    git-ssh.example.com
          # GITEA_SSH_PORT:    "2222"
        # Flat layout: the script sits at the root of the action repo. curl and
        # jq come from the composite wrapper we skipped, so check them here.
        run: |
          set -euo pipefail
          need=""
          command -v curl >/dev/null || need="$need curl"
          command -v jq   >/dev/null || need="$need jq"
          [ -z "$need" ] || { apt-get update -qq && apt-get install -y -qq $need; }
          bash "$GITHUB_WORKSPACE/.action/coder-agent-issue.sh"
```

**Action repo public**, or in the same repo/org the per-job token can read? Then
drop both steps and let Gitea resolve the action itself — inputs instead of env
vars, and no PAT:

```yaml
      - name: Coder Agent
        uses: <your-gitea-url>/<owner>/coder-agent-action.git@main
        with:
          coder-url:           ${{ vars.CODER_URL }}
          coder-token:         ${{ secrets.CODER_TOKEN }}
          coder-organization:  ${{ vars.CODER_ORG_ID }}
          coder-template-name: ${{ vars.AGENT_TEMPLATE }}
          coder-model:         ${{ vars.AGENT_MODEL }}
          gitea-token:         ${{ secrets.GITEA_TOKEN }}
          stop-after:          "1h"
```

## What it does

1. Resolves organization / template / model **names** to UUIDs (the old action
   needed a UUID for the org; names are friendlier and survive re-creation).
2. Works out the SSH clone URL from the repository's own `ssh_url` (Gitea puts
   it in the event payload), so no host or port has to be configured per repo.
3. Makes sure `.gitea/scripts/finish-issue.sh` exists on the base branch or the
   issue branch — committing the shipped copy to the issue branch if it's on
   neither. See *Bootstrap* below.
4. Reads the issue title, body and comments.
5. Creates a workspace from the template, passing the SSH clone URL as the
   `git_repo_url` rich parameter so the repo is there before the agent starts.
6. Creates a chat pinned to that workspace and posts the chat + workspace links
   on the issue immediately (opening in a new tab), so you can watch it work.
7. Polls until `running -> waiting`, then opens `ai/issue-N -> main`, links the
   issue's Branch/Tag sidebar field to that branch, and comments the result.
   Re-labelling an issue whose PR is already open refreshes that PR's body
   with the current run's links instead of leaving stale ones.
8. Applies `stop-after` (auto-stop deadline, stop now, or leave running).

The Gitea token never leaves the runner. The workspace only pushes over the SSH
key the template already has.

## Bootstrap of `finish-issue.sh`

The agent is told to edit files and then run exactly one command:

```
bash /home/coder/GIT/<repo>/.gitea/scripts/finish-issue.sh <branch> <message>
```

That wrapper does branch/add/commit/push deterministically, so a model that
forgets `git add` or stops mid-thought can't half-break the pipeline. It has to
live **in the repository**, because the workspace clones the repo — it never
sees this action's files.

To keep onboarding a new repo to one line of YAML, the action checks both the
base branch and the issue branch for the file and, if it's on neither, commits
its own copy via the Gitea contents API (`ci: add finish-issue helper…`) —
**onto the issue branch, not the base branch**. Base branches are commonly
protected, and a bot token usually can't write there directly (a `403` from
the contents API); the issue branch isn't protected — the agent already
pushes to it over its own SSH key — so bootstrap lands there instead. It then
rides into the base branch the normal way, as part of this issue's PR; once
that merges, later issues find the file already on the base branch and skip
this step. (When bootstrap does land on the issue branch, the workspace still
clones the base branch by default, so the agent's first instructed action is a
`git fetch && git checkout` onto the issue branch before anything else.)

Set `bootstrap-finish-script: false` to make a missing file a hard error
instead — the action will then never write to the repository on its own.

## Inputs

| input | default | notes |
|---|---|---|
| `coder-url` | — | required |
| `coder-token` | — | required, service-account session token |
| `coder-organization` | `coder` | name or UUID |
| `coder-template-name` | — | template name, normally `${{ vars.AGENT_TEMPLATE }}`; or a UUID via `coder-template-id` |
| `coder-model` | *(empty)* | model name, resolved via `/model-configs`; empty = deployment default. `coder-model-config-id` takes a UUID directly |
| `gitea-token` | — | required; `secrets.GITEA_TOKEN` works |
| `gitea-url` | current server | |
| `gitea-ssh-host` / `gitea-ssh-port` | the repo's own `ssh_url` | only set when the host Gitea advertises isn't reachable from the workspace |
| `repo-owner` / `repo-name` / `issue-number` | from the event | override to drive another repo's issue |
| `base-branch` | `main` | |
| `branch-prefix` | `ai/issue-` | branch is `<prefix><issue-number>` |
| `extra-prompt` | *(empty)* | appended as "Project-specific notes" |
| `workspace-checkout-dir` | `/home/coder/GIT` | must match the template |
| `git-repo-parameter` | `git_repo_url` | rich parameter name |
| `finish-script-path` | `.gitea/scripts/finish-issue.sh` | |
| `bootstrap-finish-script` | `true` | |
| `comment-on-issue` | `true` | |
| `stop-after` | `1h` | `1h` / `30m` / `90s` / `3600` / `now` / `off` |
| `poll-timeout` / `build-timeout` | `2400` / `900` | seconds |
| `fail-on-no-pr` | `true` | red job when no PR came out |

## Outputs

`chat-id`, `chat-url`, `workspace-id`, `workspace-url`, `branch`, `branch-url`,
`pr-url`, `result` (`success` | `no-pr` | `failed`).

## Migrating from `coder-create-task-action`

| old | new |
|---|---|
| `coder-token` | `coder-token` |
| `coder-organization` | `coder-organization` (unchanged, still accepts the name) |
| `coder-template-name` | `coder-template-name` |
| `coder-template-preset` | `coder-model` — the Chats API pins a model, not a preset |
| `coder-task-prompt` | built from the issue; use `extra-prompt` for additions |
| `coder-task-name-prefix` | `workspace-name-prefix` (the run id and issue number are appended) |
| `github-token` / `G_TOKEN` | `gitea-token` — `secrets.GITEA_TOKEN` is enough |
| `github-issue-url` | not needed, taken from the event |
| `coder-username` | not needed; the workspace is owned by the service account |
| `comment-on-issue` | `comment-on-issue` |

## Running it by hand

Everything is env-driven, so the same script works from a shell on the Gitea
server — handy for debugging a template change:

```bash
export CODER_URL=https://coder.example.com CODER_SESSION_TOKEN=... \
       CODER_ORG=coder AGENT_TEMPLATE=dockerUbuntuPython-agent \
       GITEA_URL=https://gitea.example.com GITEA_TOKEN=... \
       REPO_OWNER=GITEA REPO_NAME=someproject ISSUE_NUM=42
bash coder-agent-issue.sh
```

## Known rough edges

- `run-name` showing the commit message instead of the issue is
  [go-gitea/gitea#34247](https://github.com/go-gitea/gitea/issues/34247), not a
  config problem.
- The Chats API is under `/api/experimental/` and can change between Coder
  releases; the sanity check at the top fails fast if `/chats/models` moves.
- `ssh_url` comes from `SSH_DOMAIN` / `SSH_PORT` in Gitea's `app.ini`. If those
  are wrong, or the name only resolves on the runner's network and not in the
  Coder workspace, set `gitea-ssh-host` / `gitea-ssh-port` — that is the only
  reason those inputs exist.
- Re-labelling an issue re-runs the agent: the branch is rebuilt from the base
  and force-pushed (with lease), and an already-open PR is reused rather than
  failing the job.
- The issue's Branch/Tag sidebar link uses Gitea's `Issue.Ref` field
  (`PATCH .../issues/{n}` with `{"ref": "refs/heads/<branch>"}`) — the same
  field the branch-selector dropdown in the issue sidebar sets. It's a
  long-standing Gitea feature but a lightweight one; some Gitea versions may
  eventually replace it with a GitHub-style "development" sidebar
  ([go-gitea/gitea#31899](https://github.com/go-gitea/gitea/issues/31899)).
  Setting it is best-effort and never fails the run.
- The `target="_blank"` links rely on Gitea's Markdown sanitizer passing
  through raw `<a target="_blank">` HTML (confirmed on stock Gitea; a locked-down
  sanitizer policy could theoretically strip the attribute — check one comment
  on your instance after upgrading this action).
