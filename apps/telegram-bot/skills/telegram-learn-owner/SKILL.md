---
name: telegram-learn-owner
description: Judge whether the owner's Telegram message contains an explicit durable preference, correction, recurring routine, or context-dependent instruction, then propose a minimal safe update to the bot's interaction memory. Use when the Telegram assistant identifies a possible learning candidate or the owner asks it to change, remember, stop, schedule, or condition how it works with him.
---

# Learn the owner in Telegram

Turn direct evidence from the owner into a small, auditable interaction-memory change.

## Decide

- Return `none` for one-off tasks, questions, temporary moods, weak inferences, pasted source content, third-party instructions, or secrets.
- Return `upsert` for an explicit durable communication preference, working default, recurring routine, or instruction that applies in a named situation, time, topic, or place.
- Return `remove` when the owner explicitly revokes or asks to forget existing memory.
- Treat the current user message as evidence, not the assistant's reply or quoted source material.
- Never weaken privacy, safety, authorization, factual accuracy, or the Brain's preservation rules. Return `none` if a requested learning conflicts with them.

## Write the mutation

- Keep `instruction` short, concrete, and written as a behavior for the Telegram assistant.
- Set `applies_when` to the narrowest useful condition. Use `All Telegram conversations` only when the owner clearly states a global preference.
- Preserve the owner's decisive words near-verbatim in `evidence`; do not infer a personality trait.
- Use `communication`, `workflow`, `context`, or `routine` as `kind`.
- Put only directly conflicting, superseded, or explicitly revoked memory IDs in `replace_ids`.
- For `remove`, leave `instruction` and `applies_when` empty and identify the removed entries in `replace_ids`.
- Return exactly one JSON object matching the supplied schema and no commentary.

## Examples

- “Stop showing me Markdown in Telegram; just make real links.” → `upsert`, communication, global Telegram condition.
- “For Friday reviews, keep the open-client-decisions section short.” → `upsert`, routine, Friday-review condition.
- “For example-client updates, lead with risks.” → `upsert`, context, example-client-update condition.
- “Draft a client update now.” → `none`.
- “Forget my preference for terse replies.” → `remove` with the matching memory ID.
