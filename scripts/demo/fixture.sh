#!/usr/bin/env bash
# Build the repository the demos run in.
#
# Fixed content, so a recording made today and one made after a refactor differ only by what trek
# did. Everything lives under /tmp: a demo must never touch the repository it documents, and trek's
# own tree is far too noisy to read at 30 rows anyway.
set -euo pipefail

WORK="${DEMO_WORK:-/tmp/trek-demo-work}"
rm -rf "$WORK"
mkdir -p "$WORK"

cd "$WORK"
git init -q -b main .
git config user.name "Ada Lovelace"
git config user.email "ada@example.com"

mkdir -p src/engine src/ui docs
cat > README.md <<'EOF'
# atlas

A small mapping library.
EOF
cat > src/engine/render.odin <<'EOF'
package engine
render :: proc() {}
EOF
cat > src/engine/tiles.odin <<'EOF'
package engine
tiles :: proc() {}
EOF
cat > src/ui/panel.odin <<'EOF'
package ui
panel :: proc() {}
EOF
cat > docs/design.md <<'EOF'
# Design
EOF
cat > atlas.toml <<'EOF'
name = "atlas"
EOF

git add -A
GIT_AUTHOR_DATE="2026-05-02T09:14:00+02:00" GIT_COMMITTER_DATE="2026-05-02T09:14:00+02:00" \
    git commit -q -m "feat: lay out the engine and the ui"
git tag v0.1.0

cat >> src/engine/render.odin <<'EOF'
draw :: proc() {}
EOF
GIT_AUTHOR_DATE="2026-05-09T16:40:00+02:00" GIT_COMMITTER_DATE="2026-05-09T16:40:00+02:00" \
    git commit -qam "feat(engine): draw the visible tiles"

git checkout -q -b spike
cat >> src/ui/panel.odin <<'EOF'
resize :: proc() {}
EOF
GIT_AUTHOR_DATE="2026-05-14T11:05:00+02:00" GIT_COMMITTER_DATE="2026-05-14T11:05:00+02:00" \
    git commit -qam "feat(ui): let a panel resize"
git checkout -q main
# A merge, so the graph has a fork in it rather than one straight line.
GIT_AUTHOR_DATE="2026-05-16T10:00:00+02:00" GIT_COMMITTER_DATE="2026-05-16T10:00:00+02:00" \
    git merge -q --no-ff spike -m "merge: bring the panel work onto main"

# The working tree the Changes tab shows: one new file, two edits, one staged.
cat >> src/engine/tiles.odin <<'EOF'
neighbours :: proc() {}
EOF
cat >> docs/design.md <<'EOF'

Tiles are square.
EOF
cat > src/ui/theme.odin <<'EOF'
package ui
theme :: proc() {}
EOF
git add src/ui/theme.odin

# Left untracked on purpose, so the Changes tab has a NEW section as well as the other two.
cat > notes.md <<'EOF'
# Notes
EOF

echo "$WORK"
