#!/usr/bin/env bash
# sync-repos.sh — clone missing GitHub repos as OWNER/REPO folders.
# Pull is opt-in; default is clone-only.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sync-repos.sh [options]

Lists repositories the authenticated GitHub user can access, then:
  - clones any that are missing as  BASE/OWNER/REPO
  - optionally pulls repos that already exist

Options:
  -d, --dir DIR       Base directory (default: ~/git_repos)
      --pull          git pull --ff-only in repos that already exist
      --delay SEC     Pause between clone/pull attempts (default: 1)
      --retries N     Extra attempts after a failed clone/pull (default: 3)
      --dry-run       Print actions without cloning or pulling
  -q, --quiet         Only print actions and errors
  -h, --help          Show this help

Requirements:
  gh   (logged in: gh auth login)
  git
  jq is NOT required; gh --jq is used

Examples:
  ./sync-repos.sh
  ./sync-repos.sh --dir ~/src
  ./sync-repos.sh --pull
  ./sync-repos.sh --dry-run --pull
EOF
}

BASE_DIR="${HOME}/git_repos"
DO_PULL=0
DRY_RUN=0
QUIET=0
DELAY=1
RETRIES=3

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--dir)
      [[ $# -ge 2 ]] || { echo "error: $1 requires a directory" >&2; exit 2; }
      BASE_DIR="$2"
      shift 2
      ;;
    --pull)
      DO_PULL=1
      shift
      ;;
    --delay)
      [[ $# -ge 2 ]] || { echo "error: $1 requires a number" >&2; exit 2; }
      DELAY="$2"
      shift 2
      ;;
    --retries)
      [[ $# -ge 2 ]] || { echo "error: $1 requires a number" >&2; exit 2; }
      RETRIES="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -q|--quiet)
      QUIET=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

log() {
  [[ "$QUIET" -eq 1 ]] && return 0
  printf '%s\n' "$*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

need_cmd gh
need_cmd git

# Git exit 128 is a generic fatal error. gh wraps it as
# "failed to run git: exit status 128" and hides useful context if we pass --quiet.
run_with_retry() {
  local label="$1"
  shift
  local attempt=0
  local max=$((RETRIES + 1))
  local wait="$DELAY"

  while (( attempt < max )); do
    attempt=$((attempt + 1))
    if "$@" ; then
      return 0
    fi
    echo "error: ${label} failed (attempt ${attempt}/${max})" >&2
    if (( attempt < max )); then
      echo "retrying in ${wait}s..." >&2
      sleep "$wait"
      # backoff a little so a burst of SSH/HTTPS limits can clear
      wait=$(awk -v w="$wait" 'BEGIN { w = w * 2; if (w > 15) w = 15; print w }')
    fi
  done
  return 1
}

clone_repo() {
  local slug="$1"
  local dest="$2"
  # Do not pass --quiet: the line before exit 128 is the real reason.
  # GIT_TERMINAL_PROMPT=0 prevents a hung password prompt in a loop.
  GIT_TERMINAL_PROMPT=0 run_with_retry "clone ${slug}" \
    gh repo clone "$slug" "$dest"
}

pull_repo() {
  local slug="$1"
  local dest="$2"
  GIT_TERMINAL_PROMPT=0 run_with_retry "pull ${slug}" \
    git -C "$dest" pull --ff-only
}

if ! gh auth status >/dev/null 2>&1; then
  echo "error: gh is not authenticated. Run: gh auth login" >&2
  exit 1
fi

mkdir -p "$BASE_DIR"
BASE_DIR="$(cd "$BASE_DIR" && pwd)"

log "base directory: $BASE_DIR"
if [[ "$DO_PULL" -eq 1 ]]; then
  log "mode: clone missing + pull existing"
else
  log "mode: clone missing only (pass --pull to update existing repos)"
fi
[[ "$DRY_RUN" -eq 1 ]] && log "dry-run: no changes will be made"
log "delay=${DELAY}s retries=${RETRIES}"

# TSV is easier to parse in bash than JSON objects.
# owner / name / visibility so the log can show private vs public.
mapfile -t REPOS < <(
  gh api /user/repos --paginate --jq \
    '.[] | [.owner.login, .name, .visibility] | @tsv'
)

if [[ ${#REPOS[@]} -eq 0 ]]; then
  echo "no repositories returned for the authenticated user" >&2
  exit 0
fi

cloned=0
pulled=0
skipped=0
failed=0
missing_git=0

for row in "${REPOS[@]}"; do
  # GitHub names cannot contain tabs; this split is safe.
  IFS=$'\t' read -r owner name visibility <<<"$row"
  [[ -n "$owner" && -n "$name" ]] || continue

  slug="${owner}/${name}"
  dest="${BASE_DIR}/${owner}/${name}"

  if [[ -d "${dest}/.git" ]]; then
    if [[ "$DO_PULL" -eq 1 ]]; then
      log "pull  ${slug}  (${visibility})"
      if [[ "$DRY_RUN" -eq 0 ]]; then
        if pull_repo "$slug" "$dest"; then
          pulled=$((pulled + 1))
        else
          echo "error: giving up on pull: ${slug}" >&2
          failed=$((failed + 1))
        fi
        sleep "$DELAY"
      else
        pulled=$((pulled + 1))
      fi
    else
      log "skip  ${slug}  (already exists)"
      skipped=$((skipped + 1))
    fi
  elif [[ -e "$dest" ]]; then
    echo "error: ${slug}: ${dest} exists but is not a git repo — leaving it alone" >&2
    missing_git=$((missing_git + 1))
    failed=$((failed + 1))
  else
    log "clone ${slug}  (${visibility}) -> ${dest}"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      mkdir -p "$(dirname "$dest")"
      if clone_repo "$slug" "$dest"; then
        cloned=$((cloned + 1))
      else
        echo "error: giving up on clone: ${slug}" >&2
        failed=$((failed + 1))
        # dest did not exist before this attempt; remove a partial clone.
        if [[ -e "$dest" && ! -d "${dest}/.git" ]]; then
          rm -rf "$dest"
        elif [[ -d "${dest}/.git" ]] && ! git -C "$dest" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
          rm -rf "$dest"
        fi
      fi
      sleep "$DELAY"
    else
      cloned=$((cloned + 1))
    fi
  fi
done

log ""
log "done: cloned=${cloned} pulled=${pulled} skipped=${skipped} failed=${failed}"
if [[ "$missing_git" -gt 0 ]]; then
  log "note: ${missing_git} path(s) existed but were not git repos"
fi

[[ "$failed" -eq 0 ]]
