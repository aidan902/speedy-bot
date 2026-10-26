#!/usr/bin/env python3
"""Adds a "Speedy Bot" page to the MX Creative Keypad's General profile (Logi Options+), leaving every other page
and key as it is. Page buttons (< >) on the keypad switch to it.

    python3 LogiPlugin/add-keypad-page.py            add the page (backs the profile up first)
    python3 LogiPlugin/add-keypad-page.py --remove   take the Speedy Bot page out again

Keys: On/Off (shows the live state), On, Auto, Off, Multi Ping. Needs the Speedy Bot plugin installed
(LogiPlugin/build.sh). The plugin service saves profiles when it quits, so the file is written while it is
stopped; Logi Options+ starts it again straight away. The keypad is device Loupedeck70.
"""
import datetime, glob, json, os, shutil, subprocess, sys, time, uuid

ROOT = os.path.expanduser("~/Library/Application Support/Logi/LogiPluginService")
PROC = "LogiPluginService.app/Contents/MacOS/LogiPluginService"
P = "$SpeedyBot___Loupedeck.SpeedyBotPlugin."
KEYS = [P + "ToggleCommand", P + "ModeCommand___on", P + "ModeCommand___auto", P + "ModeCommand___off",
        P + "ModeCommand___multiping", None, None, None, None]
PAGE = "Speedy Bot"


def running():
    return subprocess.run(["pgrep", "-f", PROC], capture_output=True).returncode == 0


def main():
    remove = "--remove" in sys.argv
    found = glob.glob(os.path.join(ROOT, "Applications", "Loupedeck70", "@_defaultmac", "Profiles", "*", "ProfileInfo.json"))
    if len(found) != 1:
        sys.exit(f"Expected one keypad General profile, found {len(found)}. Is an MX Creative Keypad set up in Logi Options+?")
    info_path = found[0]
    pdir = os.path.dirname(info_path)
    if not os.path.isdir(os.path.join(ROOT, "Plugins", "SpeedyBot")) and not remove:
        sys.exit("The Speedy Bot plugin is not installed. Run LogiPlugin/build.sh first.")

    d = json.load(open(info_path, encoding="utf-8"))
    pages = d["layout"]["layoutModes"][0]["workspaces"][0]["pressPages"]
    has = any(p.get("displayName") == PAGE for p in pages)
    if remove:
        if not has:
            sys.exit("There is no Speedy Bot page; nothing changed.")
        d["layout"]["layoutModes"][0]["workspaces"][0]["pressPages"] = [p for p in pages if p.get("displayName") != PAGE]
    else:
        if has:
            sys.exit("The keypad already has a Speedy Bot page; nothing changed.")
        first = pages[0]
        pages.append({
            "$type": first["$type"],
            "name": uuid.uuid4().hex.upper(),
            "displayName": PAGE,
            "description": None,
            "controls": [{"$type": first["controls"][0]["$type"], "controlId": i, "pressAction": a, "rotateAction": None}
                         for i, a in enumerate(KEYS)],
        })
        names = d.get("additionalNativePluginNames") or []
        if "SpeedyBot" not in names:
            names.append("SpeedyBot")
        d["additionalNativePluginNames"] = names
    now = datetime.datetime.now(datetime.timezone.utc)
    d["lastModifiedTimeUtc"] = now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond:06d}Z"
    text = json.dumps(d, indent=4, ensure_ascii=False) + "\n"
    json.loads(text)

    backup = os.path.expanduser("~/Library/Caches/speedy-bot-build/logi-profile-backup-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    shutil.copytree(pdir, backup)
    print("Backed up the profile to", backup)

    subprocess.run(["osascript", "-e", "with timeout of 15 seconds", "-e", 'tell application id "com.logi.pluginservice" to quit', "-e", "end timeout"], capture_output=True)
    t0 = time.time()
    while running() and time.time() - t0 < 15:
        time.sleep(0.05)
    if running():
        sys.exit("The Logi Plugin Service did not stop; nothing changed.")
    tmp = info_path + ".speedybot-tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, info_path)
    t1 = time.time()
    while not running() and time.time() - t1 < 4:
        time.sleep(0.2)
    if not running():
        subprocess.run(["open", "-g", "-b", "com.logi.pluginservice"])
    print("Removed the Speedy Bot page." if remove else "Added the Speedy Bot page. On the keypad, press > to reach it.")


if __name__ == "__main__":
    main()
