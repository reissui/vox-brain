# Brain Telegram

A single-user, always-on Telegram conversation layer for the Brain. It runs on the remote Mac with `launchd`, answers from the local vault and live read-only Gmail search through `codex exec`, captures approved notes and links through the existing gateway, and asks about unresolved meeting details rather than allowing the Librarian to guess. Gmail results are transient and are not copied into the vault unless the owner explicitly asks to save something.

It uses the remote Mac's existing **Codex sign-in with ChatGPT**. It does not use `OPENAI_API_KEY` or create separate OpenAI API usage. Ordinary conversation defaults to `gpt-5.6-terra`. Durable interaction learning is a separate, gated pass through the versioned `telegram-learn-owner` skill and defaults to `gpt-5.6-sol`; it never falls back to a weaker model. Set `BRAIN_TELEGRAM_MODEL`, `BRAIN_TELEGRAM_LEARNING_MODEL`, or `BRAIN_SITE_URL` before installation to override them; the learning override must still name a Sol model.

## Install on the remote Mac

1. In Telegram, open **@BotFather**, send `/newbot`, choose a name and username, and copy the bot token.
2. On the remote Mac, confirm `codex login status` says `Logged in using ChatGPT` and initialize the external Brain data root.
3. From the vault, run:

   ```bash
   BRAIN_SOURCE_ROOT="$PWD" \
   BRAIN_DATA_ROOT="$HOME/Library/Application Support/Brain/Vault" \
     apps/telegram-bot/install.sh
   ```

4. Paste the BotFather token when asked. The installer validates it, then asks you to send `/start` to the bot. Confirm the Telegram account it finds.
5. Send `/status` and then ask, “What should I focus on today?”

The token and paired numeric Telegram IDs are stored in macOS Keychain when available. Headless SSH sessions that cannot write to Keychain automatically use `~/Library/Application Support/Brain/telegram-secrets.json` with owner-only (`600`) permissions. Secrets never enter the repository or launchd plist. Messages from every other Telegram account are ignored. Conversation context stays in `~/Library/Application Support/Brain/telegram-state.json`, also owner-only.

Telegram captures can use the deprecated compatibility gateway only when its
three legacy settings are deliberately configured. Otherwise the bot writes
the same validated capture directly into the canonical remote `inbox/`; a
gateway problem does not lose the note.

Replies use Telegram's native HTML mode. Markdown headings, backticks, and Obsidian `[[wikilinks]]` are never shown raw. A wikilink resolves to a clickable private-site link only when the target is in the site's publish allowlist (`notes/`, `sources/`, or `maps/`); private or missing targets are shown as ordinary text.

When the owner states a durable preference, correction, routine, or context-dependent instruction, Terra proposes a learning candidate and Sol decides whether it is safe and durable. Accepted changes go into the owner-only Telegram state immediately, are included in future assistant prompts, and are also captured into the Brain for normal Librarian processing. Sol can replace or remove conflicting memories; `/memory` shows the current set. If Sol is unavailable, the bot keeps the existing memory unchanged and says so rather than silently using a weaker model.

## Commands

- `/today` — current daily command center
- `/questions` — unresolved meeting confirmations
- `/memory` — learned Telegram interaction preferences and conditions
- `/status` — local vault and automation status
- `/forget` — clear recent Telegram chat context without changing Brain notes

Everything else is ordinary conversation. “Remember…”, “save this link…”, or
an answer to a meeting question is captured into the Brain inbox and processed
by the hourly Librarian.
