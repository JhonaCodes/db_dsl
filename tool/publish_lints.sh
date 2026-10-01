#!/usr/bin/env bash
# Publishes db_dsl_lints from an export of the committed tree.
#
#   tool/publish_lints.sh --dry-run
#   tool/publish_lints.sh --force
#
# Why an export: pub applies the .pubignore at the root of the repository,
# which keeps the plugin out of db_dsl's archive, to every package inside
# the repository. Outside of it, only the plugin's own rules apply, and what
# is published is exactly what is committed.
#
# `--force` because the analysis server requires the entry point at
# `lib/main.dart`, which pub warns about.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

git -C "$root" archive HEAD db_dsl_lints | tar -x -C "$out"
cd "$out/db_dsl_lints"
dart pub publish "$@"
