#!/usr/bin/env bash
set -euo pipefail

MESSAGE="${1:-}"
if [[ -z "$MESSAGE" ]]; then
  echo "Usage: $0 \"commit message\"" >&2
  exit 2
fi

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "Run this helper inside the publication checkout." >&2
  exit 2
}
cd "$ROOT"
BRANCH=$(git symbolic-ref --quiet --short HEAD) || {
  echo "Detached HEAD is not allowed." >&2
  exit 2
}

case "$BRANCH" in
  claude)
    ALLOWED='^(\.gitignore|LICENSE|README\.md|push_public\.sh|[^/]+\.template\.sh)$'
    ;;
  codex)
    ALLOWED='^(\.gitignore|LICENSE|README\.md|push_public\.sh|codex/[^/]+\.template\.sh|codex/task\.template\.md)$'
    ;;
  *)
    echo "Refusing to publish unsupported branch: $BRANCH" >&2
    exit 3
    ;;
esac

POLICY_FILE="${FORBIDDEN_POLICY_FILE:-$ROOT/.forbidden-patterns}"
if [[ ! -s "$POLICY_FILE" ]]; then
  echo "ABORT: missing non-empty local forbidden-pattern policy: $POLICY_FILE" >&2
  exit 4
fi

mapfile -t FORBIDDEN_MARKERS < <(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
  -e '/^$/d' -e '/^#/d' "$POLICY_FILE")
if [[ "${#FORBIDDEN_MARKERS[@]}" -eq 0 ]]; then
  echo "ABORT: local forbidden-pattern policy contains no active entries." >&2
  exit 4
fi

# Generic credential/identity shapes are safe to publish; private literal
# markers remain only in the ignored local policy file.
SECRET_RE='ghp[_]|g[i]thub_pat_|A[K]IA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|s[k]-[A-Za-z0-9_-]{20,}|A[I]za[0-9A-Za-z_-]{30,}|D[E]SKTOP-[A-Z]|/home/[a-z][a-z0-9_-]+'

git add -A

UNEXPECTED=$(git ls-files | grep -Ev "$ALLOWED" || true)
if [[ -n "$UNEXPECTED" ]]; then
  echo "ABORT: tracked paths are outside the branch allowlist:" >&2
  printf '%s\n' "$UNEXPECTED" >&2
  exit 5
fi

for marker in "${FORBIDDEN_MARKERS[@]}"; do
  if MATCHED_FILES=$(git grep --cached -ilE -- "$marker" -- .); then
    echo "ABORT: a forbidden local marker was found in these staged files:" >&2
    printf '%s\n' "$MATCHED_FILES" >&2
    exit 6
  fi
done
if MATCHED_FILES=$(git grep --cached -ilE "$SECRET_RE" -- .); then
  echo "ABORT: likely credential or machine-identity material was found in these staged files:" >&2
  printf '%s\n' "$MATCHED_FILES" >&2
  exit 7
fi

git diff --cached --check
if git diff --cached --quiet; then
  echo "Nothing to commit."
  exit 0
fi

git commit -m "$MESSAGE"
git push origin "$BRANCH"
