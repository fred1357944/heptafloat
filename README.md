<p align="center">
  <img src="assets/icon-1024.png" width="128" alt="HeptaFloat icon">
</p>

<h1 align="center">HeptaFloat</h1>

<p align="center">
  <b>Today's Heptabase journal, one keystroke away.</b><br>
  A small floating card that sits above your other windows — jot a thought, tick a to-do, and get back to work.
</p>

<p align="center">
  <a href="https://github.com/madeyexz/heptafloat/releases/latest"><b>⬇︎ Download for Mac</b></a>
  &nbsp;·&nbsp; macOS 13 or later &nbsp;·&nbsp; Apple Silicon & Intel &nbsp;·&nbsp; Free & open source
</p>

<p align="center">
  <img src="docs/demo.gif" width="560" alt="Typing a to-do with the / menu, mentioning a card with @, and ticking it off">
</p>

---

## Why

Opening Heptabase, finding today's journal, and switching back breaks your flow. HeptaFloat keeps today's journal in a little card you can pop up from anywhere — like Raycast Notes, but it **is** your Heptabase journal. Everything you type is saved straight into Heptabase, and anything you add in Heptabase shows up in the card.

## What you get

| | |
|---|---|
| <img src="docs/screenshot-light.png" alt="HeptaFloat in light mode floating over another window"> | <img src="docs/screenshot-dark.png" alt="HeptaFloat in dark mode"> |
| **Floats above everything.** Put it anywhere on screen; it stays on top across desktops and full-screen apps. | **Looks like Heptabase.** Same fonts, colors, checkboxes and lists — in light and dark. |
| <img src="docs/screenshot-commands.png" alt="The / command menu"> | <img src="docs/screenshot-mention.png" alt="Searching cards with @"> |
| **Type `/` for blocks** — to-dos, headings, bullets, toggles, quotes, dividers, today's date. | **Type `@` to mention a card** from your Heptabase library. Click a mention to open it in Heptabase. |

- **One shortcut to show and hide** — <kbd>⌃</kbd> <kbd>⌥</kbd> <kbd>J</kbd> by default; pick another in the menu bar.
- **Saves as you type** and stays in sync with Heptabase both ways.
- **Always today's page** — at midnight it moves to the new day's journal on its own.
- **Lives in your menu bar**, no Dock icon. Can start when you log in.

## Install

1. **Download** `HeptaFloat-x.y.z.zip` from the [latest release](https://github.com/madeyexz/heptafloat/releases/latest) and double-click it to unzip.
2. **Drag `HeptaFloat`** into your **Applications** folder.
3. **Open it.** Because HeptaFloat isn't from the App Store, macOS will warn you the first time:
   - Click **Done** (or **Cancel**) on the warning.
   - Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to HeptaFloat.
   - Confirm with **Open**. You only need to do this once.

### One-time setup in Heptabase

HeptaFloat talks to Heptabase through Heptabase's built-in **CLI** (its local connection for other apps).

1. Make sure the **Heptabase desktop app** is installed and running.
2. In Heptabase, open **Settings** and turn on the **CLI** (install/enable it). Heptabase may require an active subscription for this.
3. That's it — open HeptaFloat and today's journal appears.

> If the card says *"heptabase CLI not found"* or *"Heptabase isn't responding"*, Heptabase is closed or its CLI is turned off.

## How to use it

| Do this | To |
|---|---|
| <kbd>⌃</kbd> <kbd>⌥</kbd> <kbd>J</kbd> | Show or hide the card from any app |
| <kbd>Esc</kbd> | Hide it and go back to what you were doing |
| Drag the top edge | Move it; drag any edge to resize (it remembers) |
| `/` | Insert a block: to-do, heading, list, toggle, quote, code, divider, date |
| `@` or `[[` | Mention a card |
| Select text | Bold, italic, underline, strikethrough, code, link |
| <kbd>Tab</kbd> / <kbd>⇧</kbd> <kbd>Tab</kbd> | Indent / outdent a list item |
| <kbd>⌘</kbd> <kbd>↩</kbd> | Tick or untick a to-do |
| <kbd>⌘</kbd> <kbd>O</kbd> | Open today's journal in Heptabase |
| <kbd>⌘</kbd> <kbd>=</kbd> / <kbd>⌘</kbd> <kbd>-</kbd> | Bigger / smaller text |

You can also type Markdown: `- ` bullets, `1. ` numbers, `[] ` to-dos, `# ` headings, `> ` quotes, `---` dividers.

**Menu bar icon** (the little note): show/hide, **Keep on Top** (turn off to make the card tuck away when you switch apps), **Appearance** (System / Light / Dark), **Shortcut**, **Open in Heptabase**, **Launch at Login**, and Quit.

> Using Raycast or another launcher? Set HeptaFloat's own **Shortcut** to the key you like instead of a launcher hotkey — macOS doesn't let launchers hide menu-bar apps, so only HeptaFloat's shortcut can toggle it both ways.

## Privacy

HeptaFloat runs entirely on your Mac. It reads and saves your journal through the Heptabase app on your computer and never sends your notes anywhere else. No accounts, no analytics.

## FAQ

**Does it work with notes other than the journal?** Not yet — it's focused on today's journal.

**Will it mess up my journal?** HeptaFloat keeps everything it doesn't edit exactly as it was (images, embeds, colors, tables…). Each save is checked against the latest version in Heptabase, so it won't overwrite changes you made there.

**Is this made by Heptabase?** No — it's an independent, unofficial companion app.

---

## For developers

HeptaFloat is a native Swift shell (floating `NSPanel`, global hotkey, menu bar item) around a [ProseMirror](https://prosemirror.net) editor in a `WKWebView`. It reads and writes the journal with the Heptabase CLI (`heptabase journal read/save`), with md5 conflict checks.

```
Sources/main.swift   app shell: window, hotkey, menu bar, CLI bridge
src/schema.js        lossless ProseMirror schema for Heptabase's card format
src/editor.js        editor state, autosave, sync, day rollover
src/commands.js      list editing (indent, split, toggle…)
src/menus.js         "/" menu, @ mentions, selection toolbar, placeholders
src/index.html       styles (Heptabase theme tokens, light/dark)
preview/             run the editor in a browser with a demo journal
```

**Build:** `./build.sh` (needs [Bun](https://bun.sh) and Xcode Command Line Tools) — builds a Universal app, installs it to `~/Applications`, and writes `dist/HeptaFloat-<version>.zip`.

**Try the editor without Heptabase:** `./preview/serve.sh`, then open <http://localhost:8765/stage.html>.

**Regenerate screenshots and the demo:** `./preview/capture.sh` (needs `agent-browser` and `ffmpeg`).

**Round-trip test:** `bun test/roundtrip.js <folder of journal JSON>` checks that loading and saving a journal changes nothing.

## License

[MIT](LICENSE) © 2026 Ian Hsiao. Bundles the [Inter](https://rsms.me/inter/) typeface under the [SIL Open Font License](src/fonts/OFL.txt).
Heptabase is a trademark of its owners; this project is not affiliated with Heptabase.
