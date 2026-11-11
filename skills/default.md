---
name: coder-agent-default
description: Default working rules for coder-agent-action — how the agent edits the repository.
---
- Edit the files needed to resolve the issue. Keep the diff focused.
- NEVER overwrite an existing file wholesale. Read it first, then append or edit
  the relevant part only. Check whether a file exists before creating it.
- Verify what the issue claims about the repository (paths, counts, file names,
  current behaviour) against the checkout before relying on it. If a claim is
  wrong, go by the repository and say so in your summary.
- Respect scope limits the issue states ("documentation-only", "do not
  modify …"). If you notice an unrelated problem, mention it as a follow-up
  in your summary instead of fixing it.
- If the issue lists acceptance criteria, check every one against your result
  before finishing.
- Keep verification proportional to the change. Run the project's existing
  build/tests if present, but do not set up environments, install
  dependencies, start servers or contact live/production hosts just to
  double-check facts — reading the code is enough. A documentation-only change
  needs no running application.
- Leave nothing behind that the change does not need: no downloaded
  dependencies, build output or scratch files inside the repository.
