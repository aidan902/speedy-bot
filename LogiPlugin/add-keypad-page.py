#!/usr/bin/env python3
"""Puts the Speedy Bot keys on the MX Creative Keypad (Logi Options+), leaving every other page and key alone.

    python3 LogiPlugin/add-keypad-page.py                   add a "Speedy Bot" page to the General profile
    python3 LogiPlugin/add-keypad-page.py --screenconnect   add a ScreenConnect profile: the keypad switches to the
                                                            Speedy Bot keys by itself whenever ScreenConnect is in front
    python3 LogiPlugin/add-keypad-page.py --remove          take the General profile's Speedy Bot page out again
    python3 LogiPlugin/add-keypad-page.py --remove-screenconnect   take the ScreenConnect profile out again
    --icon FILE.png   the ScreenConnect icon to show in Logi Options+ (otherwise taken from the installed app)

Keys: On/Off (shows the live state), On, Auto, Off, Multi Ping. Needs the Speedy Bot plugin installed
(LogiPlugin/build.sh). The keypad is device Loupedeck70.

The ScreenConnect profile is written the way the plugin service's own CreateNewApplicationProfile makes one for an
app without a Logitech plugin: folder = the bundle id in lower case, no native plugin, processOrBundleName = the
bundle id (what the service matches the app in front against), one mode "main"/"Main". The service saves profiles
when it quits, so files are written while it is stopped; Logi Options+ starts it again straight away. A backup of
the keypad's profiles is made in ~/Library/Caches/speedy-bot-build first.
"""
import datetime, glob, json, os, shutil, subprocess, sys, time, uuid

ROOT = os.path.expanduser("~/Library/Application Support/Logi/LogiPluginService")
DEVICE = "Loupedeck70"   # MX Creative Keypad
DEVICE_DIR = os.path.join(ROOT, "Applications", DEVICE)
PROC = "LogiPluginService.app/Contents/MacOS/LogiPluginService"
SC_BUNDLE = "com.screenconnect.client"
SC_DIR = os.path.join(DEVICE_DIR, SC_BUNDLE.lower())
P = "$SpeedyBot___Loupedeck.SpeedyBotPlugin."
KEYS = [P + "ToggleCommand", P + "ModeCommand___on", P + "ModeCommand___auto", P + "ModeCommand___off",
        P + "ModeCommand___multiping", None, None, None, None]
PAGE = "Speedy Bot"
T_PAGE = "Loupedeck.Service.Devices.Loupedeck7Devices.ProfileLayoutPage7, LoupedeckService"
T_CONTROL = "Loupedeck.Service.Devices.Loupedeck7Devices.ProfileLayoutControl7, LoupedeckService"
T_WORKSPACE = "Loupedeck.Service.Devices.Loupedeck7Devices.ProfileLayoutWorkspace7, LoupedeckService"
T_MODE = "Loupedeck.Service.Devices.Loupedeck7Devices.ProfileLayoutMode7, LoupedeckService"
T_LAYOUT = "Loupedeck.Service.Devices.Loupedeck7Devices.ProfileLayout7, LoupedeckService"
T_APPMODE = "Loupedeck.Service.ApplicationMode, LoupedeckService"


def guid():
    return uuid.uuid4().hex.upper()


def now_utc():
    n = datetime.datetime.now(datetime.timezone.utc)
    return n.strftime("%Y-%m-%dT%H:%M:%S.") + f"{n.microsecond:06d}Z"


def dump(obj, indent=4):
    text = json.dumps(obj, indent=indent, ensure_ascii=False) + "\n"
    json.loads(text)
    return text


def speedy_page():
    return {"$type": T_PAGE, "name": guid(), "displayName": PAGE, "description": None,
            "controls": [{"$type": T_CONTROL, "controlId": i, "pressAction": a, "rotateAction": None} for i, a in enumerate(KEYS)]}


def general_profile_path():
    found = glob.glob(os.path.join(DEVICE_DIR, "@_defaultmac", "Profiles", "*", "ProfileInfo.json"))
    if len(found) != 1:
        sys.exit(f"Expected one keypad General profile, found {len(found)}. Is an MX Creative Keypad set up in Logi Options+?")
    return found[0]


def screenconnect_icon(arg_icon):
    """PNG bytes of ScreenConnect's icon, or None."""
    if arg_icon:
        return open(arg_icon, "rb").read()
    apps = subprocess.run(["mdfind", f'kMDItemCFBundleIdentifier == "{SC_BUNDLE}"'], capture_output=True, text=True).stdout.split("\n")
    for app in filter(None, apps):
        for dirpath, _, files in os.walk(os.path.join(app, "Contents", "Resources")):
            for f in files:
                if f.endswith(".icns"):
                    out = os.path.join(os.path.expanduser("~/Library/Caches/speedy-bot-build"), "screenconnect-icon.png")
                    os.makedirs(os.path.dirname(out), exist_ok=True)
                    if subprocess.run(["sips", "-s", "format", "png", "-z", "256", "256", os.path.join(dirpath, f), "--out", out],
                                      capture_output=True).returncode == 0:
                        return open(out, "rb").read()
    return None


