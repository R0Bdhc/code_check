#!/usr/bin/env bash
# ============================================================
# code_check/lib/state.sh — Cross-Agent State Management
# ============================================================
# Persist and retrieve check state for cross-agent library audit.
# State files are stored JSON files keyed by MD5 hash of the
# absolute target path, avoiding collision and filename length issues.
#
# Functions:
#   init_state_dir           — ensure state/ directory exists
#   state_filename <target>  — compute state file path from target
#   load_state <target>      — load last-checked SHA and metadata
#   save_state <target> <sha> <verdict> <files> <findings_json>
#   purge_state <target>     — delete state for a target
#   list_tracked             — list all tracked libraries
#   is_first_run <target>    — check if target has never been checked
# ============================================================

# Determine CC_ROOT (code_check root directory)
# When sourced from cross-agent/orchestrator.sh: ../lib/state.sh
# When sourced from other scripts: try relative paths
if [[ -z "${CC_ROOT:-}" ]]; then
  _state_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CC_ROOT="$(cd "$_state_script_dir/.." && pwd)"
fi

STATE_DIR="${CC_ROOT}/state"
readonly STATE_DIR

# ─── Ensure state directory exists ────────────────────────────────
init_state_dir() {
  if [[ ! -d "$STATE_DIR" ]]; then
    mkdir -p "$STATE_DIR" 2>/dev/null || {
      echo "WARNING: Cannot create state directory: $STATE_DIR" >&2
      return 1
    }
  fi
  return 0
}

# ─── Compute state filename from target path ──────────────────────
# Uses MD5 hash to avoid collision and path-length issues.
# Stores the human-readable path inside the JSON for discoverability.
state_filename() {
  local target="$1"

  # Resolve to absolute path
  local abs
  if [[ -d "$target" ]]; then
    abs="$(cd "$target" 2>/dev/null && pwd || echo "$target")"
  else
    abs="$target"
  fi

  # Normalize: lowercase drive letter on Windows, forward slashes
  abs=$(echo "$abs" | sed 's|\\|/|g' | sed 's|^\([A-Z]\):|/\L\1|')

  # Compute MD5 hash (use md5sum on Linux, md5 on macOS)
  local hash
  if command -v md5sum &>/dev/null; then
    hash=$(echo -n "$abs" | md5sum | cut -d' ' -f1)
  elif command -v md5 &>/dev/null; then
    hash=$(echo -n "$abs" | md5 -q)
  else
    # Fallback: sanitize path to filename (no hash tool available)
    hash=$(echo "$abs" | sed 's|[^a-zA-Z0-9_-]|-|g' | sed 's|-\{2,\}|-|g')
  fi

  echo "${STATE_DIR}/${hash}.json"
}

# ─── Load state for a target path ─────────────────────────────────
# Sets global variables:
#   STATE_LAST_SHA        — last checked commit SHA ("" if first run)
#   STATE_LAST_AT         — ISO timestamp of last check
#   STATE_LAST_VERDICT    — last verdict: CLEAR/WARNINGS/BLOCKED
#   STATE_CHECK_COUNT     — total number of checks performed
#   STATE_TARGET_REMOTE   — remote URL of the target repo
#   STATE_TARGET_BRANCH   — branch name from last check
load_state() {
  local target="$1"
  init_state_dir

  local state_file
  state_file=$(state_filename "$target")

  # Defaults (first-run values)
  STATE_LAST_SHA=""
  STATE_LAST_AT=""
  STATE_LAST_VERDICT=""
  STATE_CHECK_COUNT=0
  STATE_TARGET_REMOTE=""
  STATE_TARGET_BRANCH=""

  if [[ ! -f "$state_file" ]]; then
    return 1  # No state exists — first run
  fi

  # Parse JSON with grep/sed (no jq dependency)
  # We use simple pattern matching since we control the JSON format
  STATE_LAST_SHA=$(grep -oE '"last_checked_sha"\s*:\s*"[^"]*"' "$state_file" 2>/dev/null \
    | head -1 | sed 's/.*: *"//' | sed 's/"$//')
  STATE_LAST_AT=$(grep -oE '"last_checked_at"\s*:\s*"[^"]*"' "$state_file" 2>/dev/null \
    | head -1 | sed 's/.*: *"//' | sed 's/"$//')
  STATE_LAST_VERDICT=$(grep -oE '"last_verdict"\s*:\s*"[^"]*"' "$state_file" 2>/dev/null \
    | head -1 | sed 's/.*: *"//' | sed 's/"$//')
  STATE_CHECK_COUNT=$(grep -oE '"check_count"\s*:\s*[0-9]+' "$state_file" 2>/dev/null \
    | head -1 | sed 's/.*: *//')
  STATE_TARGET_REMOTE=$(grep -oE '"target_remote_url"\s*:\s*"[^"]*"' "$state_file" 2>/dev/null \
    | head -1 | sed 's/.*: *"//' | sed 's/"$//')
  STATE_TARGET_BRANCH=$(grep -oE '"target_branch"\s*:\s*"[^"]*"' "$state_file" 2>/dev/null \
    | head -1 | sed 's/.*: *"//' | sed 's/"$//')

  # Validate numeric
  if ! [[ "${STATE_CHECK_COUNT}" =~ ^[0-9]+$ ]]; then
    STATE_CHECK_COUNT=0
  fi

  return 0
}

