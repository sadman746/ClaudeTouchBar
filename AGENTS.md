# ClaudeTouchBar — AGENTS.md

macOS app that puts a Claude-powered assistant on the **Touch Bar** of a Touch
Bar MacBook Pro. Persistent Control Strip icon → chat / screenshot / dictation,
plus an assistant that can act on Calendar, Obsidian notes and Mail. Full details
in `README.md` — read it before changing behavior.

## Stack
- Swift, built with **Swift Package Manager** (`Package.swift`), no full Xcode needed.
- Uses private/undocumented Apple APIs (`DFRFoundation`, private `NSTouchBar*`
  methods) to pin a system-wide Control Strip item — fragile across macOS updates.
- Talks to the local `claude` CLI (no API key), launched in `--safe-mode` with a
  single `--allowedTools` dispatcher: `tb-tools/tb`.

## Build / run
```bash
./scripts/setup-signing.sh   # one-time: stable local code-signing identity
./scripts/build-app.sh       # compile + package + sign ClaudeTouchBar.app
open ClaudeTouchBar.app
```
Requires: Touch Bar Mac, macOS 13+, `claude` on PATH, Xcode Command Line Tools.

## Layout
- `Sources/ClaudeTouchBar/` — app code (`AppDelegate`, `TouchBarPrivate`,
  `InputWindow`, `ClaudeRunner`, `Config`, `AgendaCache`, `FrontmostContext`,
  `ScreenshotCapture`, `GlobalHotkeys`, `MarqueeLabel`)
- `config.example` — template for the personal settings file
- `tb-tools/tb` — the ONLY thing the assistant can execute; all AppleScript for
  Calendar/Notes/Mail lives here (no free-form shell)
- `scripts/` — build + signing

## Conventions & safety (read before editing the assistant)
- **Mail is never sent automatically** — `mail-compose` only opens a draft.
- Mutating actions are audit-logged to `~/Library/Logs/ClaudeTouchBar.log`
  (titles/subjects only, never bodies). Keep this invariant.
- Code signing must stay stable across rebuilds or macOS revokes Screen Recording.
- No personal data in the repo: account names, addresses, vault paths and
  calendar names belong in `~/.config/claudetouchbar/config` (see
  `config.example`), read by `Config.swift` and sourced by `tb`.
- Code and code comments in English.
