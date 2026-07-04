#!/usr/bin/env bash
# ============================================================
# code_check/lib/git-utils.sh — Git Utility Library
# ============================================================
# Encapsulates all git operations needed by the cross-agent
# orchestrator and other code_check components.
#
# Functions:
#   is_git_repo <path>             — validate path is a git repo
#   get_head_sha <path>            — get current HEAD commit SHA
#   get_short_sha <path>           — get 8-char short SHA
#   get_default_branch <path>      — get default branch name
#   get_branch_name <path>         — get current branch name
#   is_detached_head <path>        — check if HEAD is detached
#   detect_changes <target> <last_sha> <since_ref> <full_mode>
#                                  — determine what changed
#   get_remote_url <path>          — get origin remote URL
#   has_uncommitted_changes <path> — check working tree status
#   fetch_origin <path>            — safely fetch from origin
# ============================================================

# ─── Validate that a path is a git repository ──────────────────────
is_git_repo() {
  local target="$1"
  git -C "$target" rev-parse --git-dir >/dev/null 2>&1
}

# ─── Get the current HEAD commit SHA ───────────────────────────────
get_head_sha() {
  local target="$1"
  git -C "$target" rev-parse HEAD 2>/dev/null || echo ""
}

# ─── Get 8-character short SHA ─────────────────────────────────────
get_short_sha() {
  local target="$1"
  git -C "$target" rev-parse --short=8 HEAD 2>/dev/null || echo ""
}

# ─── Get the default branch name (main or master) ──────────────────
get_default_branch() {
  local target="$1"
  # Try to resolve origin/HEAD
  local default
  default=$(git -C "$target" rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's|origin/||')
  if [[ -n "$default" ]] && [[ "$default" != "origin/HEAD" ]]; then
    echo "$default"
    return 0
  fi
  # Fall back to checking for main or master
  if git -C "$target" show-ref --verify --quiet refs/heads/main 2>/dev/null; then
    echo "main"
  elif git -C "$target" show-ref --verify --quiet refs/heads/master 2>/dev/null; then
    echo "master"
  else
    echo "main"
  fi
}

# ─── Get current branch name ───────────────────────────────────────
get_branch_name() {
  local target="$1"
  git -C "$target" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "DETACHED"
}

# ─── Check if HEAD is detached ─────────────────────────────────────
is_detached_head() {
  local target="$1"
  ! git -C "$target" symbolic-ref -q HEAD >/dev/null 2>&1
}

# ─── Get the origin remote URL ─────────────────────────────────────
get_remote_url() {
  local target="$1"
  git -C "$target" remote get-url origin 2>/dev/null || echo ""
}

# ─── Check for uncommitted changes ─────────────────────────────────
has_uncommitted_changes() {
  local target="$1"
  local status
  status=$(git -C "$target" status --porcelain 2>/dev/null || echo "")
  [[ -n "$status" ]]
}

# ─── Safely fetch from origin ──────────────────────────────────────
fetch_origin() {
  local target="$1"
  git -C "$target" fetch origin --no-tags 2>/dev/null || true
}

# ══════════════════════════════════════════════════════════════════
# Core: Detect Changes
# ══════════════════════════════════════════════════════════════════
#
# Determines what files have changed between the last checked SHA
# and the current HEAD. Handles first-run, full-scan, and incremental
# modes.
#
# After calling, the following variables are set for the caller:
#   DETECT_MODE       — "full" | "incremental" | "none"
#   DETECT_FROM_SHA   — base commit SHA (empty for full scan)
#   DETECT_TO_SHA     — current HEAD SHA
#   DETECT_FILES      — newline-separated list of changed files
#   DETECT_DIFF       — full diff content (empty in full mode)
#   DETECT_MESSAGE    — human-readable description of the range
#
# Arguments:
#   $1 - target repo path
#   $2 - last checked SHA (from state, empty if first run)
#   $3 - user-specified --since ref (optional)
#   $4 - full mode flag: "true" | "false"
#
# Returns: 0 on success, 1 if target is not a git repo
# ============================================================
detect_changes() {
  local target="$1"
  local last_sha="$2"
  local since_ref="$3"
  local full_mode="$4"

  # ─── Validate ───
  if ! is_git_repo "$target"; then
    echo "ERROR: '$target' is not a git repository" >&2
    return 1
  fi

  # ─── Get current HEAD ───
  DETECT_TO_SHA=$(get_head_sha "$target")
  if [[ -z "$DETECT_TO_SHA" ]]; then
    echo "ERROR: Cannot determine HEAD SHA for '$target' (empty repository?)" >&2
    return 1
  fi

  DETECT_FROM_SHA=""
  DETECT_MODE="full"
  DETECT_FILES=""
  DETECT_DIFF=""
  DETECT_MESSAGE=""

  # ─── Determine the "from" reference ───
  if [[ "$full_mode" == "true" ]]; then
    # Full mode: scan entire repo
    DETECT_MODE="full"
    DETECT_FROM_SHA=""
    DETECT_MESSAGE="Full repository scan at $(get_short_sha "$target")"
  elif [[ -n "$since_ref" ]]; then
    # User-specified reference
    if git -C "$target" cat-file -e "$since_ref" 2>/dev/null; then
      DETECT_FROM_SHA=$(git -C "$target" rev-parse "$since_ref" 2>/dev/null)
      DETECT_MODE="incremental"
      DETECT_MESSAGE="User-specified range: ${since_ref}..HEAD"
    else
      echo "ERROR: Invalid git reference: $since_ref" >&2
      return 1
    fi
  elif [[ -n "$last_sha" ]]; then
    # Incremental: diff from last checked SHA
    if git -C "$target" cat-file -e "$last_sha" 2>/dev/null; then
      DETECT_FROM_SHA="$last_sha"
      DETECT_MODE="incremental"
      DETECT_MESSAGE="Incremental: $(echo "$last_sha" | cut -c1-8)..$(echo "$DETECT_TO_SHA" | cut -c1-8)"
    else
      # Stored SHA no longer exists (rebased, force-pushed, shallow clone)
      echo "WARNING: Stored SHA $last_sha no longer exists in '$target'. Falling back to full scan." >&2
      DETECT_MODE="full"
      DETECT_FROM_SHA=""
      DETECT_MESSAGE="Full scan (previous SHA not found)"
    fi
  else
    # First run for this target — full scan
    DETECT_MODE="full"
    DETECT_FROM_SHA=""
    DETECT_MESSAGE="First run — full repository scan"
  fi

  # ─── Get changed files and diff content ───
  if [[ "$DETECT_MODE" == "incremental" ]]; then
    DETECT_FILES=$(git -C "$target" diff --name-only "$DETECT_FROM_SHA".."$DETECT_TO_SHA" 2>/dev/null || echo "")
    DETECT_DIFF=$(git -C "$target" diff "$DETECT_FROM_SHA".."$DETECT_TO_SHA" 2>/dev/null || echo "")

    # Check if there are any changes at all
    if [[ -z "$DETECT_FILES" ]]; then
      DETECT_MODE="none"
      DETECT_MESSAGE="No changes since last audit"
    fi
  else
    # Full mode: list all tracked text files
    DETECT_FILES=$(git -C "$target" ls-files 2>/dev/null || echo "")
    DETECT_DIFF=""  # We'll read files directly in full mode
  fi

  return 0
}
