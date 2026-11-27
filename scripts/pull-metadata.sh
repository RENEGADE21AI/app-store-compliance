#!/usr/bin/env bash
# Pull live store metadata into ./metadata so metadata-audit.py can inspect the
# real listing, not only the source.
#
# Apple (asc CLI):
#   APP_ID=123456789 VERSION=1.2.0 bash pull-metadata.sh apple
#
# Google Play (Play Developer API, real pull):
#   PACKAGE_NAME=com.example.app bash pull-metadata.sh google --allow-play-edit
#   Auth: explicitly supply GOOGLE_ACCESS_TOKEN for this operation.
#   The service account or user must have
#   the Play Developer API enabled and access to the app.
#
# Then audit:
#   python3 scripts/metadata-audit.py ./metadata
set -uo pipefail
DIR="${DIR:-./metadata}"
target="${1:-apple}"

case "$target" in
  apple)
    if ! command -v asc >/dev/null 2>&1; then
      echo "asc CLI not found. Install with: brew install asc"
      echo "Then authenticate asc with your App Store Connect API key (issuer id, key id, .p8)."
      exit 1
    fi
    : "${APP_ID:?set APP_ID to your App Store Connect app id}"
    : "${VERSION:?set VERSION to the app version, e.g. 1.2.0}"
    mkdir -p "$DIR" || exit 1
    echo "Pulling Apple metadata for app $APP_ID version $VERSION into $DIR"
    asc metadata pull --app "$APP_ID" --version "$VERSION" --dir "$DIR" || exit $?
    echo "Done. Now run: python3 scripts/metadata-audit.py $DIR"
    ;;

  google|play)
    [ "$#" -eq 2 ] && [ "$2" = "--allow-play-edit" ] || {
      echo "Google retrieval creates and deletes a temporary Play edit. Re-run with --allow-play-edit if authorized." >&2
      exit 2
    }
    : "${PACKAGE_NAME:?set PACKAGE_NAME to your app package, e.g. com.example.app}"
    command -v curl >/dev/null 2>&1 || { echo "curl is required"; exit 1; }
    command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 1; }
    TOKEN="${GOOGLE_ACCESS_TOKEN:-}"
    export -n TOKEN
    if [ -z "$TOKEN" ] || [[ "$TOKEN" == *$'\n'* || "$TOKEN" == *$'\r'* ]]; then
      echo "Supply a valid GOOGLE_ACCESS_TOKEN explicitly. It needs the androidpublisher scope and access to $PACKAGE_NAME." >&2
      exit 1
    fi
    unset GOOGLE_ACCESS_TOKEN
    if ! [[ "$PACKAGE_NAME" =~ ^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$ ]]; then
      echo "PACKAGE_NAME must be an Android application ID." >&2
      exit 2
    fi
    google_request() {
      printf 'Authorization: Bearer %s\n' "$TOKEN" | env -u GOOGLE_ACCESS_TOKEN curl --disable -fsS --proto '=https' --max-time 45 --header @- "$@"
    }
    BASE="https://androidpublisher.googleapis.com/androidpublisher/v3/applications/$PACKAGE_NAME"
    mkdir -p "$DIR" || exit 1
    echo "Creating a temporary Play edit for $PACKAGE_NAME"
    EDIT="$(google_request -X POST -H "Content-Length: 0" "$BASE/edits" | python3 -I -c 'import json,sys;print(json.load(sys.stdin).get("id",""))')" || exit 1
    if ! [[ "$EDIT" =~ ^[A-Za-z0-9_-]+$ ]]; then
      echo "Google did not return a usable edit ID. Check Play Console for any pending edit." >&2
      exit 1
    fi
    cleanup_edit() {
      local prior="$?"
      trap - EXIT
      if ! google_request -X DELETE "$BASE/edits/$EDIT" >/dev/null; then
        printf 'Could not delete temporary edit %s. Check Play Console.\n' "$EDIT" >&2
        [ "$prior" -eq 0 ] && prior=1
      fi
      exit "$prior"
    }
    trap cleanup_edit EXIT
    echo "Fetching listings for the temporary edit."
    LISTINGS="$(google_request "$BASE/edits/$EDIT/listings")" || exit $?
    LISTINGS="$LISTINGS" python3 -I - "$DIR" <<'PYIN' || exit $?
import json
import os
import re
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1]).resolve()
data = json.loads(os.environ["LISTINGS"])
for listing in data.get("listings", []):
    language = listing.get("language", "default")
    if not isinstance(language, str) or not re.fullmatch(r"[A-Za-z0-9]+(?:[-_][A-Za-z0-9]+)*", language):
        raise SystemExit("Google returned an invalid listing locale.")
    directory = root / language
    if directory.resolve() != directory or directory.is_symlink():
        raise SystemExit("Refusing to write through a linked locale directory.")
    directory.mkdir(exist_ok=True)
    for key, name in (("title", "name.txt"), ("shortDescription", "short_description.txt"), ("fullDescription", "full_description.txt")):
        if key not in listing:
            continue
        target = directory / name
        with tempfile.NamedTemporaryFile(mode="w", dir=directory, encoding="utf-8", delete=False) as temp:
            temp.write(listing[key])
        try:
            os.replace(temp.name, target)
        finally:
            if os.path.exists(temp.name):
                os.unlink(temp.name)
    print("wrote", language)
PYIN
    echo "Retrieval finished. The temporary edit will be deleted before exit."
    echo "Note. The Play privacy policy URL and Data Safety form are not in the listings API. Add the privacy policy URL to $DIR/meta.json as {\"privacy_policy_url\":\"...\"} and verify Data Safety in the Play Console."
    ;;
  *)
    echo "Usage: pull-metadata.sh apple | google --allow-play-edit"
    exit 1
    ;;
esac
