# ClaudeTouchBar

> 🚧 **Beta.** Personal project, built and tested on a single Mac (13" M1 MacBook
> Pro, macOS 26). Relies on undocumented private Apple APIs that could break with
> a future macOS update — see [How it works](#how-it-works) and
> [Known limitations](#known-limitations). No warranty; issues and PRs welcome.

A Claude-powered assistant that lives entirely on the Touch Bar of a Touch
Bar–equipped MacBook Pro. A persistent icon sits in the Control Strip, visible no
matter which app is in front. Tap it (or use a global keyboard shortcut) to ask a
question — typed or dictated — or to have Claude describe what's on your screen.
The answer scrolls across the Touch Bar itself.

Nothing ever touches your actual display: the Touch Bar is a separate hardware
panel, so this content never shows up in a screenshot, a screen recording, or a
screen share.

It talks to the `claude` CLI you're already logged into on this Mac — no
Anthropic or OpenAI API key, no separate billing.

## Features

- 🤖 Persistent Control Strip icon, always available regardless of the frontmost app
- 💬 Chat: type a question with the physical keyboard, see it echoed live on the
  Touch Bar as you type, get the answer back the same way
- 📸 Screenshot analysis: captures the whole screen and asks Claude to describe
  what's on it
- 🎤 Dictation: same as chat, but kicks off macOS's built-in dictation so you can
  speak the question instead of typing it
- ⌨️ Global keyboard shortcuts — `⌥ Option+Space` for chat, `⇧⌥ Shift+Option+Space`
  for a direct screenshot — that work from any app, no need to reach for the
  Touch Bar at all
- Conversation continuity: every question (chat or screenshot) shares one
  ongoing `claude` session, so follow-up questions have context
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

The first time you trigger a screenshot, macOS will prompt for **Screen
Recording** permission — accept it, then relaunch the app once for the grant to
take effect. See [Code signing](#code-signing) for why `setup-signing.sh`
matters and what it actually does.

### Launch at login

Open **System Settings → General → Login Items**, add `ClaudeTouchBar.app`
(after moving it to `/Applications`, or leaving it where it is — either works).

## Usage

Three ways to start:

- Tap the 🤖 icon in the Control Strip → pick 💬 (chat), 📸 (screenshot), or
  🎤 (dictation)
- **⌥ Option+Space** anywhere → jumps straight into chat
- **⇧⌥ Shift+Option+Space** anywhere → takes a screenshot immediately, no menu

For chat, type with the physical keyboard (the text scrolls across the Touch Bar
as you type) and press Return. The answer then scrolls in as a ticker; from
there you can go straight into another 💬 question or 📸 screenshot without
returning to the main menu — the conversation keeps its context throughout.

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
  TouchBarPrivate.swift     dlopen/dlsym + perform(_:with:) bridge to the private APIs
  InputWindow.swift        The real (if visually negligible) window + text field
  ClaudeRunner.swift       Shells out to `claude -p`, manages the session ID
  ScreenshotCapture.swift  Wraps /usr/sbin/screencapture
  GlobalHotkeys.swift      Carbon RegisterEventHotKey wrapper
  MarqueeLabel.swift       Scrolling label for long text on a narrow Touch Bar
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