# ─── Save state after a successful check ──────────────────────────
# Arguments:
#   $1 - target path
#   $2 - HEAD SHA
#   $3 - verdict (CLEAR/WARNINGS/BLOCKED)
#   $4 - files changed count
#   $5 - findings JSON string: '{"critical":0,"high":1,"medium":2}'
save_state() {
  local target="$1"
  local sha="$2"
  local verdict="${3:-CLEAR}"
  local files_changed="${4:-0}"
  local findings_json="${5:-{\"critical\":0,\"high\":0,\"medium\":0}}"
  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  init_state_dir
  local state_file
  state_file=$(state_filename "$target")

  # Get absolute path for storage
  local abs
  abs="$(cd "$target" 2>/dev/null && pwd || echo "$target")"

  # Get remote URL
  local remote_url
  remote_url=$(git -C "$target" remote get-url origin 2>/dev/null || echo "")

  # Get branch name
  local branch
  branch=$(git -C "$target" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "DETACHED")

  # Load existing state to get check_count and first_checked_at
  load_state "$target" 2>/dev/null || true
  local prev_count="${STATE_CHECK_COUNT:-0}"
  local new_count=$((prev_count + 1))
  local first_at="${STATE_LAST_AT:-$timestamp}"

  # Build history entry
  local short_sha="${sha:0:8}"
  local history_entry
  history_entry=$(cat <<HIST
    {
      "sha": "${sha}",
      "short": "${short_sha}",
      "at": "${timestamp}",
      "verdict": "${verdict}",
      "files_changed": ${files_changed}
    }
HIST
)

  # If we have previous history, prepend this entry
  local prev_history
  prev_history=$(grep -oE '"history"\s*:\s*\[.*\]' "$state_file" 2>/dev/null | sed 's/"history"\s*:\s*//' || echo "[]")
  # Trim trailing ] to prepend
  if [[ "$prev_history" == "[]" ]]; then
    local new_history="[${history_entry}]"
  else
    # Remove leading [ and trailing ], prepend new entry
    local inner
    inner=$(echo "$prev_history" | sed 's/^\[//' | sed 's/\]$//')
    # Keep last 9 entries + new one = 10 max
    inner=$(echo "$inner" | head -9)
    new_history="[${history_entry},${inner}]"
  fi

  # Write state file atomically (write to temp, then rename)
  local tmp_file="${state_file}.tmp.$$"
  cat > "$tmp_file" <<JSON
{
  "\$schema": "cross-agent-audit-state-v1",
  "target": "${abs}",
  "target_remote_url": "${remote_url}",
  "target_branch": "${branch}",
  "last_checked_sha": "${sha}",
  "last_checked_short": "${short_sha}",
  "last_checked_at": "${timestamp}",
  "last_verdict": "${verdict}",
  "last_summary": ${findings_json},
  "check_count": ${new_count},
  "first_checked_at": "${first_at}",
  "history": ${new_history}
}
JSON

  # Atomic rename
  mv "$tmp_file" "$state_file" 2>/dev/null || {
    # If mv fails (e.g., cross-device), copy then remove
    cp "$tmp_file" "$state_file" 2>/dev/null && rm -f "$tmp_file"
  }
}

# ─── Delete state for a target ─────────────────────────────────────
purge_state() {
  local target="$1"
  local state_file
  state_file=$(state_filename "$target")
  if [[ -f "$state_file" ]]; then
    rm -f "$state_file"
    echo "State purged: $(basename "$state_file")"
  fi
}

# ─── Check if target has never been checked ────────────────────────
is_first_run() {
  local target="$1"
  local state_file
  state_file=$(state_filename "$target")
  [[ ! -f "$state_file" ]]
}

# ─── List all tracked libraries ────────────────────────────────────
list_tracked() {
  init_state_dir
  local count=0
  for f in "$STATE_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    count=$((count + 1))
    local target
    target=$(grep -oE '"target"\s*:\s*"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*: *"//' | sed 's/"$//')
    local last_at
    last_at=$(grep -oE '"last_checked_at"\s*:\s*"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*: *"//' | sed 's/"$//')
    local verdict
    verdict=$(grep -oE '"last_verdict"\s*:\s*"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*: *"//' | sed 's/"$//')
    local count_n
    count_n=$(grep -oE '"check_count"\s*:\s*[0-9]+' "$f" 2>/dev/null | head -1 | sed 's/.*: *//')

    echo "  ${target:-unknown}"
    echo "    Last: ${last_at:-never} | Verdict: ${verdict:-N/A} | Checks: ${count_n:-0}"
    echo "    State: $(basename "$f")"
    echo ""
  done

  if [[ $count -eq 0 ]]; then
    echo "  (no libraries tracked yet)"
  fi
}

# ─── Initialize on source ──────────────────────────────────────────
init_state_dir
