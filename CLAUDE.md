# Instructions for Claude sessions working on PlayerCounter

## Start of every session

1. Read `HANDOFF.md` (current state, decisions, open items) before changing anything.
2. Read the last entry of `docs/SESSION_LOG.md` to see where the previous session stopped.
3. Check open PRs / branches: `gh api repos/leshii413/PlayerCounter/pulls --jq '.[] | "#\(.number) \(.head.ref) \(.title)"'`.

## Every time you push (non-negotiable)

Before **every** `git push`, in the **same commit** as your change (or an extra commit in the same push):

1. **`docs/SESSION_LOG.md`**: append to the current session's entry (create a new `## Session N: <date>` entry if this is a new session) with:
   - every owner prompt since the last push, **verbatim**, with local time (Asia/Singapore);
   - what was decided and why (reference decision numbers);
   - what was done, tested and pushed.
   Never rewrite or delete earlier entries; the log is append-only.
2. **`HANDOFF.md`**: bring it up to date so a new session could take over from it alone:
   - "Last updated" line and the state table (branches, PRs, versions, tested or not);
   - file map, architecture and data formats if they changed;
   - add new decisions as new `D<n>` rows (don't renumber old ones; mark reversed ones "superseded by D<n>");
   - open items: add new ones, remove finished ones.
3. **Mirror to the claude.ai Project** (when the Projects tool is available): `project_write` the full contents of `HANDOFF.md` to `PlayerCounter/HANDOFF.md` and `docs/SESSION_LOG.md` to `PlayerCounter/SESSION_LOG.md`.
4. Re-run the tests (see HANDOFF.md §7) and record the result in the log.

A push without these updates is incomplete; fix it with a follow-up commit straight away.

## What never goes in these files or the repo

The repo is public. Never commit API keys, webhook URLs, panel URLs with credentials, `discord_status.json`, player data from real servers (`stats.json`, `joins.csv`, `live.json`), or the owner's personal email address. Refer to secrets by name only ("the Pterodactyl client API key").

## Working rules

- Work on a branch and open a PR; don't push straight to `main` unless the owner says so.
- `gh pr create` uses GraphQL, which is blocked in Claude Code cloud sessions: use `gh api repos/leshii413/PlayerCounter/pulls -f base=main -f head=<branch> -f title=... -F body=@file`.
- Commit author: `Claude <noreply@anthropic.com>`, with `Co-Authored-By:` and `Claude-Session:` trailers.
- The plugin is Lua 5.3 (BeamMP-Server); keep data files under `data/`; handler functions must be globals named `PlayerCounter_*`.
- Keep `stats.json` backward compatible (add fields, don't rename) and `joins.csv` columns unchanged unless the owner agrees.
