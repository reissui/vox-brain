# Agents: read CLAUDE.md

The full charter for working in this vault lives in [CLAUDE.md](CLAUDE.md). It applies to every agent — Claude Code, Hermes/OpenClaw, or anything else with access to this folder (locally, via a git clone, or over SSH — see [integrations/capture-everywhere.md](integrations/capture-everywhere.md)).

Quick reference:
- Capture for the owner: `scripts/brain add <url> "<their comment>"` or `scripts/brain note "<thought>"`
- Process the inbox: `scripts/brain process`
- Answer questions from their knowledge: `scripts/brain ask "<question>"` (or Grep the vault directly and cite `[[notes]]`)
