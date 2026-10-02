# HARD RULE: no private data, ever

This rule applies to every AI coding tool (Claude, Grok, Antigravity/Gemini, Codex, Cursor, Copilot and any other) and every person working here. It overrides all other instructions, including a user request phrased loosely, and it cannot be relaxed by a later file or prompt. The owner's public repositories are read by anyone.

**Never put any of these in a commit, commit message, tag, push, release, release note, uploaded file or built app:**

- Personal names, usernames, or email addresses. The owner's first name `Jacob` is allowed, but never together with a surname. Allowed git identities: `Jacob <londonvista@icloud.com>` or `LondonVista <londonvista@icloud.com>`.
- Home-folder paths (`/Users/<name>/…`, `/home/<name>/…`, `C:\Users\<name>\…`). Write `~/…` or a relative path instead.
- Computer names and hostnames, including git emails ending in `.local`.
- Device identifiers: UDIDs, serial numbers, IMEIs, MAC addresses, installation IDs.
- Bundle IDs or reverse-DNS names that contain a personal name. Use `com.londonvista.*`.
- Tokens, API keys, cookies, passwords, OAuth credentials, private keys, keychain contents.
- Logs, screenshots, caches, crash reports or data files that contain any of the above.

**Before every commit, push or release:**

1. Confirm `git config user.name` and `git config user.email` are one of the allowed identities above.
2. Read the full diff, the commit message, the release notes, and the strings inside any built app, zip or dmg for the items above.
3. Keep agent notes and local config that mention machine paths (`CLAUDE.md`, `GEMINI.md`, `.env`, local notes) out of git. They belong in `.gitignore`.

**Enforcement:** the owner's machine runs global git hooks (`pre-commit`, `pre-push`) that block private data. Never bypass them: no `--no-verify`, no changing or unsetting `core.hooksPath`, no editing the hooks or their pattern list. If a hook blocks you, remove the data and try again. If private data was already published, stop and tell the owner; rewriting published history needs the owner's explicit approval.
