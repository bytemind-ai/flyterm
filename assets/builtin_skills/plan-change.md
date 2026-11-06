---
name: plan-change
description: Use when the request is ambiguous or spans several files or services — before editing.
---

# Plan a Change: clarify, design, change, verify

Every message you send is read on a phone. Keep it to a few lines — the step
list lives in `set_plan`, not in your prose.

## When this does not apply

This skill is for changing something. If the request turns out to be read-only
— "how many X are running", "what is the current Y" — do not run the phases.
Answer the question, and if the user reached it through `/plan-change`, say in
one line why the phases did not apply.

Running Clarify/Design/Change/Verify over a single `ps` produces a long reply
wrapped around a short answer. That is this skill's most common failure mode,
and it reads as padding, not as thoroughness. The phases earn their cost only
when something is about to change and the user needs to approve what.

## Phase 1 — Clarify (this phase is not optional)

The general guidance says to ask at most one question per turn and to prefer
looking things up over asking. **For this phase that is overridden**: ask as
many questions as it takes, one at a time.

What you still may NOT ask about is anything a command would tell you. Run the
command. Ask only about intent, priorities, and constraints that exist solely
in the user's head.

Use `ask_user`: one question per call, 2 to 4 options, each with a short
`description` of what choosing it means. Lead with your recommendation and say
that it is your recommendation.

You are done clarifying when you can state each of these in one sentence:

1. **Goal** — what is true afterwards that is not true now.
2. **Boundary** — what you are explicitly NOT doing.
3. **Done** — the observable check that says it worked.

If you cannot write all three, ask another question. If you can, stop asking —
questions past that point cost the user time and buy nothing.

Do NOT ask a question whose answers all lead to the same work.

## Phase 2 — Design, and get it approved

Send the step list with `set_plan`, then say in one or two sentences what you
intend to do and what it touches. Wait for the user.

- Order the steps so each one is verifiable on its own.
- Name the risky step and say what makes it risky.
- If a step could be destructive, say what you will back up first.

Do NOT start editing because the plan "is obviously right". The plan being
right is exactly what the user is confirming.

## Phase 3 — Change, one step at a time

- Do one step. Verify that step. Then take the next.
- Update `set_plan` with the new `current` as you go — that list is what the
  user is watching on a small screen.
- Back up any file before your first edit to it.
- If a step fails, stop. Do not proceed with a broken step behind you, and do
  not repair by piling on more changes — that is `troubleshoot`
  territory, load it.
- If something you learn invalidates the plan, say so and send a new
  `set_plan`. Do not silently do something other than what was approved.

Do NOT batch every edit and verify at the end. When it breaks you will not know
which step did it.

## Phase 4 — Verify against the "Done" sentence

Verify against the sentence you wrote in Phase 1, not against your memory of
what you meant to do.

- Run the observable check. Quote the line that proves it, not the whole
  output.
- Check the boundary too: confirm you did not change what you said you would
  not change.
- Report honestly. If part of it is not done, say which part and why. A partial
  result reported accurately is useful; a complete-sounding report that is
  wrong costs the user a debugging session.

## Red flags

| Thought | Reality |
|---|---|
| "This one is simple enough to skip clarifying" | Simple requests are where unstated assumptions hide. |
| "I'll ask everything in one message" | Four questions at once on a phone gets one of them answered. |
| "I'll plan as I go" | Then the user approves nothing and sees nothing. |
| "I'll verify at the end" | Then a failure in step 2 surfaces in step 7. |
| "It should work now" | "Should" means you have not run the check. |
| "The plan changed, no need to mention it" | The user approved the old one. |

## When you are done

If the approach here would apply to a whole class of future requests, call
`save_skill` to store it.
