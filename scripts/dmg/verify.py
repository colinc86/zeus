"""Read back the mounted image's actual Finder layout and packaged version."""
import argparse
import json
import plistlib
import re
from pathlib import Path

from ds_store import DSStore
from mac_alias import Alias


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(mount, layout, version, build):
    root = Path(mount)
    expected = json.loads(Path(layout).read_text())
    link = root / "Applications"
    require(link.is_symlink() and str(link.readlink()) == "/Applications", "Applications link is missing or wrong")
    require((root / ".VolumeIcon.icns").is_file(), "Volume icon missing")
    require((root / ".background/background.tiff").is_file(), "Hidden TIFF background missing")
    with (root / "Zeus.app/Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    require(info["CFBundleShortVersionString"] == version and info["CFBundleVersion"] == build, "Packaged version mismatch")
    with DSStore.open(str(root / ".DS_Store"), "r") as store:
        window = store["."]["bwsp"]
        view = store["."]["icvp"]
        require(window["ShowToolbar"] is False and window["ShowSidebar"] is False, "Finder chrome visible")
        require(window["ShowStatusBar"] is False and window["ShowPathbar"] is False, "Finder bars visible")
        require(window["ShowTabView"] is False, "Finder tab bar visible")
        bounds = list(map(int, re.findall(r"-?\d+", window["WindowBounds"])))
        require(bounds == expected["window_origin"] + expected["window_size"], f"Wrong window bounds: {bounds}")
        content_size = [bounds[2], bounds[3] - expected["title_bar_height"]]
        require(content_size == expected["content_size"], f"Wrong content size: {content_size}")
        require(view["iconSize"] == expected["icon_size"] and view["arrangeBy"] == "none", "Wrong icon sizing or arrangement")
        require(view["textSize"] == expected["text_size"] and view["labelOnBottom"] is True,
                "Wrong icon label size or position")
        require(view["showIconPreview"] is False and store["."]["icvl"] == (b"type", b"icnv"), "Wrong Finder view")
        require(view["backgroundType"] == 2 and view["backgroundImageAlias"], "Finder background alias missing")
        alias = Alias.from_bytes(view["backgroundImageAlias"])
        require(alias.target.filename == "background.tiff" and
                alias.target.posix_path.lstrip("/") == ".background/background.tiff",
                "Finder alias points to the wrong background")
        locations = {}
        for name, xy in expected["icon_locations"].items():
            location = store[name]["Iloc"]
            require(list(location[:2]) == xy, f"Wrong position for {name}: {location}")
            locations[name] = list(location[:2])
    print(json.dumps({"version": version, "build": build, "window_bounds": bounds,
                      "content_size": content_size, "title_bar_height": expected["title_bar_height"],
                      "icon_locations": locations, "icon_size": view["iconSize"],
                      "text_size": view["textSize"],
                      "toolbar": False, "sidebar": False, "background": "TIFF", "verified": True}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("mount", "layout", "version", "build"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    verify(args.mount, args.layout, args.version, args.build)
