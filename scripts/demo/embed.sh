#!/usr/bin/env bash
# Put the published recordings into the README.
#
#   ./scripts/demo/embed.sh
#
# Idempotent: each block is delimited by its own slug, so running this again after a re-record
# replaces that player rather than stacking a second one under the heading. A slug with no
# recording is left exactly as it is.
set -euo pipefail

cd "$(dirname "$0")/../.."
MAP="scripts/demo/casts.tsv"
DOC="README.md"
[ -s "$MAP" ] || { echo "nothing published yet — run scripts/demo/publish.sh" >&2; exit 1; }

while IFS=$'\t' read -r slug id; do
    [ -n "$slug" ] || continue
    begin="<!-- demo:$slug -->"
    end="<!-- /demo:$slug -->"
    grep -qF "$begin" "$DOC" || { echo "no $begin marker in $DOC — skipping $slug" >&2; continue; }

    block=$(printf '%s\n[![%s](https://asciinema.org/a/%s.svg)](https://asciinema.org/a/%s)\n%s' \
        "$begin" "trek $slug demo" "$id" "$id" "$end")

    awk -v begin="$begin" -v end="$end" -v block="$block" '
        $0 == begin { print block; skip = 1; next }
        $0 == end   { skip = 0; next }
        !skip
    ' "$DOC" > "$DOC.new"
    mv "$DOC.new" "$DOC"
    echo "$slug -> $id"
done < "$MAP"
