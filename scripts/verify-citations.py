#!/usr/bin/env python3
"""Classify cited URLs offline; request HTTP reachability only with --online.
A successful response does not establish citation accuracy or source authority.
Redirects are not followed and no synthetic control URLs are requested.
Exit 0: offline parsing or completed checks (possibly with explicit waivers).
Exit 1: unreachable URLs. Exit 2: invalid input or incomplete online coverage.
"""

import argparse
import ipaddress
import os
import re
import socket
import sys
import urllib.error
import urllib.request
from urllib.parse import urlsplit

URL_RE = re.compile(r"https?://[^\s\"'<>)\]},`]+")
TRAILING = ".,;:)]}>\"'`"

# These responses leave the citation content unverified, rather than proving it dead.
BLOCKED_CODES = {401, 403, 405, 429}

# Server-side faults also leave online coverage incomplete.
TRANSIENT_CODES = {500, 502, 503, 504}
TIMEOUT = 20
MAX_BODY_BYTES = 65536
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

TRUST = [
    (
        1,
        (
            "europa.eu",
            "eur-lex.europa.eu",
            "edpb.europa.eu",
            "enisa.europa.eu",
            "ftc.gov",
            "nist.gov",
            "cisa.gov",
            "ico.org.uk",
            "gov.uk",
            "bsi.bund.de",
        ),
    ),
    (2, ("reuters.com", "apnews.com", "bloomberg.com")),
    (
        1,
        (
            "developer.apple.com",
            "apple.com",
            "developer.android.com",
            "support.google.com",
            "source.android.com",
            "play.google.com",
        ),
    ),
    (
        3,
        (
            "owasp.org",
            "mas.owasp.org",
            "cheatsheetseries.owasp.org",
            "datatracker.ietf.org",
            "oauth.net",
        ),
    ),
]

SKIP_DIRS = {".git", "node_modules", "__pycache__", ".venv", "assets"}
SKIP_EXT = {".png", ".jpg", ".jpeg", ".gif", ".svg", ".pdf", ".zip", ".ico"}

# XML/XSD namespace identifiers. They look like URLs but are names, not endpoints.
NAMESPACE_PREFIXES = ("http://schemas.", "http://www.w3.org/", "http://purl.org/", "http://xmlns.")

# RFC 2606 reserved TLDs. Deliberately unresolvable fixtures, never citations.
RESERVED_TLDS = (".invalid", ".test", ".example", ".localhost")

# The verifier and its gauntlet hold deliberate broken URLs as pattern data.
SELF = {"verify-citations.py", "verify-citations-test.sh"}


def trust_of(host):
    for level, hosts in TRUST:
        if any(host == h or host.endswith("." + h) for h in hosts):
            return level
    return 4


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def public_url(url):
    try:
        parsed = urlsplit(url)
        host = (parsed.hostname or "").rstrip(".").lower()
        if (parsed.scheme not in ("http", "https") or not host or "\\" in host
                or parsed.username is not None or parsed.password is not None
                or host == "localhost" or host.endswith((".localhost", ".local"))):
            return False
        addresses = socket.getaddrinfo(host, parsed.port or (443 if parsed.scheme == "https" else 80), type=socket.SOCK_STREAM)
        return bool(addresses) and all(ipaddress.ip_address(hit[4][0]).is_global for hit in addresses)
    except (OSError, ValueError):
        return False


def fetch(url):
    if not public_url(url):
        return 0, b""
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        opener = urllib.request.build_opener(NoRedirect())
        with opener.open(req, timeout=TIMEOUT) as r:
            return r.getcode(), r.read(MAX_BODY_BYTES)
    except urllib.error.HTTPError as e:
        code = e.code
        e.close()
        return code, b""
    except Exception:
        return 0, b""


def host_of(url):
    try:
        return (urlsplit(url).hostname or "").lower()
    except ValueError:
        return ""


