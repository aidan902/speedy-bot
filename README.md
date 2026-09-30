# Speedy Bot

A small Mac app for techs who live in ScreenConnect and ChatGPT. It removes three bits of repeated hand work.

> **Beta.** The build on the [Releases page](https://github.com/aidan902/speedy-bot/releases) is signed but not yet notarized by Apple, so macOS blocks it the first time you open it. After trying to open it, go to System Settings > Privacy & Security and click **Open Anyway**. This note goes away with the first notarized release.

## What it does

1. **Screenshots paste themselves into ChatGPT.** Take a screenshot (Cmd+Shift+3, 4 or 5), then do whatever you chose as the trigger. The screenshot lands in the message box, once per screenshot. The trigger can be:
   - resting the pointer on the ChatGPT window (the default, no click),
   - a double-click or a triple-click in ChatGPT,
   - a keyboard shortcut you record (a mouse button set to send a keystroke works too).

   With the pointer trigger you can also set an age limit: a screenshot that has waited longer than, say, 30 seconds no longer pastes by itself and needs a double-click.
2. **Cmd+Shift+V types into ScreenConnect.** In a remote session, the shortcut types your copied text into the remote machine key by key. It works on login screens and prompts where paste does not. Esc stops it. You can record a different shortcut.
3. **Cmd+Shift+2 captures the ScreenConnect window.** One press takes a screenshot of the whole session window, no dragging, and handles it like any other screenshot. macOS asks for the Screen Recording permission the first time. You can record a different shortcut.
4. **Screenshots filed by incident (optional).** Switch on "Save screenshots for documentation", give it the incident number, and every screenshot is also saved as
   `~/Documents/SpeedyBot Documentation/#INC - 12,345/#INC - 12,345 2026-09-30 at 11.04.12.png`.

## Install

Download [SpeedyBot.dmg](https://github.com/aidan902/speedy-bot/releases/latest/download/SpeedyBot.dmg), open it, and drag Speedy Bot into Applications. Open it from Applications, not from the disk image.

Or from Terminal:

```bash
curl -fsSL https://github.com/aidan902/speedy-bot/releases/latest/download/install.sh | bash
```

The script checks the download is signed by the right developer and notarized before it installs anything.

Needs macOS 13 or later. Runs on Intel and Apple silicon.

## First run

Speedy Bot asks for one permission: **System Settings > Privacy & Security > Accessibility > Speedy Bot**. That is what lets it press Cmd+V and type for you. On a standard account macOS asks for an admin password to switch it on.

## Turning things on and off

Speedy Bot has three states: **Off**, **On**, and **Auto**. Auto means it only works while a ScreenConnect session is open, and leaves your Mac alone the rest of the time.

- **The window.** Open Speedy Bot from Applications or the Dock. Off / On / Auto, one round switch per feature (blue is on), and the options under each.
- **The menu bar icon** (a hare). The same switches.
- **Control Center** (macOS 26 or later). Control Center > Edit Controls > add "Speedy Bot" for a one-tap on/off.

Closing the window leaves Speedy Bot working. Quit stops it.

## What changes on your Mac

By default, while a screenshot feature is on:

- Cmd+Shift+3/4/5 put the picture on the **clipboard** instead of saving a file on the Desktop, so the paste is instant.
- The floating thumbnail in the corner is switched off (it delays the screenshot by about five seconds).
- Both settings go back to what you had when you switch the features off or quit Speedy Bot.
- A screenshot on the clipboard also reaches your other Apple devices through Universal Clipboard.
- A screenshot replaces whatever text you had copied. Copy the text again before Cmd+Shift+V.

Tick **Also do my normal screenshot action** to change none of that. Screenshots then save where they always do and the corner thumbnail still pops up. Speedy Bot picks the saved file up instead, which means the paste waits until the file exists: about five seconds while the thumbnail is on. In this mode the clipboard is only borrowed for the paste and what you had copied is put back. macOS may ask once to let Speedy Bot see the folder your screenshots are saved in.

## Limits

- The ChatGPT **desktop app** only, not chatgpt.com in a browser.
- Apple's own screenshot shortcuts only, not third-party screenshot tools.
- Typing covers the characters on this Mac's current keyboard layout. If the clipboard has a character the layout cannot type, nothing is typed and Speedy Bot says which character.
- Text longer than 500 characters needs Cmd+Shift+V twice.
- Inside a Windows remote, ordinary paste is Control+V. Cmd+V there is the Windows key.
- Typing stops if you press Esc, hold Cmd/Control/Option, switch away from the session, or the ScreenConnect chat window takes focus.

## Update

Run the install command again, or replace the app in Applications with the new one. The Accessibility permission carries over.

## Uninstall

```bash
curl -fsSL https://github.com/aidan902/speedy-bot/releases/latest/download/install.sh | bash -s -- --uninstall
```

Or **quit Speedy Bot first**, then drag it to the Trash. Quitting first matters: quitting is what puts your screenshot settings back. Saved screenshots in `SpeedyBot Documentation` are never deleted.

## Building from source

Needs Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```bash
scripts/build.sh --adhoc
```

That builds a universal Release app into `~/Library/Caches/speedy-bot-build`. Without `--adhoc` it signs with the Developer ID certificate for the team in `project.yml`. Do not build inside an iCloud-synced folder: the sync adds file attributes that make code signing fail, which is why the build goes to `~/Library/Caches`.

`scripts/release.sh "<path to Speedy Bot.app>" --notarize` signs, notarizes and packages a release (zip and disk image). `scripts/make-icon.swift` regenerates the app icon.

## How it works

- A screenshot sent to the clipboard is a single item of type `public.png`. Speedy Bot polls the clipboard's change counter (it does not read the contents), and when it sees that shape it waits for the trigger, brings the ChatGPT window forward and presses Cmd+V. In "normal screenshot action" mode it watches the screenshot folder for files carrying the system's screenshot tag instead.
- Cmd+Shift+V is a system hotkey that is only registered while ScreenConnect is the front app, so the shortcut keeps its normal meaning everywhere else. The text is sent as real key presses using the current keyboard layout.
- The log (`log show --predicate 'subsystem == "net.fm.speedybot"'`) records what happened, never clipboard contents or lengths.
