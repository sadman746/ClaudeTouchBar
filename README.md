# ClaudeTouchBar

> 🚧 **Beta.** Personal project, built and tested on a single Mac (13" M1 MacBook
> Pro, macOS 26). Relies on undocumented private Apple APIs that could break with
> a future macOS update — see [How it works](#how-it-works) and
> [Known limitations](#known-limitations). No warranty; issues and PRs welcome.

A Claude-powered assistant that lives entirely on the Touch Bar of a Touch
Bar–equipped MacBook Pro. A persistent icon sits in the Control Strip, visible no
matter which app is in front. Tap it (or use a global keyboard shortcut) to ask a
question — typed or dictated — or to have Claude describe what's on your screen.
The answer scrolls across the Touch Bar itself. It can also act on your
Calendar, your Obsidian notes and Apple Mail.

Nothing ever touches your actual display: the Touch Bar is a separate hardware
panel, so this content never shows up in a screenshot, a screen recording, or a
screen share.

It talks to the `claude` CLI you're already logged into on this Mac — no
Anthropic or OpenAI API key, no separate billing.

## Features

- 🤖 Persistent Control Strip icon, always available regardless of the frontmost app
- 📅 Idle dashboard: opening the bar shows your next calendar event and the
  unread mail count before you ask anything
- 💬 Chat: type a question with the physical keyboard, see it echoed live on the
  Touch Bar as you type; the answer streams in as it is written, then scrolls
  by on its own as a ticker
- 🎤 Dictation: long-press 💬 to speak the question instead of typing it
- 📸 Screenshots: collect one or more shots, add an optional caption, send them
  together
- 🧭 Automatic context: the frontmost app and window title travel with the
  question, so "summarise this" works without explaining what "this" is
- 🗓 Assistant tools: create, read and delete Calendar events, Obsidian notes
  and Mail (drafts only — it never sends)
- ⌨️ Global keyboard shortcuts — `⌥ Option+Space` for chat, `⇧⌥ Shift+Option+Space`
  for an instant screenshot — that work from any app
- ⏹ Stop button while a request is running
- Conversation continuity: every question shares one ongoing `claude` session,
  so follow-ups have context
- No API key, no App Sandbox, no Mac App Store distribution

## Requirements

- A MacBook Pro with a physical Touch Bar (2016–2020 13"/15"/16" models, or the
  13" M1/M2 that kept it — the 2021+ 14"/16" redesign replaced it with physical
  function keys and this app has nothing to attach to there)
- macOS 13+ (built and tested on macOS 26)
- [Claude Code](https://claude.com/product/claude-code) installed and logged in
  (`claude` on your `PATH`, e.g. via `~/.local/bin/claude`)
- Xcode Command Line Tools (`xcode-select --install`) — full Xcode isn't required,
  the app builds with the Swift Package Manager
- Homebrew + `gh` only if you intend to fork and publish your own copy

## Getting started

```bash
git clone https://github.com/sadman746/ClaudeTouchBar.git
cd ClaudeTouchBar
./scripts/setup-signing.sh   # one-time: creates a stable local code-signing identity
./scripts/build-app.sh       # compiles and packages ClaudeTouchBar.app
open ClaudeTouchBar.app
```

To use the Calendar / Notes / Mail tools, also create your personal settings
file (it lives outside the repo, nothing personal is ever committed):

```bash
mkdir -p ~/.config/claudetouchbar
cp config.example ~/.config/claudetouchbar/config
$EDITOR ~/.config/claudetouchbar/config   # mail account, vault path, calendars
```

Chat and screenshots work without it. Restart the app after editing the file.

### Permissions

macOS asks for these the first time each one is needed:

| Permission | Used for | Required? |
|---|---|---|
| Screen Recording | screenshots, and the frontmost window title | for screenshots |
| Calendars | next event on the dashboard, fast agenda reads | for the dashboard |
| Automation (Calendar, Mail) | the assistant's calendar and mail actions | for those tools |
| Accessibility | sending the currently selected text as context | optional, never prompted |

After granting Screen Recording, relaunch the app once for it to take effect.
See [Code signing](#code-signing) for why `setup-signing.sh` matters.

### Launch at login

Open **System Settings → General → Login Items**, add `ClaudeTouchBar.app`
(after moving it to `/Applications`, or leaving it where it is — either works).

## Usage

Three ways to start:

- Tap the icon in the Control Strip → the dashboard opens with 💬 (chat) and
  📸 (screenshot)
- **⌥ Option+Space** anywhere → jumps straight into chat
- **⇧⌥ Shift+Option+Space** anywhere → takes one screenshot and sends it
  immediately, no menu

**Chat.** Type with the physical keyboard (the text shows on the Touch Bar as
you type) and press Return; Esc cancels. While typing, the Control Strip icon
steps aside so the preview gets the width. To dictate instead, long-press 💬.

**Answers.** While Claude works the bar shows what it is doing ("Leggo il
calendario…") and then the answer as it is written. Once finished, the answer
scrolls by on its own and loops. Drag it with a finger to re-read a part;
long-press it to copy the whole answer. 💬 next to it asks a follow-up.

**Screenshots.** 📸 takes a shot and shows a small menu: add another shot,
write a caption, or send. All shots go to Claude together.

**Context.** When you open the chat, the app notes which app and window were in
front and sends that along; the model is told to ignore it unless your question
refers to it. If the app has the Accessibility permission, the selected text is
included too (capped at 2000 characters).

**Sessions.** The conversation resets on its own after 20 minutes of
inactivity, so a long-idle session never keeps growing. To reset it on demand,
type **`/new`** as a chat message.

**Language.** The system prompt and the status messages are in Italian and tell
the model to always answer in Italian. To change that, edit `systemPrompt` and
`toolStatus` in `ClaudeRunner.swift`.

## Assistant tools (Calendar / Notes / Mail)

Beyond answering questions, the assistant can *act* on a few apps — create,
read and delete Calendar events, [Obsidian](https://obsidian.md) notes and Mail —
so you can say things like *"add a 3pm meeting tomorrow"*, *"note this in Work"*,
or *"read my latest mail"* right from the Touch Bar.

**How it's wired, safely.** The app launches `claude` in `--safe-mode` (no MCP
servers, no folder probing) and grants exactly one capability via
`--allowedTools`: a single dispatcher script, `tb-tools/tb`, copied into the app
bundle at build time. All AppleScript lives inside that script, so the assistant
can touch those three apps and *nothing else* on the Mac — there is no free-form
shell. Arguments reach AppleScript as parameters, never spliced into the script
source. Actions run without an interactive confirmation (the Touch Bar can't
show one), so:

- **Mail is never sent automatically** — `mail-compose` only opens a draft you
  review and send yourself.
- Deletions are reversible: mail goes to the Trash, notes to the vault's
  `.trash` folder.
- Every **mutating** action is appended to a local audit log at
  `~/Library/Logs/ClaudeTouchBar.log` (titles/subjects only, never bodies).

**Commands** (`tb <command> …`): `cal-list`, `cal-add`, `cal-del`; `note-list`,
`note-read`, `note-add`, `note-del` (Markdown files in the Obsidian vault);
`mail-list`, `mail-read`, `mail-search`, `mail-compose`, `mail-del`; and `brief`
(today's agenda + unread count). Every read sits behind a hard timeout so
nothing can hang.

**Configuration.** Which mail account, which vault and which calendars is
personal, so it is read from `~/.config/claudetouchbar/config` (template:
[`config.example`](config.example)). A feature whose setting is missing is
simply reported as not configured.

**Calendar reads.** The app itself reads Calendar through EventKit (recurring
events included) and keeps a small cache in
`~/Library/Caches/ClaudeTouchBar/calendar.txt`, refreshed every five minutes and
whenever the calendar changes. `tb cal-list` reads that cache when it is fresh
and the range is a week or less (instant), and falls back to AppleScript
otherwise — slower (10–20s) and blind to some recurring occurrences.

**Things to know.**

- `mail-read <n>` and `mail-del <n>` address a message by its position in the
  inbox; if new mail arrives between listing and acting, the number shifts.
- `cal-del` and `note-del` act on *every* item matching the given text.
- Mail you ask about is untrusted text read by a model that can run `tb`. The damage is bounded by what `tb` can do (nothing is sent, deletes
  are reversible), but keep it in mind before adding more powerful commands.

## How it works

The interesting (and fragile) part of this project is making a Touch Bar item
work like a genuine, persistent system control instead of an in-app-only touch
bar, which is all the public `NSTouchBar` API supports. Three private/undocumented
pieces make that possible — the same techniques used by
[Pock](https://github.com/pock/pock) and BetterTouchTool:

- **`DFRFoundation`** (a private framework, loaded via `dlopen`) exposes
  `DFRElementSetControlStripPresenceForIdentifier`, which pins a Touch Bar item
  into the Control Strip so it survives regardless of which app is frontmost.
- **`+[NSTouchBarItem addSystemTrayItem:]`** and
  **`+[NSTouchBar presentSystemModalTouchBar:systemTrayItemIdentifier:]`** are
  private category methods on public AppKit classes, called via
  `NSObject.perform(_:with:)` rather than a compile-time header. They let a
  background (non-frontmost) app both register that Control Strip item and
  later replace the whole Touch Bar with custom content system-wide.
- Getting a **real, editable, typeable text field** on there turned out to need
  a different trick: the private "system modal" Touch Bar above only supports
  taps, not keyboard input, for a third-party app. What actually works is a real
  (if visually negligible — 1 pixel tall, sitting just past the top edge of the
  display) `NSWindow` with a genuine `NSTextField`. Once that window is key,
  macOS routes real keystrokes to it, and overriding the window's public,
  fully-documented `makeTouchBar()` shows a live preview of what's being typed —
  which otherwise defaults to a generic word-completion candidate bar that
  doesn't echo the raw text.

Global keyboard shortcuts use Carbon's `RegisterEventHotKey`, which — unlike an
`NSEvent` global monitor — doesn't require Accessibility/Input Monitoring
permission.

## Code signing

None of the private-API tricks above need special entitlements, but macOS ties
TCC permission grants (Screen Recording, in this app's case) to the app's code
signing identity. An ad-hoc signature (`codesign --sign -`, the default for a
personal build) gets a **new** identity on every single rebuild, silently
invalidating every permission you granted the previous build — you'd have to
re-grant Screen Recording access after every `git pull` + rebuild.

`./scripts/setup-signing.sh` creates a small self-signed certificate once,
imports it into your login keychain, and asks you to mark it "Always Trust" for
code signing in Keychain Access (this one step needs GUI confirmation — macOS
doesn't allow it to be scripted non-interactively). From then on,
`build-app.sh` signs every build with that same stable identity, so a `git
pull` + rebuild doesn't cost you the Screen Recording grant again.

This is entirely local to your Mac — the certificate isn't checked into the
repo (`signing/` is gitignored) and has nothing to do with Apple's own code
signing / notarization infrastructure. It won't make the app distributable
outside this Mac; that's not the goal.

## Known limitations

- **Answers are in Italian** unless you edit the prompt (see [Usage](#usage)).
- **No Mac App Store distribution.** The private Control Strip APIs alone rule
  it out.
- **Private APIs can break.** `DFRFoundation`'s symbols and the private
  `NSTouchBarItem`/`NSTouchBar` methods are undocumented and unversioned; a
  future macOS update could change or remove them without notice.
- **Only tested on one machine.** Built and used on a 13" M1 MacBook Pro running
  macOS 26. It should work on any Touch Bar Mac running macOS 13+, but that's
  untested — please open an issue if something's off on your hardware/OS
  combination.
- **Screen Recording permission is required** for the screenshot feature (not
  for chat/dictation), and — see above — depends on the app being consistently
  signed with the same identity across rebuilds.
- **Live text preview may not always render.** The `makeTouchBar()` override
  showing what you're typing depends on macOS not overriding it with the system
  candidate bar; this has worked reliably in testing but hasn't been stress-tested
  across every macOS point release.

## Project layout

```
Sources/ClaudeTouchBar/
  AppDelegate.swift        Touch Bar menu, state machine, wiring
  TouchBarPrivate.swift    dlopen/dlsym + perform(_:with:) bridge to the private APIs
  InputWindow.swift        The real (if visually negligible) window + text field
  ClaudeRunner.swift       Shells out to `claude -p`, streaming, session handling
  Config.swift             Reads the personal settings file
  AgendaCache.swift        EventKit agenda: dashboard line + cache for `tb`
  FrontmostContext.swift   Frontmost app / window title / selected text
  ScreenshotCapture.swift  Wraps /usr/sbin/screencapture, downsizes to JPEG
  GlobalHotkeys.swift      Carbon RegisterEventHotKey wrapper
  MarqueeLabel.swift       Scrolling label used for typing, streaming and answers
tb-tools/tb                The only thing the assistant can execute
config.example             Template for ~/.config/claudetouchbar/config
scripts/
  build-app.sh             Compile + package + sign
  setup-signing.sh         One-time local signing identity setup
```

## Contributing

Issues and pull requests are welcome — this is a beta built for one person's
one Mac, so reports from other Touch Bar models/macOS versions are especially
useful.

## License

[MIT](LICENSE)