def collect_urls(root, only=None):
    found = {}
    targets = only if only else [root]
    for target in targets:
        walk = [target] if os.path.isfile(target) else []
        if not walk:
            for dirpath, dirnames, filenames in os.walk(target):
                # hidden directories hold local tool state (browser logs, editor caches), never cited sources
                dirnames[:] = [
                    d for d in dirnames
                    if d not in SKIP_DIRS and (not d.startswith(".") or d == ".github")
                ]
                for fn in filenames:
                    if os.path.splitext(fn)[1].lower() in SKIP_EXT or fn in SELF:
                        continue
                    walk.append(os.path.join(dirpath, fn))
        for path in walk:
            try:
                with open(path, "r", encoding="utf-8", errors="ignore") as fh:
                    text = fh.read()
            except OSError:
                continue
            for raw in URL_RE.findall(text):
                url = raw.rstrip(TRAILING)
                if len(url) < 12 or url.startswith(NAMESPACE_PREFIXES):
                    continue
                if "{" in url or "}" in url or "\\n" in url:
                    continue
                if any(host_of(url).endswith(x) for x in RESERVED_TLDS):
                    continue
                found.setdefault(url, set()).add(os.path.relpath(path, root))
    return found


def main():
    ap = argparse.ArgumentParser(
        description="Classify citations offline by default; --online requests HTTP reachability, not claim verification."
    )
    ap.add_argument("--dir", default=".", help="repo root to scan")
    ap.add_argument("--files", nargs="*", help="scan only these paths")
    network = ap.add_mutually_exclusive_group()
    network.add_argument("--online", action="store_true", help="request only scanned URLs; no redirects or synthetic probes")
    network.add_argument("--offline", action="store_true", help="compatibility alias for the default: parse and classify only")
    ap.add_argument(
        "--allow",
        default=".citation-allowlist",
        help="explicit URL waivers (one per line); skipped URLs remain unverified",
    )
    args = ap.parse_args()

    root = os.path.abspath(args.dir)
    allow = set()
    allow_path = os.path.join(root, args.allow)
    if os.path.exists(allow_path):
        with open(allow_path, encoding="utf-8") as fh:
            allow = {ln.strip() for ln in fh if ln.strip() and not ln.startswith("#")}

    files = []
    for path in args.files or []:
        # a relative path is tried from the working directory first, then under --dir
        resolved = path if os.path.exists(path) else os.path.join(root, path)
        if not os.path.exists(resolved):
            print(f"verify-citations. '{path}' does not exist here or under {root}. Nothing was checked.")
            return 2
        files.append(resolved)

    urls = collect_urls(root, files or None)
    if not urls:
        print("verify-citations. no URLs found.")
        return 0

    print(f"verify-citations. {len(urls)} distinct URL(s) across the scan.")
    if not args.online:
        for u in sorted(urls):
            print(f"  P{trust_of(host_of(u))} {u}")
        print("offline mode. no network verification performed. Use --online to request reachability checks.")
        return 0

    dead, blocked, transient, redirects, waived, ok = [], [], [], [], [], 0
    for url in sorted(urls):
        if url in allow:
            waived.append(url)
            continue
        code, _body = fetch(url)
        if 200 <= code < 300:
            ok += 1
        elif code in BLOCKED_CODES:
            blocked.append((url, code))
        elif code in TRANSIENT_CODES:
            transient.append((url, code, sorted(urls[url])))
        elif 300 <= code < 400:
            redirects.append((url, code))
        else:
            dead.append((url, code, sorted(urls[url])))

    print(f"  HTTP success. {ok}")
    if waived:
        print(f"  WAIVED. {len(waived)} explicitly skipped, not verified.")
        for url in waived:
            print(f"    {url}")
    if blocked:
        print(f"  BLOCKED. {len(blocked)} response(s); citation content not verified.")
        for url, code in blocked:
            print(f"    [{code}] {url}")
    if transient:
        print(f"\nTRANSIENT HOST FAULT. {len(transient)} URL(s) return 5xx; not verified.")
        for url, code, files in transient:
            print(f"  [{code}] {url}")
            for f in files:
                print(f"        cited in {f}")
    if redirects:
        print(f"  REDIRECT. {len(redirects)} not followed; inspect the final URL explicitly.")
        for url, code in redirects:
            print(f"    [{code}] {url}")
    if dead:
        print(f"\nUNREACHABLE. {len(dead)} URL(s).")
        for url, code, files in dead:
            print(f"  [{code or 'ERR'}] {url}")
            for f in files:
                print(f"        cited in {f}")

    if dead:
        print("\nverify-citations. FAIL")
        return 1
    if blocked or transient or redirects:
        print("\nverify-citations. INCOMPLETE. Required online responses remain unverified.")
        return 2
    if waived:
        print("\nverify-citations. COMPLETE WITH WAIVERS. Waived citations were not verified.")
    else:
        print("\nverify-citations. PASS. Requested URLs returned successful HTTP responses.")
    print("HTTP reachability does not verify cited claims or source authority.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
