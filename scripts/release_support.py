#!/usr/bin/env python3
"""Local Sparkle preparation and explicit, resumable GitHub publication for Zeus."""
import argparse
import base64
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import appcast

REPO = "colinc86/zeus"
FEED_URL = "https://raw.githubusercontent.com/colinc86/zeus/main/appcast.xml"


def run(arguments, *, cwd, input=None, check=True):
    result = subprocess.run([str(argument) for argument in arguments], cwd=cwd, input=input,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode:
        # Signing-tool diagnostics are deliberately not echoed. Only public-key
        # printing and archive signing are permitted; no key-export operation exists.
        raise ValueError(f"{Path(str(arguments[0])).name} {arguments[1]} failed; check setup or connectivity")
    return result


def project_version(project):
    values = []
    for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
        matches = re.findall(rf"^\s*{key}:\s*([^\n#]+)", Path(project).read_text(encoding="utf-8"), re.MULTILINE)
        if len(matches) != 1:
            raise ValueError(f"project.yml must define {key} exactly once")
        values.append(matches[0].strip().strip("\"'"))
    appcast.validate_version(*values)
    return tuple(values)


def sparkle_tools(root):
    # Only this checkout's package artifacts are eligible, never another app's
    # DerivedData or a user's global Library directory.
    for relative in ("build/release/SourcePackages", "build/release/DerivedData/SourcePackages",
                     "build/SourcePackages", "build/DerivedData/SourcePackages"):
        directory = root / relative
        for executable in sorted(directory.glob("artifacts/**/sign_update")):
            public = executable.with_name("generate_keys")
            if os.access(executable, os.X_OK) and os.access(public, os.X_OK):
                if executable.resolve().is_relative_to(root.resolve() / "build"):
                    return executable, public
    raise ValueError("Sparkle tools missing from this checkout's build/ SourcePackages artifacts; build the app with Sparkle integrated to resolve the package first")


def digest(path):
    checksum = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def save_json(path, data):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def sign_archive(root, notarized):
    release = root / "build/release"
    version, build = project_version(root / "project.yml")
    appcast.check_build(root / "appcast.xml", version, build)
    app = release / "Zeus.app"
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if (info.get("CFBundleShortVersionString"), str(info.get("CFBundleVersion"))) != (version, build):
        raise ValueError("built app version/build differs from project.yml")
    sign, generate = sparkle_tools(root)
    public = run([generate, "--account", "zeus", "-p"], cwd=root, check=False)
    if public.returncode:
        raise ValueError("Sparkle account 'zeus' has no signing key; run generate_keys --account zeus interactively (private key stays in Keychain)")
    key = public.stdout.strip()
    try:
        valid_key = len(base64.b64decode(key, validate=True)) == 32
    except ValueError:
        valid_key = False
    if not valid_key or info.get("SUPublicEDKey") != key:
        raise ValueError("Zeus.app SUPublicEDKey does not match generate_keys --account zeus -p; set the matching public key in project.yml and rebuild")
    if info.get("SUFeedURL") != FEED_URL:
        raise ValueError(f"Zeus.app SUFeedURL must be {FEED_URL}")
    archive = release / f"Zeus-{version}.zip"
    if not archive.is_file():
        raise ValueError("Sparkle ZIP is missing")
    signature = run([sign, "--account", "zeus", archive], cwd=root).stdout.strip()
    _, length = appcast.signature_fields(signature)
    if length != archive.stat().st_size:
        raise ValueError("sign_update length differs from the actual ZIP")
    (release / "signature.txt").write_text(signature + "\n", encoding="utf-8")
    assets = [f"Zeus-{version}.dmg", archive.name]
    metadata = {"version": version, "build": build, "notarized": notarized,
                "commit": run(["git", "rev-parse", "HEAD"], cwd=root).stdout.strip(),
                "signature": signature, "assets": {name: digest(release / name) for name in assets}}
    save_json(release / "publish.json", metadata)


def git_ready(root, resume):
    if run(["git", "branch", "--show-current"], cwd=root).stdout.strip() != "main":
        raise ValueError("--publish requires main; local builds are allowed on task branches")
    status = run(["git", "status", "--porcelain"], cwd=root).stdout.splitlines()
    if any(not (resume and line[3:] == "appcast.xml") for line in status):
        raise ValueError("--publish requires a clean main (resume permits only an interrupted appcast.xml change)")
    origin = run(["git", "remote", "get-url", "origin"], cwd=root).stdout.strip()
    if origin not in (f"https://github.com/{REPO}", f"https://github.com/{REPO}.git", f"git@github.com:{REPO}.git", f"ssh://git@github.com/{REPO}.git"):
        raise ValueError(f"origin must be the public GitHub repository {REPO}")


def preflight(root, resume, notes):
    if not notes.is_file() or not notes.read_text(encoding="utf-8").strip():
        raise ValueError("--publish requires a nonempty Markdown notes file")
    if not resume and notes.resolve().is_relative_to(root / "build/release"):
        raise ValueError("put notes outside build/release/; that directory is recreated for a new release")
    git_ready(root, resume)
    version, build = project_version(root / "project.yml")
    appcast.check_build(root / "appcast.xml", version, build, allow_existing=resume)
    if not resume and run(["git", "rev-parse", "--verify", f"refs/tags/v{version}"], cwd=root, check=False).returncode == 0:
        raise ValueError(f"tag v{version} exists; use --publish NOTES --resume with its saved artifacts")


def publish(root, notes, resume):
    preflight(root, resume, notes)
    release = root / "build/release"
    try:
        metadata = json.loads((release / "publish.json").read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError) as error:
        raise ValueError("no saved publish.json; build and notarize this release before publishing") from error
    version, build = project_version(root / "project.yml")
    if (metadata["version"], metadata["build"]) != (version, build) or metadata["notarized"] is not True:
        raise ValueError("saved artifacts must be notarized and match project.yml; --no-notarize cannot publish")
    expected_assets = [f"Zeus-{version}.dmg", f"Zeus-{version}.zip"]
    if set(metadata["assets"]) != set(expected_assets):
        raise ValueError("saved manifest must contain exactly the DMG and ZIP")
    for name, checksum in metadata["assets"].items():
        if digest(release / name) != checksum:
            raise ValueError(f"saved artifact changed: {name}; do not resume with different bytes")
    _, length = appcast.signature_fields(metadata["signature"])
    if length != (release / expected_assets[1]).stat().st_size:
        raise ValueError("saved Sparkle signature length differs from the ZIP")
    # Only the appcast commit may follow the source revision used for these bytes.
    source = metadata["commit"]
    run(["git", "merge-base", "--is-ancestor", source, "HEAD"], cwd=root)
    changed = run(["git", "diff", "--name-only", source, "HEAD"], cwd=root).stdout.splitlines()
    if any(path != "appcast.xml" for path in changed):
        raise ValueError("source changed since packaging; resume from the original release revision")
    notes_text = notes.read_text(encoding="utf-8")
    saved_notes = release / "notes.md"
    if saved_notes.exists() and saved_notes.read_text(encoding="utf-8") != notes_text:
        raise ValueError("notes changed since publishing started; resume with the original notes")
    saved_notes.write_text(notes_text, encoding="utf-8")
    # Nothing above this point contacts GitHub or changes tags.
    run(["gh", "auth", "status"], cwd=root)
    run(["git", "fetch", "origin", "main"], cwd=root)
    if run(["git", "merge-base", "--is-ancestor", "origin/main", "HEAD"], cwd=root, check=False).returncode:
        raise ValueError("origin/main advanced; update clean main before publishing/resuming")
    tag = f"v{version}"
    existing_tag = run(["git", "rev-parse", "--verify", f"refs/tags/{tag}^{{}}"], cwd=root, check=False)
    if existing_tag.returncode == 0:
        if existing_tag.stdout.strip() != source:
            raise ValueError(f"tag {tag} points to a different revision")
    else:
        run(["git", "tag", tag, source], cwd=root)
    run(["git", "push", "origin", f"refs/tags/{tag}"], cwd=root)
    endpoint = f"repos/{REPO}/releases/tags/{tag}"
    response = run(["gh", "api", endpoint], cwd=root, check=False)
    if response.returncode:
        if "HTTP 404" not in response.stderr:
            raise ValueError("cannot query the GitHub release; resume when GitHub is reachable")
        command = ["gh", "release", "create", tag, *[release / name for name in expected_assets], "--repo", REPO,
                   "--title", f"Zeus {version}", "--notes-file", saved_notes, "--verify-tag"]
        if "-beta." in version:
            command.append("--prerelease")
        run(command, cwd=root)
        response = run(["gh", "api", endpoint], cwd=root)
    remote = json.loads(response.stdout)
    if remote["tag_name"] != tag or remote["draft"] or remote["prerelease"] != ("-beta." in version):
        raise ValueError("existing GitHub release has the wrong tag, draft state or prerelease flag")
    if (remote.get("body") or "").strip() != notes_text.strip():
        raise ValueError("existing GitHub release notes differ from the saved notes")
    present = {asset["name"] for asset in remote["assets"]}
    missing = [release / name for name in expected_assets if name not in present]
    if missing:
        run(["gh", "release", "upload", tag, *missing, "--repo", REPO], cwd=root)
        remote = json.loads(run(["gh", "api", endpoint], cwd=root).stdout)
    # Verify existing uploads as well as new uploads, without overwriting assets.
    with tempfile.TemporaryDirectory(prefix="zeus-release-") as directory:
        for name in expected_assets:
            run(["gh", "release", "download", tag, "--repo", REPO, "--pattern", name, "--dir", directory], cwd=root)
            if digest(Path(directory) / name) != metadata["assets"][name]:
                raise ValueError(f"GitHub asset differs from the signed local artifact: {name}")
    archive = next(asset for asset in remote["assets"] if asset["name"] == expected_assets[1])
    url = archive["browser_download_url"]
    if archive["size"] != length:
        raise ValueError("GitHub ZIP size differs from the signed archive")
    html = release / "notes.html"
    if not html.exists():
        result = run(["gh", "api", "markdown", "--input", "-"], cwd=root,
                     input=json.dumps({"mode": "gfm", "context": REPO, "text": notes_text}))
        html.write_text(result.stdout, encoding="utf-8")
    run([sys.executable, "-B", root / "scripts/appcast.py", root / "appcast.xml", "--version", version, "--build", build,
         "--url", url, "--signature", metadata["signature"], "--notes", html], cwd=root)
    if run(["git", "diff", "--quiet", "HEAD", "--", "appcast.xml"], cwd=root, check=False).returncode:
        run(["git", "add", "--", "appcast.xml"], cwd=root)
        run(["git", "commit", "-m", f"Publish {version} in the appcast", "--", "appcast.xml"], cwd=root)
    run(["git", "push", "origin", "HEAD:refs/heads/main"], cwd=root)
    print(f"Published Zeus {version}: https://github.com/{REPO}/releases/tag/{tag}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("version", "sign", "preflight", "publish"))
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--field", choices=("version", "build"))
    parser.add_argument("--notarized", action="store_true")
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--notes", type=Path)
    args = parser.parse_args()
    try:
        root = args.root.resolve()
        if args.command == "version":
            version, build = project_version(root / "project.yml")
            print(version if args.field == "version" else build if args.field == "build" else f"{version}\n{build}")
        elif args.command == "sign":
            sign_archive(root, args.notarized)
        else:
            if args.notes is None:
                parser.error("--notes is required")
            if args.command == "preflight":
                preflight(root, args.resume, args.notes.resolve())
            else:
                publish(root, args.notes.resolve(), args.resume)
    except (ValueError, OSError, KeyError) as error:
        parser.exit(1, f"release: {error}\n")


if __name__ == "__main__":
    main()
