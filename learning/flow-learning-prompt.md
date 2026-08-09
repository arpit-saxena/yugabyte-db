# The flow-learning prompt

There isn't one to copy any more. It's a skill:
[`.claude/skills/learn-flow/SKILL.md`](../.claude/skills/learn-flow/SKILL.md).

From a session with this repo checked out:

| Command | What it does |
|---|---|
| `/learn-flow` | Lists the flows from [`flows.md`](flows.md) and asks which one |
| `/learn-flow 5` | Teaches flow 5 |
| `/learn-flow mvcc` | Same, resolved by name |
| `/learn-flow resume mvcc` | Picks up from `notes/<slug>.md` where you left off |
| `/learn-flow deeper mvcc hop 4` | Re-runs one hop as its own 5-9 sub-hops |
| `/learn-flow why does X happen before Y?` | One grounded, cited answer — no protocol |

The skill pulls the `FLOW:` / `SCOPE:` blocks out of `flows.md` itself, so there are no
slots to fill in by hand.

Tune the session by editing [`learner-profile.md`](learner-profile.md) (who you are) or
`SKILL.md` (the protocol: citation discipline, quoting budget, one hop per message,
predict-then-check, the notes template).
