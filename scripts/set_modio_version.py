#!/usr/bin/env python3
"""Set version labels after a TF3 upload; preview by default, never upload files."""
import argparse
import getpass
import json
import os
from pathlib import Path
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, build_opener, HTTPRedirectHandler

REPOSITORY = Path(__file__).resolve().parents[1]
BASE = "https://g-10640.modapi.io/v1/games/10640/mods/6428298/files"


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Client:
    def __init__(self, token):
        self.token = token
        self.opener = build_opener(NoRedirect())

    def request(self, suffix="", fields=None):
        body = None if fields is None else urlencode(fields).encode("ascii")
        request = Request(BASE + suffix, data=body,
                          method="GET" if fields is None else "PUT",
                          headers={"Authorization": "Bearer " + self.token,
                                   "User-Agent": "SubsidyManagerReleaseTool/1.0",
                                   "Accept": "application/json",
                                   "Content-Type": "application/x-www-form-urlencoded"})
        try:
            with self.opener.open(request, timeout=30) as response:
                return json.load(response)
        except HTTPError as error:
            raise RuntimeError(f"mod.io returned HTTP {error.code}; check token permissions or retry later") from None
        except URLError:
            raise RuntimeError("Could not reach mod.io; check your connection") from None

    def files(self):
        result = []
        offset = 0
        while True:
            page = self.request("?" + urlencode({"_limit": 100, "_offset": offset}))
            rows = page["data"]
            result.extend(rows)
            offset += len(rows)
            if offset >= page["result_total"]:
                return result
            if not rows:
                raise RuntimeError("Incomplete mod.io file listing; no changes made")


def select_files(files, version, ids=()):
    if ids:
        selected = [file for file in files if file["id"] in ids]
        if {file["id"] for file in selected} != set(ids):
            raise ValueError("A requested file ID does not belong to this mod")
    else:
        # Only a release heading at the start counts; mentions of older releases do not.
        heading = re.compile(r"^\s*v?" + re.escape(version) + r"(?=$|[\s:—–-])", re.I)
        selected = [file for file in files if heading.search(file.get("changelog") or "")]
    if not selected:
        raise ValueError("No matching release files. Put vMAJOR.MINOR.PATCH at the start of the upload changelog, or supply --file-id for each reviewed file.")
    return selected


def update(client, files, version, apply=False):
    for file in files:
        print(f"File {file['id']} ({file['filename']}): {file.get('version')!r} -> {version!r}")
    if not apply:
        print("Preview only. Run with --apply to update these labels.")
        return
    for file in files:
        if file.get("version") == version:
            print(f"File {file['id']}: already correct")
            continue
        # Recheck before writing so a changed release cannot be silently relabelled.
        current = client.request(f"/{file['id']}")
        if any(current.get(key) != file.get(key) for key in ("id", "version", "changelog")):
            raise RuntimeError(f"File {file['id']} changed since listing; rerun to review. Earlier files may already be updated.")
        client.request(f"/{file['id']}", {"version": version})
        verified = client.request(f"/{file['id']}")
        if verified.get("version") != version:
            raise RuntimeError(f"File {file['id']}: version verification failed. Earlier files may already be updated.")
        print(f"File {file['id']}: updated and verified")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="write version labels and verify them")
    parser.add_argument("--version", help="override VERSION for an older release")
    parser.add_argument("--file-id", type=int, action="append", default=[], help="explicit reviewed file ID; repeat for PC/console")
    args = parser.parse_args()
    version = args.version or (REPOSITORY / "VERSION").read_text().strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        parser.error("version must be MAJOR.MINOR.PATCH")
    if any(file_id <= 0 for file_id in args.file_id):
        parser.error("file IDs must be positive")
    token = os.environ.get("MODIO_ACCESS_TOKEN") or getpass.getpass("mod.io OAuth access token (hidden): ")
    if not token.strip():
        parser.error("an OAuth access token is required")
    client = Client(token.strip())
    update(client, select_files(client.files(), version, args.file_id), version, args.apply)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, KeyError, OSError) as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
