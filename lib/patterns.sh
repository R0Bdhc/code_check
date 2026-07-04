#!/usr/bin/env bash
# ============================================================
# code_check/lib/patterns.sh — Shared detection patterns & utilities
# ============================================================
# Canonical pattern definitions sourced by all bash consumers.
# Generated from patterns.json — do not edit manually.
# Regenerate: node scripts/generate-patterns-sh.js
# ============================================================

# --- Color Constants ---
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Severity Levels ---
LEVEL_CRITICAL=3
LEVEL_HIGH=2
LEVEL_MEDIUM=1
LEVEL_INFO=0

# --- Entropy Configuration ---
ENTROPY_THRESHOLD=40
ENTROPY_EXCLUDE_PATTERNS=(
  '^[0-9a-fA-F]{40}$'
  '^[0-9a-fA-F]{64}$'
  '^[0-9a-fA-F]{128}$'
  '^index\s+[0-9a-f]{7,}'
)

# --- Secret Patterns (pattern:Name:Level) ---
# Format: "regex:name:level" where level is CRITICAL|HIGH|MEDIUM
SECRET_PATTERNS=(
  'AKIA[0-9A-Z]{16}:AWS Access Key:CRITICAL'
  'sk_live_[0-9a-zA-Z]{24,}:Stripe Live Key:CRITICAL'
  'ghp_[0-9a-zA-Z]{36}:GitHub Token:CRITICAL'
  'gho_[0-9a-zA-Z]{36}:GitHub OAuth:CRITICAL'
  'github_pat_[A-Za-z0-9_]{36,}:GitHub Fine-grained PAT:CRITICAL'
  'xox[baprs]-[0-9a-zA-Z-]{10,}:Slack Token:CRITICAL'
  'AIza[0-9A-Za-z\-_]{35}:Google API Key:CRITICAL'
  'sk-(proj-|org-)?[A-Za-z0-9]{32,}:OpenAI API Key:CRITICAL'
  'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}:JWT Token:CRITICAL'
  '-----BEGIN (RSA|EC|DSA|OPENSSH) PRIVATE KEY-----:Private Key Block:CRITICAL'
  '(secret|token|password|api_key|apikey)\s*[:=]\s*["\047][^"\047]{8,}["\047]:Generic Secret Assignment:CRITICAL'
)

# --- PII Patterns (pattern:Name:Level) ---
PII_PATTERNS=(
  '1[3-9][0-9]{9}:Chinese Phone:HIGH'
  '[1-9][0-9]{5}(19|20)[0-9]{2}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])[0-9]{3}[0-9Xx]:Chinese ID Card:CRITICAL'
  '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}:Email (non-test):HIGH'
  '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:IP Address (non-private):MEDIUM'
)

# --- Log Leak Patterns (pattern:Name:Level) ---
LOG_LEAK_PATTERNS=(
  '(console\.(log|error|warn|debug|info)|println!|log\.|logger\.|logging\.).*(password|secret|token|key|credential|pii|ssn|credit|card):Log Sensitive Data:CRITICAL'
)

# --- Weak Crypto Patterns (pattern:Name:Level) ---
WEAK_CRYPTO_PATTERNS=(
  '(MD5|SHA-?1):Weak Hash:HIGH'
  '(DES|RC4|ECB\s+mode):Weak Cipher:MEDIUM'
)

# --- Dangerous Exec Patterns (pattern:Name:Level) ---
DANGEROUS_EXEC_PATTERNS=(
  '(eval|exec|system|shell_exec|popen|subprocess\.call)\s*\(:Dangerous Function Call:HIGH'
)

# ============================================================
# Helper Functions
# ============================================================

# Count non-empty lines in input
# Usage: count_lines "$VAR"
count_lines() {
  local input="$1"
  if [[ -z "$input" ]]; then
    echo "0"
  else
    echo "$input" | grep -c '.' 2>/dev/null || echo "0"
  fi
}

# Scan diff for a single pattern, return matches (sorted, unique, max 10)
# Usage: scan_pattern "$DIFF" "regex" "exclude_regex"
scan_pattern() {
  local diff="$1"
  local pattern="$2"
  local exclude="${3:-}"
  local matches

  matches=$(echo "$diff" | grep -oE -- "$pattern" 2>/dev/null | sort -u | head -10 || true)

  # Apply exclude filter if provided
  if [[ -n "$exclude" ]] && [[ -n "$matches" ]]; then
    matches=$(echo "$matches" | grep -vE "$exclude" 2>/dev/null || true)
  fi

  echo "$matches"
}

# Scan only added lines (not removed lines) for secrets
# Usage: scan_added_lines "$DIFF" "pattern"
scan_added_lines() {
  local diff="$1"
  local pattern="$2"

  # Extract only lines starting with + (but not +++), then remove the + prefix
  echo "$diff" | grep -E '^\+[^+]' 2>/dev/null | sed 's/^+//' | grep -oE -- "$pattern" 2>/dev/null | sort -u | head -10 || true
}

# Check if a value is numeric
is_numeric() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

# Resolve the diff range for git operations
# Usage: resolve_diff_range
# Returns: Sets RANGE and DIFF_CMD global variables
resolve_diff_range() {
  local remote_sha="${1:-}"
  local local_sha="${2:-}"

  if [[ "$remote_sha" == "0000000000000000000000000000000000000000" ]]; then
    # New branch — find merge base with main/master
    local base
    base=$(git merge-base origin/main HEAD 2>/dev/null || git merge-base origin/master HEAD 2>/dev/null || git rev-list --max-parents=0 HEAD 2>/dev/null || echo "")
    if [[ -n "$base" ]]; then
      RANGE="${base}..${local_sha}"
    else
      RANGE=""
    fi
  else
    RANGE="${remote_sha}..${local_sha}"
  fi

  if [[ -n "$RANGE" ]]; then
    DIFF_CMD="git diff ${RANGE}"
  else
    DIFF_CMD="git diff HEAD"
  fi
}

# Clean up temporary git branches created during audit
# Usage: register_cleanup "branch-name"
register_cleanup() {
  local branch="$1"
  trap "git branch -D '${branch}' 2>/dev/null || true" EXIT
}
