---
name: skill-creator
description: Use when writing or updating a skill via save_skill — how to phrase the description, the body, and the attachments.
---

# Writing a Skill Worth Keeping

The user asked for this, so the procedure is worth keeping. Your job is to
write it so it works when it is recalled days from now, on a different
machine, by you with no memory of today.

Everything you send is read on a phone. Keep it short.

## Step 0 — Ask before you write, unless you already know

A skill is stored in an index and recalled later. A wrong one is not just
useless — it fires at the wrong moment and burns the user's tokens being
read. So do not guess what the user wants and then write it up.

**The test:** you can write this skill without asking only if the user's own
words tell you both of these:

1. **When it applies** — the situation that should trigger it.
2. **What it should do** — at least the shape of the procedure.

| What you have | What to do |
|---|---|
| Both | Write it. Do not ask. |
| Only one, or just "save this" / "remember that" | **Ask first** — see below. |
| "You decide" / "whatever you think" | Write it, then say in your reply what you assumed so they can correct you. |

### The trap: today's incident is not the skill

"Save that as a skill" almost never means "save what we just did".

What you just did was for **this** machine, **this** error, **today**. A skill
has to work on a machine you have never seen. Those two are almost never the
same thing — if you write down today's fix verbatim, the user gets a skill
that is wrong the next time it fires.

So when the user points at work in progress and says "save it", treat that as
"only one of the two things is known". Ask.

### How to ask

Use `ask_user` with concrete options — not an open question the user has to
type an answer to.

The thing worth asking about is **when this should fire**. That decides the
`description`, which is the only part that lives in every prompt forever —
and it is the one thing you genuinely cannot infer from the work you just
did.

- Good: "When should this run?" → options like `Whenever a deploy fails` /
  `Only when I ask for it` / `Let me type it`.

**Do not ask** about the body's wording, the reply format, what to name it,
or whether to save it at all. Those are already settled — the first three by
the steps below, the last by the fact that you are reading this. Asking about
them spends the user's attention on decisions you are supposed to make.

One question is usually enough. Two is the limit before this becomes an
interrogation.

## Step 1 — Write the description for the moment of recall

The `description` is the only part that stays in every prompt. It is not a
summary of the skill — it is the **trigger condition**.

- Write WHEN, not WHAT. "Use when a deploy fails after the upload step" beats
  "How to debug failed deploys".
- Name the observable situation the user will be in: an error text, a task
  they are about to start, a state they will describe.
- Under 200 bytes. It rides along in every request forever.

Test: read only the description. Can you say whether it applies to a request
you have not seen yet? If not, rewrite it.

One case worth knowing: if the procedure only makes sense on one particular
machine, it is not a skill — that is what `save_note` is for. A quirk of one
box will never be recalled for another.

## Step 2 — Write the body as steps, not as a report

- **Imperative steps in order.** Each one should be verifiable on its own.
- **Put the work in the commands.** A skill whose steps are shell commands
  returns finished numbers; a skill that tells you to gather raw values and
  combine them in your head burns tokens and gets the arithmetic wrong.
- **Do not prescribe the reply format.** A body that says "report X, then Y,
  then Z" produces that padding on every future call. Describe what to find,
  not what to write.
- **State the failure modes.** A step that says "if this prints nothing, the
  unit is masked — check `systemctl is-enabled` first" is worth more than
  three happy-path steps.
- **Say what NOT to do.** The times you were burned are the times worth
  recording.

Do not paste a whole script into the body if it will be identical next time —
attach it (Step 3).

## Step 3 — Attach files that would be identical next time

If the procedure includes a script, a config template, or a fixed query that
you would write the same way on every run, attach it via the `assets` argument
of `save_skill` instead of inlining it:

- The body is capped at 8 KiB and you rewrite it on every save. An attached
  file is stored once and written to the server as-is.
- Mark it `executable: true` only if it is meant to be run — those get
  `chmod +x` on install.
- Paths are relative (`scripts/check.sh`), with no leading `/` and no `..`.
  They land inside the skill's own folder on the server.
- The body must say which file to run and when. An attachment nothing
  references is dead weight.

Only attach what the body actually tells you to run. A skill that ships a
dozen unused templates is a skill nobody can review before approving it.

## Step 4 — Check it before saving

- Would each step still make sense on a machine you have never logged into?
- Does every command in it print something a reader can act on?
- Did you remove the parts that were specific to today's incident?
- Is the description a trigger, not a summary?

## Red flags

| Thought | Reality |
|---|---|
| "The user said save it, so the requirements are clear" | "Save it" tells you nothing about when it should fire. Ask, or write a skill that misfires. |
| "I'll write down exactly what we just did" | What we just did was for this machine, today. The next fire will be neither. |
| "Asking makes me look like I wasn't paying attention" | One question about the trigger is cheaper than a skill that fires at the wrong moment forever. |
| "I'll ask about everything to be safe" | Then it is an interrogation. One question, two at most. |
| "I'll describe what the output should look like" | Then every future call produces that shape whether or not it helps. |
| "I'll include the values I used today" | Those belong in the body as variables to substitute, not as fixed values. |
| "Bigger skill = more useful" | The body is loaded whole. A long one is skimmed, not followed. |
| "I'll attach the whole repo's config" | The user approves each file. Attach what the steps need. |
| "The description can be vague, the body explains it" | The body is only read after the description made you load it. |
| "This only applies to this one box" | Then it is a note, not a skill — use `save_note`. |

## When you are done

Tell the user what you stored in one line, and that they can review or turn it
off in Settings → AI → Skills. Do not paste the skill back to them.

If you had to assume something (Step 0), say so here — that is the only
chance the user gets to correct it before it starts firing.
