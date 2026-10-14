"""Build a Finder-independent DMG; layout/art paths are the D17 integration seam."""
import argparse
import json
import plistlib
import subprocess
from pathlib import Path

import dmgbuild
from ds_store import DSStore
from mac_alias import Alias


def run(*args):
    subprocess.run(args, check=True)


def load_layout(path):
    layout = json.loads(Path(path).read_text())
    for key in ("window_origin", "window_size", "content_size"):
        if len(layout[key]) != 2 or not all(isinstance(n, int) for n in layout[key]):
            raise ValueError(f"{key} must contain two integers")
    width, height = layout["content_size"]
    if width <= 0 or height <= 0 or not 1 <= layout["icon_size"] <= 128:
        raise ValueError("Invalid window or icon size")
    if layout["title_bar_height"] < 0 or layout["window_size"] != [width, height + layout["title_bar_height"]]:
        raise ValueError("Window frame must equal content size plus the title bar")
    if not 1 <= layout["text_size"] <= 32:
        raise ValueError("Invalid label text size")
    if set(layout["icon_locations"]) != {"Zeus.app", "Applications"}:
        raise ValueError("Layout must place Zeus.app and Applications")
    for name, xy in layout["icon_locations"].items():
        if len(xy) != 2 or not (0 <= xy[0] < width and 0 <= xy[1] < height):
            raise ValueError(f"{name} position is outside the window")
    for key in ("background_1x", "background_2x", "volume_icon"):
        name = Path(layout[key])
        if name.is_absolute() or ".." in name.parts:
            raise ValueError(f"{key} must be relative to the art directory")
    return layout


def build(args):
    layout = load_layout(args.layout)
    work = Path(args.work).resolve()
    work.mkdir(parents=True, exist_ok=True)
    app = Path(args.app).resolve()
    art = Path(args.art_dir).resolve()
    images = [art / layout[key] for key in ("background_1x", "background_2x")]
    icon = art / layout["volume_icon"]
    placeholder = not all(p.is_file() for p in [*images, icon])
    if placeholder:
        if any(p.is_file() for p in [*images, icon]) or (art / "LAYOUT.md").exists():
            raise ValueError("Incomplete D17 art: update layout.json filenames to match LAYOUT.md")
        print("D17 art absent: generating placeholder background and using the app volume icon", flush=True)
        run("xcrun", "swift", str(Path(__file__).with_name("placeholder.swift")), str(work),
            *map(str, layout["content_size"]))
        images = [work / "background.png", work / "background@2x.png"]
        with (app / "Contents/Info.plist").open("rb") as stream:
            icon_name = plistlib.load(stream)["CFBundleIconFile"]
        icon = app / "Contents/Resources" / (icon_name if icon_name.endswith(".icns") else icon_name + ".icns")
    for scale, image in enumerate(images, 1):
        result = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(image)], check=True, capture_output=True, text=True)
        dimensions = {line.strip().split(": ")[0]: int(line.strip().split(": ")[1])
                      for line in result.stdout.splitlines() if line.strip().startswith(("pixelWidth:", "pixelHeight:"))}
        if (dimensions["pixelWidth"], dimensions["pixelHeight"]) != tuple(n * scale for n in layout["content_size"]):
            raise ValueError(f"{image} must be {scale}x the content size")
        run("sips", "-s", "dpiWidth", str(72 * scale), "-s", "dpiHeight", str(72 * scale),
            "-s", "format", "tiff", str(image), "--out", str(work / ("background.tiff" if scale == 1 else "background@2x.tiff")))
    background = work / "background-multi.tiff"
    run("tiffutil", "-cathidpicheck", str(work / "background.tiff"), str(work / "background@2x.tiff"), "-out", str(background))
    settings = {
        "format": "UDZO", "filesystem": "HFS+", "compression_level": 9,
        "files": [str(app)], "symlinks": {"Applications": "/Applications"},
        # SetFile's hide-extension bit adds FinderInfo to the signed app and
        # makes strict codesign verification fail. Never mutate app metadata.
        "hide": [".VolumeIcon.icns"], "hide_extensions": [],
        "icon": str(icon), "background": str(background),
        "icon_locations": {name: tuple(xy) for name, xy in layout["icon_locations"].items()},
        "window_rect": (tuple(layout["window_origin"]), tuple(layout["window_size"])),
        "show_toolbar": False, "show_sidebar": False, "show_status_bar": False,
        "show_tab_view": False, "show_pathbar": False,
        "default_view": "icon-view", "include_icon_view_settings": True,
        "include_list_view_settings": False, "arrange_by": None, "grid_spacing": 80,
        "icon_size": layout["icon_size"], "text_size": layout["text_size"], "label_pos": "bottom",
        "scroll_position": (0, 0),
    }
    (work / "layout-used.json").write_text(json.dumps({**layout, "placeholder": placeholder}, indent=2) + "\n")
    mount = None

    def finish_layout(event):
        nonlocal mount
        if event["type"] == "command::finished" and event.get("command") == "hdiutil::attach" and event["ret"] == 0:
            mount = next(Path(item["mount-point"]) for item in event["output"]["system-entities"] if "mount-point" in item)
        if event["type"] == "operation::finished" and event.get("operation") == "dsstore::create":
            # dmgbuild 1.6.7 places a hidden TIFF at the root. Relocate it before
            # compression and replace its Finder alias to use the requested folder.
            folder = mount / ".background"
            folder.mkdir()
            target = folder / "background.tiff"
            (mount / ".background.tiff").rename(target)
            run("/usr/bin/SetFile", "-a", "V", str(folder))
            with DSStore.open(str(mount / ".DS_Store"), "r+") as store:
                view = store["."]["icvp"]
                view["backgroundImageAlias"] = Alias.for_file(str(target)).to_bytes()
                store["."]["icvp"] = view

    dmgbuild.build_dmg(str(Path(args.output).resolve()), "Zeus", settings=settings,
                       lookForHiDPI=False, callback=finish_layout)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("app", "output", "work", "layout", "art-dir"):
        parser.add_argument("--" + name, required=True)
    build(parser.parse_args())
