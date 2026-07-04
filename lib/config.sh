#!/usr/bin/env bash
# ============================================================
# code_check/lib/config.sh — Shared configuration & utilities
# ============================================================
# Sourced by bash consumers to load .code_check.yml project config
# and provide shared helper functions.
# ============================================================

# Find the git repo root
git_root() {
  git rev-parse --show-toplevel 2>/dev/null || echo ""
}

# Load project-level .code_check.yml config (simple flat-key parser)
# Sets: CC_REVIEW_MODE, CC_SKIP_REVIEW, CC_IGNORE_PATHS[], CC_IGNORE_PATTERNS[]
load_project_config() {
  local root
  root=$(git_root)
  local config_file="${root}/.code_check.yml"

  # Defaults
  CC_REVIEW_MODE="${REVIEW_MODE:-normal}"
  CC_SKIP_REVIEW="${SKIP_REVIEW:-0}"
  CC_IGNORE_PATHS=()
  CC_IGNORE_PATTERNS=()

  if [[ ! -f "$config_file" ]]; then
    return 0
  fi

  # Parse simple YAML keys (does not handle nesting or complex YAML)
  local mode
  mode=$(grep -E '^\s*review_mode:\s*' "$config_file" 2>/dev/null | head -1 | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" | xargs)
  if [[ -n "$mode" ]]; then
    CC_REVIEW_MODE="$mode"
  fi

  local skip
  skip=$(grep -E '^\s*skip_review:\s*' "$config_file" 2>/dev/null | head -1 | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" | xargs)
  if [[ "$skip" == "true" ]] || [[ "$skip" == "1" ]]; then
    CC_SKIP_REVIEW=1
  fi

  # Parse ignore_paths (simple list)
  local in_ignore=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*ignore_paths: ]]; then
      in_ignore=1
      continue
    fi
    if [[ $in_ignore -eq 1 ]]; then
      if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+ ]]; then
        local path
        path=$(echo "$line" | sed 's/.*-[[:space:]]*//' | tr -d '"' | tr -d "'" | xargs)
        CC_IGNORE_PATHS+=("$path")
      elif [[ "$line" =~ ^[[:space:]]*[a-zA-Z] ]]; then
        # Next section — stop parsing ignore_paths
        in_ignore=0
      fi
    fi
  done < "$config_file"

  # Parse ignore_patterns
  local in_ignore_pat=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*ignore_patterns: ]]; then
      in_ignore_pat=1
      continue
    fi
    if [[ $in_ignore_pat -eq 1 ]]; then
      if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+ ]]; then
        local pat
        pat=$(echo "$line" | sed 's/.*-[[:space:]]*//' | tr -d '"' | tr -d "'" | xargs)
        CC_IGNORE_PATTERNS+=("$pat")
      elif [[ "$line" =~ ^[[:space:]]*[a-zA-Z] ]]; then
        in_ignore_pat=0
      fi
    fi
  done < "$config_file"
}

# Check if a file path should be ignored based on ignore_paths config
# Usage: should_ignore_path "src/main.go" → returns 0 if should ignore
should_ignore_path() {
  local file_path="$1"
  for ignore in "${CC_IGNORE_PATHS[@]}"; do
    if [[ "$file_path" == $ignore ]] || [[ "$file_path" == $ignore* ]]; then
      return 0
    fi
  done
  return 1
}

# Check if a pattern name should be ignored
# Usage: should_ignore_pattern "AWS Access Key" → returns 0 if should ignore
should_ignore_pattern() {
  local pattern_name="$1"
  for name in "${CC_IGNORE_PATTERNS[@]}"; do
    if [[ "$pattern_name" == "$name" ]]; then
      return 0
    fi
  done
  return 1
}

# Filter out ignored patterns from a patterns array
# Usage: filter_ignored_patterns PATTERNS_ARRAY
# Modifies the global array in-place by filtering out entries whose name matches CC_IGNORE_PATTERNS
filter_patterns() {
  local -n arr=$1  # nameref to the array
  local filtered=()
  for entry in "${arr[@]}"; do
    local name="${entry##*:}"  # Last field after :
    # entry format: "regex:Name:Level" — name is the middle field
    name=$(echo "$entry" | cut -d: -f2)
    if ! should_ignore_pattern "$name"; then
      filtered+=("$entry")
    fi
  done
  arr=("${filtered[@]}")
}

# Print a summary line with color
# Usage: print_result CRITICAL "Found secret"
print_result() {
  local level="$1"
  local message="$2"
  case "$level" in
    CRITICAL) echo -e "  ${RED}🛑 $message${NC}" ;;
    HIGH)     echo -e "  ${YELLOW}⚠️  $message${NC}" ;;
    MEDIUM)   echo -e "  ${CYAN}📋 $message${NC}" ;;
    *)        echo -e "  $message" ;;
  esac
}
