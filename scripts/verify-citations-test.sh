#!/usr/bin/env bash
# Offline gauntlet for citation parsing, explicit networking and honest coverage.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$SCRIPT_DIR/verify-citations.py"
PASS=0
FAIL=0

ok() { echo "PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL  $1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. offline parse finds URLs and never touches the network
cat > "$WORK/a.md" <<'EOF'
https://eur-lex.europa.eu/eli/reg/2016/679/oj
https://support.google.com/googleplay/android-developer/answer/10787469
EOF
out="$(python3 "$VERIFY" --dir "$WORK" --offline 2>&1)"
grep -q "2 distinct URL" <<<"$out" && ok "offline mode finds both URLs" || bad "offline mode URL count"
grep -q "P1 https://eur-lex" <<<"$out" && ok "trust hierarchy classifies EUR-Lex as P1" || bad "trust classification"

# 2. empty tree is clean, not a crash
mkdir -p "$WORK/empty"
python3 "$VERIFY" --dir "$WORK/empty" --offline >/dev/null 2>&1 && ok "empty tree exits 0" || bad "empty tree"

# 3. malformed and huge input do not crash the parser
printf 'http://\nhttps://x\n%s\n' "$(head -c 20000 /dev/zero | tr '\0' 'x')" > "$WORK/empty/junk.md"
python3 "$VERIFY" --dir "$WORK/empty" --offline >/dev/null 2>&1 && ok "malformed input survives" || bad "malformed input"

# 3b. hidden tool-state directories are not cited sources, but .github is part of the repo
mkdir -p "$WORK/hid/.gstack" "$WORK/hid/.github"
echo "https://example.org/from-a-browser-log" > "$WORK/hid/.gstack/browse-network.log"
echo "https://www.ftc.gov/legal-library" > "$WORK/hid/.github/CONTRIBUTING.md"
out="$(python3 "$VERIFY" --dir "$WORK/hid" --offline 2>&1)"
grep -q "1 distinct URL" <<<"$out" && grep -q "ftc.gov" <<<"$out" && ! grep -q "browser-log" <<<"$out" && ok "hidden tool-state directories are skipped, .github is scanned" || bad "hidden tool-state directories are skipped, .github is scanned"

# 3c. a --files path that does not exist is an error, and a relative one is tried under --dir
out="$(cd / && python3 "$VERIFY" --dir "$WORK" --files no-such-folder/ --offline 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && grep -q "does not exist" <<<"$out" && ok "a missing --files path fails loudly" || bad "a missing --files path fails loudly (rc=$rc)"
out="$(cd / && python3 "$VERIFY" --dir "$WORK" --files a.md --offline 2>&1)"
grep -q "2 distinct URL" <<<"$out" && ok "a relative --files path resolves under --dir from any directory" || bad "a relative --files path resolves under --dir from any directory"

# Test the real CLI decisions against a substituted network boundary. No request,
# DNS lookup or connectivity probe is allowed to escape this process.
if python3 - "$VERIFY" <<'PYTHON'
import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("citations", sys.argv[1])
citations = importlib.util.module_from_spec(spec)
spec.loader.exec_module(citations)


class CitationChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.url = "https://developer.apple.com/news/?id=fixture-citation"
        (self.root / "source.md").write_text(self.url, encoding="utf-8")

    def run_cli(self, *args):
        output = io.StringIO()
        with patch.object(sys, "argv", ["verify-citations.py", "--dir", str(self.root), *args]), contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            try:
                result = citations.main()
            except SystemExit as error:
                result = error.code
        return result, output.getvalue()

    def test_default_and_offline_alias_never_fetch(self):
        for args in [(), ("--offline",)]:
            with self.subTest(args=args), patch.object(citations, "fetch", return_value=(200, b"content")) as fetch:
                result, output = self.run_cli(*args)
                self.assertEqual(result, 0)
                fetch.assert_not_called()
                self.assertIn("no network", output.lower())

    def test_online_fetches_only_the_cited_url_without_control_probes(self):
        with patch.object(citations, "fetch", return_value=(200, b"content")) as fetch:
            result, output = self.run_cli("--online")
        self.assertEqual(result, 0, output)
        self.assertEqual([call.args[0] for call in fetch.call_args_list], [self.url])
        self.assertIn("HTTP success. 1", output)
        self.assertNotIn("every citation resolves to real content", output)

    def test_waiver_is_named_and_never_counted_as_http_success(self):
        (self.root / ".citation-allowlist").write_text(self.url + "\n", encoding="utf-8")
        with patch.object(citations, "fetch") as fetch:
            result, output = self.run_cli("--online")
        self.assertEqual(result, 0, output)
        fetch.assert_not_called()
        self.assertIn("WAIVED", output)
        self.assertIn("HTTP success. 0", output)
        self.assertIn("not verified", output)

    def test_blocked_transient_redirect_and_dead_are_not_success(self):
        for status, expected_code, label in [(401, 2, "BLOCKED"), (403, 2, "BLOCKED"), (405, 2, "BLOCKED"), (429, 2, "BLOCKED"), (503, 2, "TRANSIENT"), (302, 2, "REDIRECT"), (404, 1, "UNREACHABLE"), (0, 1, "UNREACHABLE")]:
            with self.subTest(status=status), patch.object(citations, "fetch", return_value=(status, b"")):
                result, output = self.run_cli("--online")
            self.assertEqual(result, expected_code, output)
            self.assertIn(label, output)
            self.assertIn("HTTP success. 0", output)
            self.assertNotIn("verify-citations. PASS", output)

    def test_fetch_bounds_the_response_and_disables_redirects(self):
        reads = []
        handlers = []

        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def getcode(self): return 200
            def read(self, size=-1):
                reads.append(size)
                return b"body"

        class Opener:
            def open(self, request, timeout): return Response()

        def build(*given):
            handlers.extend(given)
            return Opener()

        public_answer = [(None, None, None, "", ("8.8.8.8", 443))]
        with patch("socket.getaddrinfo", return_value=public_answer), patch("urllib.request.build_opener", side_effect=build):
            status, body = citations.fetch(self.url)
        self.assertEqual((status, body), (200, b"body"))
        self.assertEqual(len(reads), 1)
        self.assertGreater(reads[0], 0)
        self.assertLessEqual(reads[0], 65536)
        self.assertTrue(handlers)
        self.assertIsNone(handlers[0].redirect_request(None, None, 302, "Found", {}, "http://127.0.0.1/private"))

    def test_fetch_rejects_non_public_dns_before_opening(self):
        private_answer = [(None, None, None, "", ("127.0.0.1", 443))]
        with patch("socket.getaddrinfo", return_value=private_answer), patch("urllib.request.build_opener") as opener:
            self.assertEqual(citations.fetch(self.url), (0, b""))
        opener.assert_not_called()


def forbidden(*args, **kwargs):
    raise AssertionError("Unexpected real network access in an offline test")


with patch("socket.getaddrinfo", side_effect=forbidden), patch("socket.create_connection", side_effect=forbidden), patch("urllib.request.urlopen", side_effect=forbidden):
    unittest.main(argv=["citation-network-checks"], verbosity=2)
PYTHON
then
  ok "opt-in networking and coverage regressions (network mocked)"
else
  bad "opt-in networking and coverage regressions (network mocked)"
fi

echo
echo "verify-citations gauntlet. $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
