# Demos

asciinema recordings for the project README, recorded headlessly: asciinema owns the pty, tmux
renders trek into it, and `record.sh` sends keys from outside. Nothing needs a real terminal, so
this runs over ssh or in CI exactly as it runs on a desktop.

```sh
make demo                     # record every demo into /tmp/trek-demos
make demo --only graph        # record one
make demo-publish             # upload, then write the players into README.md
```

## The pieces

| | |
|---|---|
| `fixture.sh` | builds `/tmp/trek-demo-work`: a small repo with a merge, a tag, a branch and a mixed working tree |
| `*.demo` | one line per action — see the header of `record.sh` for the verbs |
| `record.sh` | runs one demo and writes a `.cast` |
| `publish.sh` | uploads casts, remembering ids in `casts.tsv` |
| `embed.sh` | replaces the `<!-- demo:slug -->` blocks in `README.md` |

The fixture is rebuilt per recording. Two demos sharing one would race: the second rebuilds the
directory under the first's running trek, and the tree it is showing stops existing.

A demo never runs against this repository. trek's own tree is far too noisy to read at 30 rows,
and a recording must not depend on what the working tree happened to look like that day.

## Authenticating

Uploads from an unauthenticated CLI are **deleted after seven days**. Running `asciinema auth`
once and opening the URL it prints claims this machine's uploads — including ones already made —
into an account, and they then stay. Nothing here can do that step for you.
