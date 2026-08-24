#!/usr/bin/env bash
# Record one asciinema cast of trek, driven by a demo script.
#
# The recording is headless — asciinema makes its own pty, tmux renders trek into it, and this
# script sends keys into the session from outside. Nothing needs a real terminal, so it runs in CI
# or over ssh exactly as it runs here.
#
#   ./scripts/demo/record.sh scripts/demo/explorer.demo [out.cast]
#
# The demo script is a line-per-action file:
#
#   cols 100          terminal width  (default 100)
#   rows 30           terminal height (default 30)
#   speed 0.06        seconds between keystrokes while typing
#   args  <argv>      arguments trek is launched with
#   setup <command>   run in the fixture before recording, so it is not in the film
#   key   <name>      one key, as tmux spells it: Down, Enter, Escape, C-c
#   type  <text>      type it a character at a time
#   wait  <seconds>   pause, so a viewer can read what just happened
#   #  …              a comment
#
# trek is the whole session: unlike a shell demo there is no prompt, so nothing is typed except
# what a user would actually press.
set -euo pipefail

cd "$(dirname "$0")/../.."
DEMO="${1:?usage: record.sh <demo-file> [out.cast]}"
OUT="${2:-/tmp/trek-demos/$(basename "${DEMO%.demo}").cast}"
TREK="${TREK_BIN:-$PWD/target/trek}"
WORK="${DEMO_WORK:-/tmp/trek-demo-work}"
SESSION="trekdemo_$(basename "${DEMO%.demo}")_$$"

[ -x "$TREK" ] || { echo "no trek binary at $TREK — run: make build" >&2; exit 1; }
command -v asciinema >/dev/null || { echo "asciinema is not installed" >&2; exit 1; }
command -v tmux >/dev/null || { echo "tmux is not installed" >&2; exit 1; }

cols=100 rows=30 speed=0.06 args=""
while read -r verb rest; do
    case "$verb" in
        cols)  cols="$rest" ;;
        rows)  rows="$rest" ;;
        speed) speed="$rest" ;;
        args)  args="$rest" ;;
    esac
done < "$DEMO"

# A fresh fixture per recording. Two demos sharing one would race: the second rebuilds the
# directory under the first's running trek, and the tree it is showing stops existing.
DEMO_WORK="$WORK" ./scripts/demo/fixture.sh >/dev/null

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

# `setup` runs before the recorder attaches, so it is not in the film.
while IFS= read -r line; do
    case "${line%% *}" in
        setup) ( cd "$WORK" && eval "${line#setup }" ) >/dev/null 2>&1 ;;
    esac
done < "$DEMO"

tmux kill-session -t "$SESSION" 2>/dev/null || true
# XDG_STATE_HOME is redirected so a demo never reads or writes the recorder's own trek state: the
# expanded folders from yesterday's session would otherwise open on camera.
tmux -f /dev/null new-session -d -s "$SESSION" -x "$cols" -y "$rows" -c "$WORK" \
    "XDG_STATE_HOME=/tmp/trek-demo-state XDG_CONFIG_HOME=/tmp/trek-demo-config $TREK $args"
# The status bar would be baked into every frame; the escape-time default makes Escape-then-key
# look like Alt-key, which matters for any demo that presses Escape.
tmux set -t "$SESSION" status off
tmux set -t "$SESSION" escape-time 0
sleep 2

asciinema rec --headless --window-size "${cols}x${rows}" \
    --command "tmux attach-session -t $SESSION" "$OUT" >/dev/null 2>&1 &
recorder=$!
sleep 2

send_text() {
    local text="$1" i ch
    for ((i = 0; i < ${#text}; i++)); do
        ch="${text:$i:1}"
        # A lone `;` is tmux's own command separator and never reaches the pane. Sent by hex
        # instead, which the parser does not touch.
        if [ "$ch" = ";" ]; then
            tmux send-keys -t "$SESSION" -H 3b
        else
            tmux send-keys -t "$SESSION" -l -- "$ch"
        fi
        sleep "$speed"
    done
}

while IFS= read -r line; do
    verb="${line%% *}"
    rest="${line#* }"
    [ "$verb" = "$line" ] && rest=""
    case "$verb" in
        ''|'#'*|cols|rows|speed|args|setup) ;;
        key)  tmux send-keys -t "$SESSION" "$rest"; sleep 0.45 ;;
        type) send_text "$rest" ;;
        wait) sleep "$rest" ;;
        *)    echo "unknown verb '$verb' in $DEMO" >&2; exit 1 ;;
    esac
done < "$DEMO"

# `q` is how trek exits, but a text field swallows it: the commit box would take it as
# typing and the recorder would wait on a trek that never left. Escape closes any dialog,
# `1` returns to the tree — a number key is handled above the tab, so it works even from
# inside a field — and only then does `q` mean quit.
tmux send-keys -t "$SESSION" Escape
sleep 0.4
tmux send-keys -t "$SESSION" 1
sleep 0.4
tmux send-keys -t "$SESSION" q
sleep 1.5

# And if it hangs anyway, end the session rather than the whole run: one stuck demo must not stop
# the others from being recorded.
for _ in $(seq 20); do
    kill -0 "$recorder" 2>/dev/null || break
    sleep 0.5
done
if kill -0 "$recorder" 2>/dev/null; then
    echo "  WARNING: $(basename "$DEMO") did not end on its own — killing the session" >&2
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    sleep 1
    kill "$recorder" 2>/dev/null || true
fi
wait "$recorder" 2>/dev/null || true
tmux kill-session -t "$SESSION" 2>/dev/null || true

[ -s "$OUT" ] || { echo "  WARNING: $(basename "$DEMO") recorded nothing" >&2; exit 1; }
events=$(grep -c '^\[' "$OUT" || true)
secs=$(grep -oE '^\[[0-9]+\.[0-9]+' "$OUT" | tr -d '[' | awk '{s+=$1} END {printf "%.1f", s}')
printf '%s  %ss  %s events  %s bytes\n' "$OUT" "${secs:-?}" "$events" "$(stat -c%s "$OUT")"

# Ways a recording is quietly ruined, worth failing on rather than publishing. The status bar is
# baked into every frame; a missing binary or a rebuilt working directory shows as an error line.
for wrong in 'getcwd' '0:trek' 'No such file'; do
    if grep -q "$wrong" "$OUT"; then
        echo "  WARNING: '$wrong' appears in the recording — re-record it" >&2
    fi
done
