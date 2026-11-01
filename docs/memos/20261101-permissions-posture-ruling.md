# Memo — Permissions posture: the conversation is the gate, the harness is lenient

**To:** every CTO home and dev lane · **From:** template CTO · **Date:** 2026-11-01 · **Answers:** `docs/memos/20261101-permissions-step-remote-approval.md` (a project CTO's request, CEO-forwarded)

## 1. The ruling (CEO, 2026-11-01, verbatim)

> "i dont want to have to specifically approve every merge command rather i want to say something like yes to a request to merge all the open prs across the project. so from that perspective that would be a bit of prompting but permission leniency no?"

Read with the 2026-10-30 ruling ("the approvals are done within the chat window and not by running a script manually"), the posture is:

- **The conversation is the gate.** The CEO approves an *intent* ("yes, merge all the open PRs across the project") once, in the conversation; the CTO records it (`record-approval.sh` when it is a gate) and executes the whole batch with no per-command harness prompt.
- **The harness is lenient.** The blanket `Bash` allow stays; `defaultMode: acceptEdits`. Routine shepherding — peek, send, commit, push, merge, reap, reviews, reports — runs silently.
- **The `ask` list is the never-uninvited set only:** what the CTO must not do without having asked first, where a harness prompt catches a *mistake* rather than re-asking a *decision* the CEO already made. Rewriting remote history (`git push --force*`), deleting remote branches, launchd persistence (`launchctl load/unload/bootstrap/bootout`), creating/deleting/re-scoping GitHub repos, and the CTO editing its own permission files. Lanes additionally ask on `gh pr merge` (lanes never merge; `land-lane` does, from the CTO home).
- **Auto mode is for unattended runs**, not for a session the CEO is approving things in.

## 2. Corrections to the request (Claude Code 2.1.316, docs fetched 2026-11-01)

The request's symptoms are right. Four of its mechanism claims are not, and one acceptance criterion is impossible as written.

| Claim in the request | What the docs say | Source |
|---|---|---|
| `Bash(*)` is a literal match for the command `*`, a no-op | "`Bash(*)` is equivalent to `Bash` and matches all Bash commands." In `acceptEdits` it already runs everything silently. | docs/en/permissions, "Match all uses of a tool" |
| Auto mode "never asks" because the classifier refuses | Auto mode **drops** the blanket allow on entry: "broad allow rules that grant arbitrary code execution are dropped: blanket `Bash(*)`…". Every call then goes to the classifier, and a block is a block, not a prompt ("lists the action under `/permissions` → Recently denied, press `r` to retry"). That is the whole observed failure: the session was in auto. | docs/en/permission-modes, "Eliminate permission prompts with auto mode" |
| "always" on an ask-prompted push persists as `Bash(git push *)` | Impossible by design. "Rules are evaluated in order: deny, then ask, then allow… specificity doesn't change the order", and "a matching ask rule prompts even when a more specific allow rule also matches". An ask-listed command prompts every time until the ask rule is removed. That is the right behaviour for the never-uninvited set — and the reason merges are *not* on the CTO home's ask list. | docs/en/permissions, "Permission system" |
| Shift+Tab has no bypass | Correct, with a nuance: the cycle is `default → acceptEdits → plan` (+ `auto` if enabled); `bypassPermissions` appears only when the session was launched with it. `auto` and `bypassPermissions` as `defaultMode` take effect only from `~/.claude/settings.json`, never from project or local settings. | docs/en/permission-modes, "Switch permission modes" |
| A classifier refusal has no route to a prompt | "Ask rules that match on a command's content, such as `Bash(git push *)`, fall back to a permission prompt" — **even in auto mode**. So the ask list is the remote-approval lever: an ask-listed command becomes a real prompt, Remote Control keeps it open until answered, `/config → Push when actions required` pings the phone. Anything *not* ask-listed is classifier-judged in auto with no prompt — which is why batches the CEO approved run in `acceptEdits`, not auto. | docs/en/permission-modes; docs/en/remote-control, "Limitations" |

Unexplained by today's docs: why a CTO home with a working `Bash(*)` accumulated 60+ one-off "always" rules (`Bash(echo "22141")`, `Bash(set +x)`, `Bash(launchctl load *)`…). Most likely auto mode's "3 blocks in a row → resume prompting" fallback, plus older CLI versions. Ten-second test in that home: Shift+Tab to `acceptEdits`, run `osascript -e 'return 1'`; if it runs without a prompt, auto mode was the entire problem. Those rules are harmless; `settings-posture.sh --apply` leaves `settings.local.json` alone.

Also not documented: variable expansion (`$CLAUDE_PROJECT_DIR`) inside permission rule strings. The template's comment that relied on it is corrected; the blanket allow makes it moot.

## 3. What shipped (template, this date)

1. **`.claude/settings.cto.json.template`** — `allow: Bash` (blanket), `defaultMode: acceptEdits`, the never-uninvited `ask` list, comments stating the posture. **`settings.devteam.json.template` + `settings.permissive.json`** — same shape plus `gh pr merge` for lanes. Project additions (object-store deletes, service installs) go in `<cto-home>/.cto/settings-overlay.json`, which `push-to-repos.sh` already unions into `allow/deny/ask`.
2. **`scripts/cto/settings-posture.sh --check|--apply [<home>]`** — `--check` names each gap (defaultMode, blanket Bash, missing ask rules, a rule in both ask and allow, missing preflight hook); `--apply` is a *merge* that keeps the home's MCP servers, `additionalDirectories` and its own hooks.
3. **`preflight.sh`** — runs `--check` in every CTO home at session start; reads the hook input's `permission_mode` and prints `[PERMISSIONS] mode=…`, with a warning in auto (blanket Bash dropped; a block is not a prompt; Shift+Tab to acceptEdits for CEO-approved batches).
4. **`lint-skills.sh` CHECK H** — every settings template carries the blanket Bash and the never-uninvited ask set, and no rule sits in both lists.
5. **`docs/personas/cto.md` "Permissions posture"** + `CLAUDE.md` Steps 1–2 + `CLAUDE.devteam.md` — the table above; a classifier block is answered by asking the CEO to Shift+Tab to `acceptEdits` so the prompt appears, never by a paste-me command; Remote Control is how prompts reach a remote CEO.
6. **`scripts/cto/test-settings-posture.sh`** — templates, check/apply/merge semantics, preflight's mode report.

## 3b. First live result, same day

The project CTO's first landing after apply (commit → push → PR → squash-merge → cleanup, one compound command) produced exactly one prompt, and not for the merge: for `git branch -D feat/…`, the *local* branch delete that every squash-merge landing needs (`-d` refuses after a squash). Local, reflog-recoverable, routine — misfiled in the never-uninvited set. Retired the same day via the template's `permissions._retired_ask`; `settings-posture.sh --check` names a retired rule still present and `--apply` removes it. Remote branch deletion (`git push --delete`) stays.

## 4. Acceptance

- A CTO home in `acceptEdits`: `git status`, `/peek`, `/send`, lane commits, pushes, a CEO-approved batch of merges and a worktree reap run without a prompt. `git push --force`, `launchctl load`, `gh repo create` prompt once each, every time, and the prompt is visible on a connected Remote Control device.
- In auto mode, preflight says so and names the consequence; the ask list still prompts.
- `settings-posture.sh --check` on an existing home reports exactly the missing ask list; `--apply` closes it and changes nothing else (test covers MCP grants, dirs, own hooks).
- `lint-skills.sh` fails if a template loses the blanket Bash or any never-uninvited rule.

— CTO
