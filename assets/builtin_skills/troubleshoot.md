---
name: troubleshoot
description: Use when something is broken or misbehaving — before any command that changes state.
---

# Systematic Troubleshooting

## The Rule

Find the cause before you change anything. A fix applied to a guessed cause is
indistinguishable from a fix that did nothing — both leave you unable to say
what was wrong.

Every message you send is read on a phone. Keep it to a few lines: quote the
evidence that decided something, not the output it came from.

## Phase 1 — Establish the symptom

You need the exact failure, not a summary of it.

- "It's down" is not a symptom. Get the error text, the exit code, or the
  observable difference from working.
- Reproduce it yourself with one command if you can.
- Note when it last worked. `systemctl status` shows the restart time; shell
  history and file mtimes show what changed near it.

Do NOT proceed on a symptom you have only been told about and have not seen.

## Phase 2 — Gather evidence in one trip

Every tool call is a phone-to-server round trip. Ask for everything this phase
needs in a single `bash` call:

    systemctl status nginx --no-pager; journalctl -u nginx -n 50 --no-pager; \
      ss -lntp | head; df -h /

Read the whole output before forming an opinion. What you are looking for is
usually in the part that looks boring.

Do NOT skip a long log because it is long. Narrow it (`-n`, `--since`, `grep`)
and read what you narrowed to.

## Phase 3 — One hypothesis, stated out loud

Write, in your message to the user: *I believe X is the cause, because Y.*

- One hypothesis. If you have three, the evidence is not sufficient yet — go
  back to Phase 2 and get what would distinguish them.
- If nothing can distinguish them, say so and pick the cheapest test.

Do NOT try three fixes at once. When it starts working you will not know which
one did it, and two of them are now unexplained changes on a live machine.

## Phase 4 — The smallest change that tests the hypothesis

- Change one thing: the one your hypothesis names.
- Back up before editing: `cp nginx.conf nginx.conf.bak.$(date +%s)`.
- Prefer a reversible test (`nginx -t`, a dry run, one request) over a restart.
  A restart destroys the evidence you would need on the next round.
- Say what you are about to change and why — that sentence is the `description`
  the user reads on a phone screen when approving it.

## Phase 5 — Verify independently

- Do NOT accept "the command exited 0" as proof. It means the command ran.
- Run a check independent of the change: request the URL, query the port, tail
  the log for the next entry.
- Quote the one line that proves it — not the whole output. "It should be
  fixed now" is not a report.
- If it is not fixed you have new evidence — return to Phase 3. Do not stack
  another change on top of the last one.

## Red flags

| Thought | Reality |
|---|---|
| "Let me just restart it and see" | Restarting destroys the state that holds the answer. |
| "The log is too long, I'll skim it" | What you are looking for is in the part you skimmed. |
| "It's probably the config" | "Probably" means you are in Phase 2, not Phase 4. |
| "I'll fix these two things together" | Then you will not know which one mattered. |
| "Exit code 0 — done" | The command ran. That is not the same as it working. |
| "The user said it's the database" | Users report symptoms, not causes. Verify it. |

## When you are done

If this took more than a few steps and the conclusion would apply again, call
`save_skill` with what you learned: the check that identified it, and the fix.
