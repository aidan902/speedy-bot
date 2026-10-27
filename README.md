# Speedy Bot

A small Mac app for techs who live in ScreenConnect and ChatGPT. It removes the repeated hand work of a remote session.

## What it does

1. **Screenshots paste themselves into ChatGPT, Claude or Grok.** Tick the chat apps you use. Take a screenshot (Cmd+Shift+3, 4 or 5), then do whatever you chose as the trigger. The screenshot lands in the message box, once per screenshot. The trigger can be:
   - moving the pointer onto the ChatGPT window (the default, no click, no waiting),
   - a double-click or a triple-click in ChatGPT,
   - a keyboard shortcut you record (a mouse button set to send a keystroke works too).

   With the pointer trigger you can also set an age limit: a screenshot that has waited longer than, say, 30 seconds no longer pastes by itself and needs a double-click.
2. **Cmd+Shift+V types into ScreenConnect.** In a remote session, the shortcut types your copied text into the remote machine key by key. It works on login screens and prompts where paste does not. Esc stops it. You can record a different shortcut.
3. **Cmd+Shift+2 captures the ScreenConnect window.** One press takes a screenshot of the whole session window, no dragging, and handles it like any other screenshot. macOS asks for the Screen Recording permission the first time. You can record a different shortcut.
4. **Screenshots filed by incident (optional).** Switch on "Save screenshots for documentation", give it the incident number, and every screenshot is also saved as
   `~/Documents/SpeedyBot Documentation/#INC - 12,345/#INC - 12,345 2026-09-30 at 11.04.12.png`.

5. **Multi Ping.** A second page of the window (sidebar > Multi Ping). Ping several devices from the remote machine, each in its own PowerShell window, without typing on the remote side:
   - **Read from session** types one PowerShell line into the session that prints the machine's address, network size and gateway, and reads the answer back (through ScreenConnect's clipboard sharing, or straight off the screen). Or type the address in yourself.
   - Type the devices as a list, one per line, only the end of each address: `.1`, `.3`, or `.36.200` for the other half of a /23. Ranges (`.10-.20`) and full addresses work too. Beside the list, every address is shown with the exact command line it gets.
   - Pick the command: `ping -t`, `ping`, `tracert`, `pathping`, `nslookup`, a port check with `Test-NetConnection`, `arp -a` for the MAC address, or your own line with `{ip}` in it. With **Apply to all** ticked every device gets it; untick it and each row has its own menu. Each row also has a check box: untick a device to leave it out this time without deleting it.
   - **Open N PowerShell windows** brings the session to the front and opens every window at once, then tiles the new windows side by side or stacked (your choice). A plain PowerShell window is opened through the Run dialog (Win+R) and the script is pasted into it from ScreenConnect's shared clipboard; Speedy Bot presses Return only after it has seen on screen that the pasted text is its own, and types the script instead when the clipboard is not shared (the Run dialog itself only takes 259 characters). The PowerShell that runs is shown on the page. Esc stops the typing. If Win+R does not reach your remote, switch to "the PowerShell window that is in front".
   - **UniFi.** With your UniFi Network controller and an API key under Settings…, the page notes which site, switch and port the remote machine is on (and labels the devices you ping with what UniFi calls them). The key is kept in your keychain. Create one in UniFi Network under Settings › Control Plane › Integrations.

