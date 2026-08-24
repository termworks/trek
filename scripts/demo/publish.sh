#!/usr/bin/env bash
# Upload recorded casts to asciinema.org and remember which id belongs to which demo.
#
#   ./scripts/demo/publish.sh [slug …]        # default: every cast in /tmp/trek-demos
#
# The mapping lands in scripts/demo/casts.tsv so that re-embedding does not mean re-uploading, and
# so a later re-record can replace one recording without disturbing the others.
#
# **Uploads made by an unauthenticated CLI are deleted after seven days.** Running `asciinema auth`
# once and opening the URL it prints claims this machine's uploads — including the ones already
# made — into an account, and they then stay. Nothing here can do that step for you.
set -euo pipefail

cd "$(dirname "$0")/../.."
MAP="scripts/demo/casts.tsv"
CASTS="${CAST_DIR:-/tmp/trek-demos}"
touch "$MAP"

targets=()
if [ $# -gt 0 ]; then
    for slug in "$@"; do targets+=("$CASTS/$slug.cast"); done
else
    while IFS= read -r c; do targets+=("$c"); done < <(find "$CASTS" -name '*.cast' | sort)
fi

updated=$(mktemp)
cp "$MAP" "$updated"

for cast in "${targets[@]}"; do
    slug=$(basename "${cast%.cast}")
    [ -f "$cast" ] || { echo "no cast for $slug" >&2; continue; }

    # Already published, and the recording has not been made again since. Checking the
    # timestamp as well as the name is the point: skipping on the name alone means a
    # re-recorded demo can never be uploaded again, and the README keeps pointing at the
    # old one — silently, which is the worst way to be wrong about what a page shows.
    if grep -qP "^${slug}\t" "$MAP" && [ "$cast" -ot "$MAP" ]; then
        echo "$slug: already published, unchanged since"
        continue
    fi

    echo "$slug: uploading…"
    url=$(asciinema upload "$cast" 2>&1 | grep -oE 'https://asciinema\.org/a/[A-Za-z0-9]+' | head -1)
    if [ -z "$url" ]; then
        echo "  upload failed — is `asciinema auth` done on this machine?" >&2
        continue
    fi
    id="${url##*/}"
    grep -vP "^${slug}\t" "$updated" > "$updated.new" || true
    mv "$updated.new" "$updated"
    printf '%s\t%s\n' "$slug" "$id" >> "$updated"
    echo "  $url"
done

sort -o "$updated" "$updated"
mv "$updated" "$MAP"
echo "wrote $MAP"
