#!/usr/bin/env python3
"""Add a signed Zeus update to the Sparkle feed, atomically and newest first."""
import argparse
import base64
import email.utils
import re
from pathlib import Path
from xml.dom import minidom
from xml.parsers.expat import ExpatError
from xml.sax.saxutils import escape, quoteattr

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
HEADER = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE}">
  <channel>
    <title>Zeus</title>
    <link>https://github.com/colinc86/zeus</link>
    <description>Zeus releases</description>
    <language>en</language>
  </channel>
</rss>
'''
STYLE = '''<style>
:root { color-scheme: light dark; }
body { font: 13px -apple-system, system-ui, sans-serif; line-height: 1.45; margin: 0 4px; }
h1, h2, h3 { font-size: 1.05em; margin: 1em 0 .4em; }
ul, ol { padding-left: 1.4em; }
code { font: 12px ui-monospace, SF Mono, Menlo, monospace; }
a { color: -apple-system-control-accent; }
</style>
'''


def validate_version(version, build):
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-beta\.[1-9]\d*)?", version):
        raise ValueError("version must look like 0.1.4 or 0.1.5-beta.1")
    if not re.fullmatch(r"[1-9]\d*", str(build)):
        raise ValueError("build must be a positive integer")


def signature_fields(output):
    signature = re.search(r'sparkle:edSignature="([^"]+)"', output)
    length = re.search(r'length="([1-9]\d*)"', output)
    if not signature or not length:
        raise ValueError("cannot read sign_update's signature and length")
    try:
        decoded = base64.b64decode(signature[1], validate=True)
    except ValueError as error:
        raise ValueError("invalid EdDSA signature") from error
    if len(decoded) != 64:
        raise ValueError("EdDSA signature must contain 64 bytes")
    return signature[1], int(length[1])


def text(node, namespace, name):
    elements = node.getElementsByTagNameNS(namespace, name)
    if len(elements) != 1:
        raise ValueError(f"appcast item must have exactly one {name}")
    return "".join(child.data for child in elements[0].childNodes if child.nodeType == child.TEXT_NODE)


def read_feed(path):
    source = path.read_text(encoding="utf-8") if path.exists() else HEADER
    document = minidom.parseString(source)
    if document.documentElement.tagName != "rss":
        raise ValueError("feed must be RSS")
    channels = document.documentElement.getElementsByTagName("channel")
    if len(channels) != 1:
        raise ValueError("feed must have exactly one channel")
    channel = channels[0]
    items = [node for node in channel.childNodes if node.nodeType == node.ELEMENT_NODE and node.tagName == "item"]
    builds = [int(text(item, SPARKLE, "version")) for item in items]
    if any(build <= 0 for build in builds) or len(set(builds)) != len(builds):
        raise ValueError("feed has invalid or duplicate build numbers")
    return document, channel, items, builds


def check_build(path, version, build, allow_existing=False):
    validate_version(version, build)
    _, _, items, builds = read_feed(Path(path))
    versions = [text(item, SPARKLE, "shortVersionString") for item in items]
    if version in versions:
        index = versions.index(version)
        if allow_existing and builds[index] == int(build):
            return
        raise ValueError(f"version {version} is already in the appcast")
    if builds and int(build) <= max(builds):
        raise ValueError(f"build {build} must strictly exceed newest appcast build {max(builds)}")


def update_feed(path, version, build, url, signature, notes):
    path = Path(path)
    check_build(path, version, build, allow_existing=True)
    sig, length = signature_fields(signature)
    if url != f"https://github.com/colinc86/zeus/releases/download/v{version}/Zeus-{version}.zip":
        raise ValueError("enclosure must use this ZIP's public GitHub release-asset download URL")
    document, channel, items, _ = read_feed(path)
    html = STYLE + notes
    for old in items:
        if text(old, SPARKLE, "shortVersionString") == version:
            enclosure = old.getElementsByTagName("enclosure")
            description = old.getElementsByTagName("description")
            if len(enclosure) != 1 or len(description) != 1:
                raise ValueError("existing release is incomplete")
            old_notes = "".join(child.data for child in description[0].childNodes
                                if child.nodeType == child.CDATA_SECTION_NODE
                                or (child.nodeType == child.TEXT_NODE and child.data.strip()))
            node = enclosure[0]
            if (node.getAttribute("url"), node.getAttributeNS(SPARKLE, "edSignature"), node.getAttribute("length"), old_notes) != (url, sig, str(length), html):
                raise ValueError("existing release differs; refusing to replace its archive or notes")
            return False
    safe_html = html.replace("]]>", "]]]]><![CDATA[>")
    item_xml = f'''<item xmlns:sparkle="{SPARKLE}">
      <title>Zeus {escape(version)}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <description><![CDATA[{safe_html}]]></description>
      <enclosure url={quoteattr(url)} type="application/octet-stream" sparkle:edSignature={quoteattr(sig)} length="{length}"/>
    </item>'''
    new_item = document.importNode(minidom.parseString(item_xml).documentElement, True)
    channel.appendChild(new_item)
    # Reorder item elements without discarding historical CDATA/unknown fields.
    ordered = sorted(items + [new_item], key=lambda node: int(text(node, SPARKLE, "version")), reverse=True)
    for item in ordered:
        channel.removeChild(item)
    for node in list(channel.childNodes):
        if node.nodeType == node.TEXT_NODE and not node.data.strip():
            channel.removeChild(node)
    for item in ordered:
        channel.appendChild(item)
    # Whitespace nodes from previous serialization otherwise accumulate on reruns.
    def trim(node):
        for child in list(node.childNodes):
            if child.nodeType == child.TEXT_NODE and not child.data.strip():
                node.removeChild(child)
            elif child.nodeType == child.ELEMENT_NODE:
                trim(child)
    trim(document)
    output = document.toprettyxml(indent="  ", encoding="utf-8")
    temporary = path.with_name(path.name + ".tmp")
    try:
        temporary.write_bytes(output)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("feed", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--check-build", action="store_true")
    parser.add_argument("--allow-existing", action="store_true", help="Only for interrupted publish recovery")
    parser.add_argument("--url")
    parser.add_argument("--signature", help="Output from Sparkle sign_update")
    parser.add_argument("--notes", type=Path, help="Rendered release notes HTML")
    args = parser.parse_args()
    try:
        if args.check_build:
            check_build(args.feed, args.version, args.build, args.allow_existing)
        else:
            if not all((args.url, args.signature, args.notes)):
                parser.error("--url, --signature and --notes are required when writing the feed")
            update_feed(args.feed, args.version, args.build, args.url, args.signature, args.notes.read_text(encoding="utf-8"))
    except (ValueError, OSError, ExpatError) as error:
        # XML parser failures, invalid snapshots and I/O all leave the feed untouched.
        parser.exit(1, f"appcast: {error}\n")


if __name__ == "__main__":
    main()