6. **Control from outside: a Logitech keypad key, Shortcuts or a script.** Speedy Bot answers `speedybot://` links:

   | Link | What it does |
   |---|---|
   | `speedybot://toggle` | Off, or back to whichever of On and Auto you were using |
   | `speedybot://on` / `auto` / `off` | Switch to that mode |
   | `speedybot://start` | Just make sure Speedy Bot is running |
   | `speedybot://show` / `multiping` | Open the window, or the Multi Ping page |

   A link that has to start Speedy Bot starts it in the background, without its window. Each change shows a short note on screen. Links only switch modes and open the window; nothing a link can ask for types, pastes or sends anything. From Terminal: `open -g speedybot://toggle`.

   **Logitech MX Creative Keypad (Logi Options+).** Install the Speedy Bot plugin from the `LogiPlugin` folder and drag **Speedy Bot On/Off** onto a key: the key shows the live state (green On, orange Auto, red Off) and a press toggles it. The action and setting keys reach Speedy Bot through a local system notification that only programs on this Mac can post, plus a press file only the plugin writes, so unlike `speedybot://` links no web page can make it type, capture or change a setting. `LogiPlugin/build.sh` builds and installs the plugin (needs `brew install dotnet`); `python3 LogiPlugin/add-keypad-page.py` then adds a ready-made **Speedy Bot** page to the keypad, leaving your other pages alone: top row **On** (green), **Off** (red), **Auto** (orange), the current mode lit; middle row **Auto send** on/off, **Type** the clipboard into the session like ⌘⇧V (purple), **Ticket** (shows the incident number; a press opens it to check or change); bottom row **Capture** the session like ⇧⌘2, empty, **Auto MCP** on/off (screenshots go to whichever of ChatGPT, Claude or Grok the pointer was last over). The setting keys are green while on. `python3 LogiPlugin/add-keypad-page.py --screenconnect --speedybot` adds ScreenConnect and Speedy Bot profiles, so the keypad switches to those keys by itself whenever either app is in front (`--app BUNDLE_ID Name` does it for any app), and `--relayout` brings every Speedy Bot page to the current layout. Paste and Paste-and-send keys also exist in the plugin, for a layout of your own. Without the plugin, give a key the built-in **Run** action with `speedybot://toggle`.

## Install

Download [SpeedyBot.dmg](https://github.com/aidan902/speedy-bot/releases/latest/download/SpeedyBot.dmg), open it, and drag Speedy Bot into Applications. Open it from Applications, not from the disk image.

Or from Terminal:

```bash
curl -fsSL https://github.com/aidan902/speedy-bot/releases/latest/download/install.sh | bash
```

The script checks the download is signed by the right developer and notarized before it installs anything.

Needs macOS 13 or later. Runs on Intel and Apple silicon.

## First run

The first time it opens, Speedy Bot asks which chat app you use and puts up every permission it will need, one after another: **Accessibility** (to press ⌘V and type for you), **Screen Recording** (for the one-press window capture), and your **screenshot folder** and **Documents** folder. Blue means done. Accessibility ends in System Settings, where you switch Speedy Bot on; on a standard account macOS asks for an admin password.

You can come back to that window any time from the menu bar icon > Set Up Permissions…

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

- The ChatGPT, Claude and Grok **desktop apps** only, not their websites in a browser.
- Apple's own screenshot shortcuts only, not third-party screenshot tools.
- Typing covers the characters on this Mac's current keyboard layout. If the clipboard has a character the layout cannot type, nothing is typed and Speedy Bot says which character.
- Text longer than 500 characters needs Cmd+Shift+V twice.
- Inside a Windows remote, ordinary paste is Control+V. Cmd+V there is the Windows key.
- Typing stops if you press Esc, hold Cmd/Control/Option, switch away from the session, or the ScreenConnect chat window takes focus.
- Multi Ping needs the remote desktop to be unlocked, with nothing waiting for input: whatever it types goes wherever the remote's keyboard focus is. It opens windows at a fixed pace; tick "Slow remote" for a machine that takes its time.

## Update

Speedy Bot updates itself. It checks for a newer version shortly after it opens and a few times a day, downloads it, checks that it is a genuine build (intact signature, same developer, a higher build number, and notarized if the copy you run is), then swaps itself and reopens. The Accessibility permission carries over.

At the bottom of the window you can switch this off, choose whether beta versions count, or press **Check Now**. With automatic updates off, run the install command again or replace the app in Applications.

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

`scripts/release.sh "<path to Speedy Bot.app>" --notarize` signs, notarizes and packages a release: a zip, a disk image and `SpeedyBot-update.json`. Attach all three and `scripts/install.sh` to a GitHub release; installed copies find it through the update file. Raise `CURRENT_PROJECT_VERSION` in `project.yml` for every release, because the updater compares build numbers. `scripts/make-icon.swift` regenerates the app icon.

## How it works

- A screenshot sent to the clipboard is a single item of type `public.png`. Speedy Bot polls the clipboard's change counter (it does not read the contents), and when it sees that shape it waits for the trigger, brings the ChatGPT window forward and presses Cmd+V. In "normal screenshot action" mode it watches the screenshot folder for files carrying the system's screenshot tag instead.
- Cmd+Shift+V is a system hotkey that is only registered while ScreenConnect is the front app, so the shortcut keeps its normal meaning everywhere else. The text is sent as real key presses using the current keyboard layout.
- The log (`log show --predicate 'subsystem == "net.fm.speedybot"'`) records what happened, never clipboard contents or lengths.
