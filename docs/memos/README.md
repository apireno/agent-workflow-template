# docs/memos/ — the inbound gap-report channel

**This directory is an inbox, and using it is encouraged.** Any CTO home or dev team that hits
a limitation in the shared mechanism — scripts, skills, hooks, personas, `CLAUDE.devteam.md`,
settings templates — files a memo here. Committing that memo to this repo is the sanctioned
channel; it is explicitly **not** a lane violation.

The lane rule it complements is stated in `docs/personas/cto.md` → "Mechanism Is Not Yours to
Edit". The two halves are easy to confuse, so to be exact:

| | |
|---|---|
| **Welcome** | A memo here describing a gap and a proposed shape |
| **Not permitted** | A patch to a mechanism file — here or in your own CTO home |
| **Worse than either** | Working around a real gap silently and never reporting it |

Going quiet is the failure mode this inbox exists to prevent. A downstream workaround that
nobody upstream hears about means every other project keeps the same defect, and the next
person rediscovers it the expensive way.

## What a good memo contains

1. **The failure, concretely** — what you expected, what happened, what it cost. "An overnight
   run sat blocked for hours undetected" is worth more than "watchers could be better."
2. **A proposed shape, not a patch.** A flag name and its semantics; not a diff. The template
   team owns the implementation and will often build something different — usually because the
   fix has to work in repos you cannot see.
3. **Whether you worked around it**, and how. That tells us the urgency and gives us a
   behaviour to preserve.
4. **A confirmation of no downstream edits.** State plainly that you changed no mechanism
   files, or name exactly what you changed and why it was unavoidable.

## Naming and lifecycle

`YYYY-MM-DD-<short-slug>.md`, signed with the reporting persona.

Memos are **input, not decisions**. The template team evaluates each one and may adopt it,
redesign it, or reject it — the outcome comes back as a reply memo or a note in the next sync
announcement, along with what changed and when it lands. A memo staying in this directory
after it is actioned is fine; it is the record of why the mechanism looks the way it does.

## If a gap is blocking right now

File the memo, then say so in your next CEO summary. If nothing can proceed, escalate to the
CEO for a ruling. The CEO can direct the template team to prioritise it — that is the lever.
Editing the file yourself is not, however urgent it looks: if the gap is real, every other
project has it too, and only an upstream fix closes it everywhere at once.
