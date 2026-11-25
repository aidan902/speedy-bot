#!/usr/bin/env python3
"""Puts the Speedy Bot keys on the MX Creative Keypad (Logi Options+), leaving every other page and key alone.

    python3 LogiPlugin/add-keypad-page.py                   add a "Speedy Bot" page to the General profile
    python3 LogiPlugin/add-keypad-page.py --screenconnect   add a ScreenConnect profile: the keypad switches to the
                                                            Speedy Bot keys by itself whenever ScreenConnect is in front
    python3 LogiPlugin/add-keypad-page.py --speedybot       the same while Speedy Bot itself is the app in front
    python3 LogiPlugin/add-keypad-page.py --app BUNDLE_ID "Name"   the same for any app
    python3 LogiPlugin/add-keypad-page.py --migrate         point keys made by older versions at the current commands
    python3 LogiPlugin/add-keypad-page.py --relayout        set every Speedy Bot page on the keypad to the current layout
    python3 LogiPlugin/add-keypad-page.py --remove          take the General profile's Speedy Bot page out again
    python3 LogiPlugin/add-keypad-page.py --remove-screenconnect   take the ScreenConnect profile out again
    python3 LogiPlugin/add-keypad-page.py --remove-speedybot       take the Speedy Bot app profile out again
    python3 LogiPlugin/add-keypad-page.py --remove-app BUNDLE_ID   take an app profile out again
    --icon FILE.png   the icon to show for the app in Logi Options+ (otherwise taken from the installed app)
Several of these can go in one run (for example --migrate --speedybot); the service is restarted once. Anything
else on the command line (a misspelled option, say) stops the script before it changes anything.

Keys, row by row: On | Off | Auto (the current mode's key lights up: green, red, orange); Auto-send on/off | Type
the clipboard into the session (like ⌘⇧V, purple) | Ticket (the incident number); Capture the session window (like
⇧⌘2) | empty | Auto LLM on/off. Needs the Speedy Bot plugin installed (LogiPlugin/build.sh). The keypad is device
Loupedeck70.

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
SB_BUNDLE = "net.fm.speedybot"
P = "$SpeedyBot___Loupedeck.SpeedyBotPlugin."
# Plain commands only: Logi Options+ shows a warning sign instead of the picture of a parameterized command.
# The page, row by row:  On | Off | Auto  /  Auto send | Type (⌘⇧V) | Ticket  /  Capture (⇧⌘2) | - | Auto LLM
# Ticket is a folder: a press opens recent 1 | 2 | 3  /  -  /  Back | New | -  (TicketFolder).
KEYS = [P + "OnCommand", P + "OffCommand", P + "AutoCommand",
        P + "AutoSendCommand", P + "TypeCommand", "$SpeedyBot___#DynamicFolder___DynamicFolder#Loupedeck.SpeedyBotPlugin.TicketFolder",
        P + "CaptureCommand", None, P + "AutoMcpCommand"]
# Keys made by 0.7.1 (one parameterized command) -> the plain commands that replace it.
MIGRATE = {P + "ModeCommand___on": P + "OnCommand", P + "ModeCommand___auto": P + "AutoCommand",
           P + "ModeCommand___off": P + "OffCommand", P + "ModeCommand___multiping": P + "MultiPingCommand"}
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
    """The General profile the keypad uses: the one its ApplicationInfo.json names, else the only one there is."""
    general_dir = os.path.join(DEVICE_DIR, "@_defaultmac")
    try:
        name = json.load(open(os.path.join(general_dir, "ApplicationInfo.json"), encoding="utf-8")).get("defaultProfileName")
    except (OSError, ValueError):
        name = None
    if name and os.path.isfile(os.path.join(general_dir, "Profiles", name, "ProfileInfo.json")):
        return os.path.join(general_dir, "Profiles", name, "ProfileInfo.json")
    found = glob.glob(os.path.join(general_dir, "Profiles", "*", "ProfileInfo.json"))
    if len(found) != 1:
        sys.exit(f"Expected one keypad General profile, found {len(found)}. Is an MX Creative Keypad set up in Logi Options+?")
    return found[0]


def app_icon(bundle, arg_icon):
    """PNG bytes of an app's icon, or None."""
    if arg_icon:
        return open(arg_icon, "rb").read()
    apps = subprocess.run(["mdfind", f'kMDItemCFBundleIdentifier == "{bundle}"'], capture_output=True, text=True).stdout.split("\n")
    for app in filter(None, apps):
        for dirpath, _, files in os.walk(os.path.join(app, "Contents", "Resources")):
            for f in files:
                if f.endswith(".icns"):
                    out = os.path.join(os.path.expanduser("~/Library/Caches/speedy-bot-build"), f"{bundle.lower()}-icon.png")
                    os.makedirs(os.path.dirname(out), exist_ok=True)
                    if subprocess.run(["sips", "-s", "format", "png", "-z", "256", "256", os.path.join(dirpath, f), "--out", out],
                                      capture_output=True).returncode == 0:
                        return open(out, "rb").read()
    return None