def screenconnect_files(general, icon):
    """{path: bytes} for a new ScreenConnect app profile on the keypad."""
    profile_name, workspace = guid(), guid()
    profile = {}
    for key in general:   # same keys, same order as a profile the service wrote itself
        profile[key] = None
    profile.update({
        "$type": general["$type"],
        "name": profile_name,
        "profileFlags": "None",
        "displayName": "ScreenConnect",
        "description": "",
        "deviceType": DEVICE,
        "applicationName": SC_BUNDLE.lower(),
        "nativePluginName": None,
        "hasNativePlugin": False,
        "additionalNativePluginNames": ["DefaultMac", "SpeedyBot"],
        "lastModifiedTimeUtc": now_utc(),
        "profileSettings": {"$type": general["profileSettings"]["$type"]},
        "actionImages90": None, "actionImages60": None, "wheelImages": None, "actionColors": None,
        "layout": {
            "$type": T_LAYOUT, "deviceType": DEVICE, "profileFlags": "None",
            "layoutModes": [{
                "$type": T_MODE, "deviceType": DEVICE, "modeName": "main", "parentModeName": None,
                "actions": None, "dynamicButtonPages": None, "dynamicEncoderPages": None,
                "workspaces": [{"$type": T_WORKSPACE, "name": workspace, "displayName": "Workspace 1", "description": None,
                                "pressPages": [speedy_page()], "rotatePages": []}],
                "homeWorkspaceName": workspace,
            }],
            "folderPages": [],
        },
        "macroCommands": [], "macroAdjustments": [], "profileCommands": [], "profileAdjustments": [],
        "conversionHistory": None, "packageName": None, "packageVersion": None, "profileActions": [],
    })
    info = {
        "$type": "Loupedeck.Service.SupportedApplicationInfo, LoupedeckService",
        "name": SC_BUNDLE.lower(),
        "displayName": "ScreenConnect",
        "description": None,
        "deviceType": DEVICE,
        "nativePluginName": None,
        "hasNativePlugin": False,
        "processOrBundleName": SC_BUNDLE,
        "modes": [{"$type": T_APPMODE, "name": "main", "parentModeName": None, "displayName": "Main"}],
        "defaultProfileName": profile_name,
        "isEnabled": True,
    }
    files = {
        os.path.join(SC_DIR, "ApplicationInfo.json"): dump(info).encode(),
        os.path.join(SC_DIR, "Profiles", profile_name, "ProfileInfo.json"): dump(profile).encode(),
    }
    if icon:
        files[os.path.join(SC_DIR, "ApplicationIcon.png")] = icon
        files[os.path.join(SC_DIR, "Profiles", profile_name, "ApplicationIcon.png")] = icon
    return files


def running():
    return subprocess.run(["pgrep", "-f", PROC], capture_output=True).returncode == 0


def apply_while_stopped(writes, remove_dir=None):
    """Writes {path: bytes} (and/or removes a folder) while the plugin service is stopped, then lets it start."""
    backup = os.path.expanduser("~/Library/Caches/speedy-bot-build/logi-profile-backup-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    shutil.copytree(DEVICE_DIR, backup)
    print("Backed up the keypad's profiles to", backup)
    subprocess.run(["osascript", "-e", "with timeout of 15 seconds", "-e", 'tell application id "com.logi.pluginservice" to quit', "-e", "end timeout"], capture_output=True)
    t0 = time.time()
    while running() and time.time() - t0 < 15:
        time.sleep(0.05)
    if running():
        sys.exit("The Logi Plugin Service did not stop; nothing changed.")
    if remove_dir and os.path.isdir(remove_dir):
        shutil.rmtree(remove_dir)
    for path, data in writes.items():
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".speedybot-tmp"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
    t1 = time.time()
    while not running() and time.time() - t1 < 4:
        time.sleep(0.2)
    if not running():
        subprocess.run(["open", "-g", "-b", "com.logi.pluginservice"])


def main():
    args = sys.argv[1:]
    icon_arg = args[args.index("--icon") + 1] if "--icon" in args else None
    if "--remove-screenconnect" in args:
        if not os.path.isdir(SC_DIR):
            sys.exit("There is no ScreenConnect profile on the keypad; nothing changed.")
        apply_while_stopped({}, remove_dir=SC_DIR)
        print("Removed the keypad's ScreenConnect profile.")
        return
    if not os.path.isdir(os.path.join(ROOT, "Plugins", "SpeedyBot")) and "--remove" not in args:
        sys.exit("The Speedy Bot plugin is not installed. Run LogiPlugin/build.sh first.")
    general_path = general_profile_path()
    general = json.load(open(general_path, encoding="utf-8"))

    if "--screenconnect" in args:
        if os.path.isdir(SC_DIR):
            sys.exit("The keypad already has a ScreenConnect profile; nothing changed. (--remove-screenconnect takes it out.)")
        apply_while_stopped(screenconnect_files(general, screenconnect_icon(icon_arg)))
        print("Added a ScreenConnect profile: the keypad shows the Speedy Bot keys whenever ScreenConnect is in front.")
        return

    pages = general["layout"]["layoutModes"][0]["workspaces"][0]["pressPages"]
    has = any(p.get("displayName") == PAGE for p in pages)
    if "--remove" in args:
        if not has:
            sys.exit("There is no Speedy Bot page; nothing changed.")
        general["layout"]["layoutModes"][0]["workspaces"][0]["pressPages"] = [p for p in pages if p.get("displayName") != PAGE]
    else:
        if has:
            sys.exit("The keypad already has a Speedy Bot page; nothing changed.")
        pages.append(speedy_page())
        names = general.get("additionalNativePluginNames") or []
        if "SpeedyBot" not in names:
            names.append("SpeedyBot")
        general["additionalNativePluginNames"] = names
    general["lastModifiedTimeUtc"] = now_utc()
    apply_while_stopped({general_path: dump(general).encode()})
    print("Removed the Speedy Bot page." if "--remove" in args else "Added the Speedy Bot page. On the keypad, press > to reach it.")


if __name__ == "__main__":
    main()
