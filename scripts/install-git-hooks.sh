#!/bin/bash
# Install local publishing hooks. Never change core.hooksPath or global config.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(git rev-parse --show-toplevel)"
for name in post-commit pre-push; do
  # --git-path hooks honors core.hooksPath and can resolve outside this repo.
  # The global _chain deliberately looks in this repository\'s actual git-dir.
  hook="$(git rev-parse --absolute-git-dir)/hooks/$name"
  mkdir -p "$(dirname "$hook")"
  if [[ -e "$hook" ]] && ! grep -q '^# House AI local publishing hook$' "$hook"; then
    backup="$hook.backup.$(date +%Y%m%d-%H%M%S).$$"
    mv "$hook" "$backup"
    echo "Preserved previous $name at $backup"
  fi
  printf '%s\n' '#!/bin/bash' '# House AI local publishing hook' \
    'set -euo pipefail' \
    'root="$(git rev-parse --show-toplevel)"' \
    "exec /bin/bash \"\$root/scripts/git-hooks/$name\" \"\$@\"" > "$hook"
  chmod 755 "$hook"
  test -x "$hook"
done
echo "Installed clean-main auto-publish and scrub/test gates for $(basename "$root")."
echo "Commit waits for tests. Verify origin/main equals HEAD after it returns."