def app_files(general, icon, bundle, display):
    """{path: bytes} for a new app profile on the keypad that shows the Speedy Bot keys while that app is in front."""
    app_dir = os.path.join(DEVICE_DIR, bundle.lower())
    profile_name, workspace = guid(), guid()
    profile = {}
    for key in general:   # same keys, same order as a profile the service wrote itself
        profile[key] = None
    profile.update({
        "$type": general["$type"],
        "name": profile_name,
        "profileFlags": "None",
        "displayName": display,
        "description": "",
        "deviceType": DEVICE,
        "applicationName": bundle.lower(),
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
        "name": bundle.lower(),
        "displayName": display,
        "description": None,
        "deviceType": DEVICE,
        "nativePluginName": None,
        "hasNativePlugin": False,
        "processOrBundleName": bundle,
        "modes": [{"$type": T_APPMODE, "name": "main", "parentModeName": None, "displayName": "Main"}],
        "defaultProfileName": profile_name,
        "isEnabled": True,
    }
    files = {
        os.path.join(app_dir, "ApplicationInfo.json"): dump(info).encode(),
        os.path.join(app_dir, "Profiles", profile_name, "ProfileInfo.json"): dump(profile).encode(),
    }
    if icon:
        files[os.path.join(app_dir, "ApplicationIcon.png")] = icon
        files[os.path.join(app_dir, "Profiles", profile_name, "ApplicationIcon.png")] = icon
    return files


def relayout_profiles(pending):
    """{path: bytes} for every keypad profile whose Speedy Bot page differs from the current layout (building on
    what this run is already about to write, in `pending`)."""
    out = {}
    for path in glob.glob(os.path.join(DEVICE_DIR, "*", "Profiles", "*", "ProfileInfo.json")):
        d = json.loads(pending[path].decode()) if path in pending else json.load(open(path, encoding="utf-8"))
        changed = False
        for mode in d["layout"]["layoutModes"]:
            for ws in mode.get("workspaces") or []:
                for page in ws.get("pressPages") or []:
                    if page.get("displayName") != PAGE:
                        continue
                    if [c.get("pressAction") for c in page.get("controls") or []] == KEYS:
                        continue
                    t = (page.get("controls") or [{}])[0].get("$type", T_CONTROL)
                    page["controls"] = [{"$type": t, "controlId": i, "pressAction": a, "rotateAction": None} for i, a in enumerate(KEYS)]
                    changed = True
        if changed:
            names = d.get("additionalNativePluginNames") or []
            if "SpeedyBot" not in names:
                names.append("SpeedyBot")
            d["additionalNativePluginNames"] = names
            d["lastModifiedTimeUtc"] = now_utc()
            out[path] = dump(d).encode()
            print(f"Will lay out the Speedy Bot page in {os.path.relpath(path, DEVICE_DIR).split(os.sep)[0]}")
    return out


def migrated_profiles():
    """{path: bytes} for every keypad profile that still uses keys from an older plugin version."""
    out = {}
    for path in glob.glob(os.path.join(DEVICE_DIR, "*", "Profiles", "*", "ProfileInfo.json")):
        text = open(path, encoding="utf-8").read()
        if not any(old in text for old in MIGRATE):
            continue
        d = json.loads(text)
        changed = 0
        for mode in d["layout"]["layoutModes"]:
            for ws in mode.get("workspaces") or []:
                for kind in ("pressPages", "rotatePages"):
                    for page in ws.get(kind) or []:
                        for c in page.get("controls") or []:
                            if c.get("pressAction") in MIGRATE:
                                c["pressAction"] = MIGRATE[c["pressAction"]]
                                changed += 1
        if changed:
            d["lastModifiedTimeUtc"] = now_utc()
            out[path] = dump(d).encode()
            print(f"Will update {changed} key(s) in {os.path.relpath(path, DEVICE_DIR)}")
    return out


def running():
    return subprocess.run(["pgrep", "-f", PROC], capture_output=True).returncode == 0


def apply_while_stopped(writes, remove_dirs=()):
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
    for d in remove_dirs:
        if os.path.isdir(d):
            shutil.rmtree(d)
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


# Every option and how many values it takes.
OPTIONS = {"--screenconnect": 0, "--speedybot": 0, "--app": 2, "--migrate": 0, "--relayout": 0, "--remove": 0,
           "--remove-screenconnect": 0, "--remove-speedybot": 0, "--remove-app": 1, "--icon": 1}


def parse(argv):
    """{option: [values]}; anything unknown, repeated or missing a value stops the script before it changes anything."""
    opts, i = {}, 0
    while i < len(argv):
        a = argv[i]
        if a in ("-h", "--help"):
            print(__doc__)
            sys.exit(0)
        if a not in OPTIONS:
            sys.exit(f"Unknown option {a!r}; nothing changed. The options are: {', '.join(OPTIONS)}")
        if a in opts:
            sys.exit(f"{a} is given twice; nothing changed. Run the script once per change.")
        n = OPTIONS[a]
        values = argv[i + 1:i + 1 + n]
        if len(values) < n or any(v.startswith("--") for v in values):
            sys.exit(f"{a} needs {n} value(s); nothing changed.")
        opts[a] = values
        i += 1 + n
    return opts


def main():
    args = parse(sys.argv[1:])
    icon_arg = args["--icon"][0] if "--icon" in args else None
    writes, removes, done = {}, [], []

    for flag in ("--remove-screenconnect", "--remove-speedybot", "--remove-app"):
        if flag in args:
            bundle = {"--remove-screenconnect": SC_BUNDLE, "--remove-speedybot": SB_BUNDLE}.get(flag) or args[flag][0]
            d = os.path.normpath(os.path.join(DEVICE_DIR, bundle.lower()))
            if not bundle.strip(". /") or os.path.dirname(os.path.normpath(d)) != DEVICE_DIR or bundle.startswith("@"):
                sys.exit(f"{bundle!r} is not an app's bundle id; nothing changed.")
            if not os.path.isdir(d):
                sys.exit(f"There is no keypad profile for {bundle}; nothing changed.")
            removes.append(d)
            done.append(f"Removed the keypad profile for {bundle}.")

    apps = []
    if "--screenconnect" in args:
        apps.append((SC_BUNDLE, "ScreenConnect"))
    if "--speedybot" in args:
        apps.append((SB_BUNDLE, "Speedy Bot"))
    if "--app" in args:
        apps.append(tuple(args["--app"]))
    wants_general = not apps and not removes and "--migrate" not in args and "--relayout" not in args or "--remove" in args
    if (apps or wants_general) and "--remove" not in args and not os.path.isdir(os.path.join(ROOT, "Plugins", "SpeedyBot")):
        sys.exit("The Speedy Bot plugin is not installed. Run LogiPlugin/build.sh first.")

    # The General profile is only needed to change its page, or as the model for a new app profile.
    general_path = general_profile_path() if apps or wants_general else None
    general = json.load(open(general_path, encoding="utf-8")) if general_path else None

    if "--migrate" in args:
        writes.update(migrated_profiles())
        done.append("Pointed the older Speedy Bot keys at the current commands." if writes else "No keys needed updating.")
    if "--relayout" in args:
        laid = relayout_profiles(writes)
        writes.update(laid)
        done.append(f"Laid out {len(laid)} Speedy Bot page(s) with the current keys." if laid else "Every Speedy Bot page already has the current keys.")

    for bundle, display in apps:
        if os.path.isdir(os.path.join(DEVICE_DIR, bundle.lower())):
            sys.exit(f"The keypad already has a profile for {bundle}; nothing changed.")
        icon = app_icon(bundle, icon_arg if len(apps) == 1 else None)
        if bundle == SB_BUNDLE and not icon:
            here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "metadata", "Icon256x256.png")
            icon = open(here, "rb").read() if os.path.exists(here) else None
        writes.update(app_files(general, icon, bundle, display))
        done.append(f"Added a {display} profile: the keypad shows the Speedy Bot keys whenever {display} is in front.")

    if wants_general:
        if general_path in writes:   # already migrated in this run: build on that
            general = json.loads(writes[general_path].decode())
        pages = general["layout"]["layoutModes"][0]["workspaces"][0]["pressPages"]
        has = any(p.get("displayName") == PAGE for p in pages)
        if "--remove" in args:
            if not has:
                sys.exit("There is no Speedy Bot page; nothing changed.")
            general["layout"]["layoutModes"][0]["workspaces"][0]["pressPages"] = [p for p in pages if p.get("displayName") != PAGE]
            done.append("Removed the Speedy Bot page.")
        else:
            if has:
                sys.exit("The keypad already has a Speedy Bot page; nothing changed.")
            pages.append(speedy_page())
            names = general.get("additionalNativePluginNames") or []
            if "SpeedyBot" not in names:
                names.append("SpeedyBot")
            general["additionalNativePluginNames"] = names
            done.append("Added the Speedy Bot page. On the keypad, press > to reach it.")
        general["lastModifiedTimeUtc"] = now_utc()
        writes[general_path] = dump(general).encode()

    # A profile removed in this run is not written back (that would leave half a profile behind).
    writes = {p: b for p, b in writes.items() if not any(p.startswith(d + os.sep) for d in removes)}
    if not writes and not removes:
        print("\n".join(done) or "Nothing to do.")
        return
    apply_while_stopped(writes, removes)
    print("\n".join(done))


if __name__ == "__main__":
    main()
