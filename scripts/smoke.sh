#!/usr/bin/env bash
set -euo pipefail

export TREK_SMOKE_BIN
TREK_SMOKE_BIN=$(realpath "${1:-target/trek}")
scratch=$(mktemp -d "${TMPDIR:-/tmp}/trek-smoke.XXXXXXXX")
output="$scratch/terminal.log"
export HOME="$scratch/home"
export XDG_CONFIG_HOME="$HOME/config"
export XDG_STATE_HOME="$HOME/state"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export TREK_SMOKE_DIR="$scratch/trek"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$TREK_SMOKE_DIR"
git -C "$TREK_SMOKE_DIR" init -q
printf 'tracked\n' > "$TREK_SMOKE_DIR/tracked.txt"
git -C "$TREK_SMOKE_DIR" add tracked.txt
git -C "$TREK_SMOKE_DIR" -c user.name=Smoke -c user.email=smoke@example.invalid \
  -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm 'test: seed fixture'
printf 'untracked\n' > "$TREK_SMOKE_DIR/new.txt"

cleanup() {
  if [ "$?" -eq 0 ]; then
    rm -rf "$scratch"
  else
    printf 'PTY smoke failed; terminal log: %s\n' "$output" >&2
  fi
}
trap cleanup EXIT

wait_for() {
  local text=$1 minimum=${2:-1} count
  for ((attempt = 0; attempt < 200; attempt++)); do
    count=$(grep -aoF "$text" "$output" 2>/dev/null | wc -l) || true
    if [ "$count" -ge "$minimum" ]; then return 0; fi
    sleep .05
  done
  printf 'Timed out waiting for %s\n' "$text" >&2
  return 1
}

{
  wait_for TREK
  printf 2
  wait_for Changes
  wait_for NEW
  printf 3
  wait_for 'Git Graph'
  printf 1
  wait_for TREK 2
  printf '\033[B'
  sleep .2
  printf m
  wait_for Actions
  printf q
  sleep .2
  printf q
} | timeout 30 script -qefc \
  'stty cols 100 rows 30; exec "$TREK_SMOKE_BIN" "$TREK_SMOKE_DIR"' /dev/null \
  > "$output" 2>&1
grep -aqF $'\033[?1049l' "$output"
printf 'PTY smoke passed: explorer, changes, graph, menu, terminal restore\n'
