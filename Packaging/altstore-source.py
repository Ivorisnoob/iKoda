"""Writes Koda's AltStore / SideStore source from the GitHub releases.

Usage: python3 -I altstore-source.py <releases.json> <out/source.json>

releases.json is `gh api repos/<repo>/releases`. Each published release with a Koda.ipa
becomes a version. AltStore refuses an install whose version, build number or permissions
differ from what the source claims, so those are read from each IPA's own Info.plist rather
than from tags or the project.
"""

import json
import plistlib
import re
import sys
import urllib.request
import zipfile
from io import BytesIO
from pathlib import Path

TEMPLATE = Path(__file__).with_name("altstore-source.json")
INFO_PLIST = re.compile(r"^Payload/[^/]+\.app/Info\.plist$")


def info_plist(url):
    with urllib.request.urlopen(url) as response:
        data = response.read()
    with zipfile.ZipFile(BytesIO(data)) as ipa:
        name = next(n for n in ipa.namelist() if INFO_PLIST.match(n))
        return plistlib.loads(ipa.read(name))


def main(releases_path, out_path):
    releases = json.loads(Path(releases_path).read_text(encoding="utf-8"))
    source = json.loads(TEMPLATE.read_text(encoding="utf-8"))
    app = source["apps"][0]

    published = [r for r in releases if not r["draft"] and not r["prerelease"]]
    published.sort(key=lambda r: r["published_at"], reverse=True)

    versions = []
    privacy = None
    for release in published:
        ipa = next((a for a in release["assets"] if a["name"] == "Koda.ipa"), None)
        if ipa is None:
            continue
        info = info_plist(ipa["browser_download_url"])
        if info.get("CFBundleIdentifier") != app["bundleIdentifier"]:
            sys.exit(f"{release['tag_name']}: Koda.ipa is {info.get('CFBundleIdentifier')}")
        # The newest IPA's usage strings are what AltStore checks on install.
        if privacy is None:
            privacy = {k: v for k, v in sorted(info.items()) if k.endswith("UsageDescription")}
        versions.append({
            "version": info["CFBundleShortVersionString"],
            "buildVersion": info["CFBundleVersion"],
            "date": release["published_at"],
            "localizedDescription": (release.get("body") or release["name"] or "").strip(),
            "downloadURL": ipa["browser_download_url"],
            "size": ipa["size"],
            "minOSVersion": info.get("MinimumOSVersion", "26.0"),
        })
        print(f"{release['tag_name']}: {versions[-1]['version']} ({versions[-1]['buildVersion']}), {ipa['size']} bytes")

    if not versions:
        sys.exit("No release has a Koda.ipa")

    app["versions"] = versions
    app["appPermissions"]["privacy"] = privacy

    out = Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
