#!/usr/bin/env bash
# ============================================================
# code_check/cross-agent/check.sh — Cross-Agent Library Audit
# ============================================================
# Orchestrates: change detection → debug → security audit → report
# Designed to be called by any AI agent (via Skill) or CI/CD.
#
# 用法:
#   bash cross-agent/check.sh <target_path>              # 增量检查
#   bash cross-agent/check.sh <target_path> --full       # 全量重扫
#   bash cross-agent/check.sh <target_path> --debug-only # 仅 debug
#   bash cross-agent/check.sh <target_path> --audit-only # 仅安全审计
#   bash cross-agent/check.sh <target_path> --json       # JSON 输出
#   bash cross-agent/check.sh <target_path> --since <ref># 从指定 ref 开始
#   bash cross-agent/check.sh --list                     # 列出追踪库
#   bash cross-agent/check.sh <target_path> --reset      # 重置状态
# ============================================================

set -euo pipefail

# ─── Resolve code_check root directory ────────────────────────────
CC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ─── Source shared libraries ──────────────────────────────────────
source "$CC_ROOT/lib/patterns.sh"
source "$CC_ROOT/lib/config.sh"
source "$CC_ROOT/lib/state.sh"
source "$CC_ROOT/lib/git-utils.sh"

# ─── Constants ────────────────────────────────────────────────────
REPORTS_DIR="$CC_ROOT/cross-agent/reports"
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')

# ─── Parse arguments ──────────────────────────────────────────────
TARGET=""
FULL_MODE="false"
DEBUG_ONLY="false"
AUDIT_ONLY="false"
JSON_OUTPUT="false"
SINCE_REF=""
RESET_MODE="false"
LIST_MODE="false"

args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --full)        FULL_MODE="true"; shift ;;
    --debug-only)  DEBUG_ONLY="true"; shift ;;
    --audit-only)  AUDIT_ONLY="true"; shift ;;
    --json)        JSON_OUTPUT="true"; shift ;;
    --since)       SINCE_REF="$2"; shift 2 ;;
    --reset)       RESET_MODE="true"; shift ;;
    --list)        LIST_MODE="true"; shift ;;
    --help|-h)
      echo "Cross-Agent Library Audit — 跨 Agent 库审计"
      echo ""
      echo "用法:"
      echo "  bash cross-agent/check.sh <target_path>              # 增量检查"
      echo "  bash cross-agent/check.sh <target_path> --full       # 全量重扫"
      echo "  bash cross-agent/check.sh <target_path> --debug-only # 仅代码调试"
      echo "  bash cross-agent/check.sh <target_path> --audit-only # 仅安全审计"
      echo "  bash cross-agent/check.sh <target_path> --json       # JSON 输出"
      echo "  bash cross-agent/check.sh <target_path> --since <ref># 从指定 ref 开始"
      echo "  bash cross-agent/check.sh --list                     # 列出追踪库"
      echo "  bash cross-agent/check.sh <target_path> --reset      # 重置状态"
      echo ""
      echo "选项:"
      echo "  --full         全量扫描（忽略增量状态）"
      echo "  --debug-only   仅执行代码调试分析"
      echo "  --audit-only   仅执行安全隐私审计"
      echo "  --json         以 JSON 格式输出报告"
      echo "  --since <ref>  从指定 git ref 开始检查"
      echo "  --list         列出所有追踪库"
      echo "  --reset        重置指定库的检查状态"
      exit 0
      ;;
    --*)           echo "Unknown option: $1"; exit 2 ;;
    *)             args+=("$1"); shift ;;
  esac
done

# ─── Handle meta commands ─────────────────────────────────────────
if [[ "$LIST_MODE" == "true" ]]; then
  echo -e "${BLUE}📋 Tracked Libraries${NC}"
  echo ""
  list_tracked
  exit 0
fi

# ─── Determine target path ────────────────────────────────────────
if [[ ${#args[@]} -gt 0 ]]; then
  TARGET="${args[0]}"
fi

if [[ "$RESET_MODE" == "true" ]]; then
  if [[ -z "$TARGET" ]]; then
    echo "用法: bash cross-agent/check.sh <target_path> --reset"
    exit 1
  fi
  purge_state "$TARGET"
  exit 0
fi

if [[ -z "$TARGET" ]]; then
  echo "用法: bash cross-agent/check.sh <target_path> [options]"
  echo "      bash cross-agent/check.sh --list"
  echo "      bash cross-agent/check.sh --help"
  exit 1
fi

# ─── Validate target ──────────────────────────────────────────────
if [[ ! -d "$TARGET" ]]; then
  echo -e "${RED}ERROR: Target path does not exist: $TARGET${NC}" >&2
  exit 2
fi

if ! is_git_repo "$TARGET"; then
  echo -e "${RED}ERROR: Target is not a git repository: $TARGET${NC}" >&2
  exit 2
fi

# ─── Resolve to absolute path ─────────────────────────────────────
TARGET_ABS="$(cd "$TARGET" && pwd)"
TARGET_NAME="$(basename "$TARGET_ABS")"

# ══════════════════════════════════════════════════════════════════
# Phase 1: Change Detection
# ══════════════════════════════════════════════════════════════════
echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Cross-Agent Library Audit                              ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Target:    $TARGET_ABS"
echo "  Time:      $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Load state to get last checked SHA
load_state "$TARGET" 2>/dev/null || true
LAST_SHA="${STATE_LAST_SHA:-}"

# Detect changes
detect_changes "$TARGET" "$LAST_SHA" "$SINCE_REF" "$FULL_MODE"
# detect_changes sets: DETECT_MODE, DETECT_FROM_SHA, DETECT_TO_SHA, DETECT_FILES, DETECT_DIFF, DETECT_MESSAGE

echo "  Mode:      $DETECT_MODE"
echo "  Range:     $DETECT_MESSAGE"
echo ""

# No changes → early exit
if [[ "$DETECT_MODE" == "none" ]]; then
  echo -e "${GREEN}✅ No changes since last audit. Library is up to date.${NC}"

  # Still update state timestamp
  save_state "$TARGET" "$DETECT_TO_SHA" "CLEAR" "0" '{"critical":0,"high":0,"medium":0}' 2>/dev/null || true

  if [[ "$JSON_OUTPUT" == "true" ]]; then
    cat <<JSON
{
  "conclusion": "CLEAR",
  "reason": "no_changes",
  "target": "$TARGET_ABS",
  "sha": "$DETECT_TO_SHA",
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
JSON
  fi
  exit 0
fi

# ─── Count changes ────────────────────────────────────────────────
FILES_CHANGED=$(echo "$DETECT_FILES" | grep -c '.' 2>/dev/null || echo "0")
if ! [[ "$FILES_CHANGED" =~ ^[0-9]+$ ]]; then FILES_CHANGED=0; fi

echo "  Files:     $FILES_CHANGED changed"
echo ""

# ─── Initialize counters ──────────────────────────────────────────
CRITICAL=0
HIGH=0
MEDIUM=0
DEBUG_ISSUES=0

# ─── Build diff content to scan ───────────────────────────────────
# In incremental mode: use the git diff
# In full mode: read all tracked text files
if [[ "$DETECT_MODE" == "full" ]]; then
  # Full mode: build content from all tracked text files
  FULL_CONTENT=""
  while IFS= read -r file; do
    if [[ -f "$TARGET/$file" ]]; then
      # Skip binary files (contain NULL bytes)
      if ! grep -qP '\x00' "$TARGET/$file" 2>/dev/null; then
        FULL_CONTENT+=$(cat "$TARGET/$file" 2>/dev/null || true)
        FULL_CONTENT+=$'\n'
      fi
    fi
  done <<< "$DETECT_FILES"
  SCAN_CONTENT="$FULL_CONTENT"
else
  SCAN_CONTENT="$DETECT_DIFF"
fi

# Extract only added/changed lines for audit scanning
# (In full mode, all lines are "added" since we're reading file contents directly)
if [[ "$DETECT_MODE" == "full" ]]; then
  DIFF_ADDED="$SCAN_CONTENT"
else
  DIFF_ADDED=$(echo "$SCAN_CONTENT" | grep -E '^\+[^+]' 2>/dev/null | sed 's/^+//' || echo "")
fi

# ══════════════════════════════════════════════════════════════════
# Phase 2: Security Audit
# ══════════════════════════════════════════════════════════════════
if [[ "$DEBUG_ONLY" != "true" ]]; then
  echo -e "${BLUE}┌── 🔒 Security Audit ──────────────────────────────────┐${NC}"

  # ─── 2a. Secrets ────────────────────────────────────────────────
  echo "│  Scanning secrets..."
  for entry in "${SECRET_PATTERNS[@]}"; do
    pattern="${entry%%:*}"
    rest="${entry#*:}"
    name="${rest%%:*}"
    level="${rest##*:}"

    if command -v should_ignore_pattern &>/dev/null && should_ignore_pattern "$name"; then
      continue
    fi

    MATCHES=$(echo "$DIFF_ADDED" | grep -oE -- "$pattern" 2>/dev/null | sort -u | head -5 || true)
    if [[ -n "$MATCHES" ]]; then
      print_result "$level" "$name"
      echo "$MATCHES" | while read -r m; do echo "│     $m"; done
      case "$level" in
        CRITICAL) CRITICAL=$((CRITICAL + 1)) ;;
        HIGH)     HIGH=$((HIGH + 1)) ;;
        MEDIUM)   MEDIUM=$((MEDIUM + 1)) ;;
      esac
    fi
  done

  # ─── 2b. High Entropy ───────────────────────────────────────────
  HIGH_ENTROPY=$(echo "$DIFF_ADDED" | grep -oE "[A-Za-z0-9+/=]{${ENTROPY_THRESHOLD:-40},}" 2>/dev/null | sort -u | head -10 || true)
  if [[ -n "$HIGH_ENTROPY" ]]; then
    for ex_pattern in "${ENTROPY_EXCLUDE_PATTERNS[@]}"; do
      HIGH_ENTROPY=$(echo "$HIGH_ENTROPY" | grep -vE "$ex_pattern" 2>/dev/null || true)
    done
  fi
  if [[ -n "$HIGH_ENTROPY" ]]; then
    print_result "MEDIUM" "High-entropy strings (possible keys/tokens)"
    echo "$HIGH_ENTROPY" | while read -r m; do echo "│     $m"; done
    MEDIUM=$((MEDIUM + 1))
  fi

  # ─── 2c. .env files ─────────────────────────────────────────────
  if echo "$DETECT_FILES" | grep -qE '(\.env$|\.env\.local$|\.env\.production$)' 2>/dev/null; then
    print_result "CRITICAL" ".env file(s) in changes — possible credential leak"
    CRITICAL=$((CRITICAL + 1))
  fi

  # ─── 2d. PII ────────────────────────────────────────────────────
  echo "│  Scanning PII..."
  for entry in "${PII_PATTERNS[@]}"; do
    pattern="${entry%%:*}"
    rest="${entry#*:}"
    name="${rest%%:*}"
    level="${rest##*:}"

    if command -v should_ignore_pattern &>/dev/null && should_ignore_pattern "$name"; then
      continue
    fi

    MATCHES=$(echo "$DIFF_ADDED" | grep -oE -- "$pattern" 2>/dev/null | sort -u | head -5 || true)

    # Email exclusion
    if [[ "$name" == "Email (non-test)" ]] && [[ -n "$MATCHES" ]]; then
      MATCHES=$(echo "$MATCHES" | grep -vE '(test@|example@|localhost|@test|@example|@localhost|your-?email)' 2>/dev/null || true)
    fi

    # IP exclusion
    if [[ "$name" == "IP Address (non-private)" ]] && [[ -n "$MATCHES" ]]; then
      MATCHES=$(echo "$MATCHES" | grep -vE '(^127\.|^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[01])\.|^0\.0\.0\.0|^169\.254\.|^22[4-9]\.|^23[0-9]\.)' 2>/dev/null || true)
    fi

    if [[ -n "$MATCHES" ]]; then
      print_result "$level" "$name"
      echo "$MATCHES" | while read -r m; do echo "│     $m"; done
      case "$level" in
        CRITICAL) CRITICAL=$((CRITICAL + 1)) ;;
        HIGH)     HIGH=$((HIGH + 1)) ;;
        MEDIUM)   MEDIUM=$((MEDIUM + 1)) ;;
      esac
    fi
  done

  # ─── 2e. Log Leaks ──────────────────────────────────────────────
  echo "│  Scanning log leaks..."
  for entry in "${LOG_LEAK_PATTERNS[@]}"; do
    pattern="${entry%%:*}"
    rest="${entry#*:}"
    name="${rest%%:*}"
    level="${rest##*:}"

    LOG_LEAKS=$(echo "$DIFF_ADDED" | grep -iE "$pattern" 2>/dev/null | head -5 || true)
    if [[ -n "$LOG_LEAKS" ]]; then
      print_result "$level" "Log leak: $name"
      echo "$LOG_LEAKS" | while read -r m; do echo "│     $m"; done
      case "$level" in
        CRITICAL) CRITICAL=$((CRITICAL + 1)) ;;
        HIGH)     HIGH=$((HIGH + 1)) ;;
      esac
    fi
  done

  # ─── 2f. Weak Crypto ────────────────────────────────────────────
  echo "│  Scanning weak crypto..."
  for entry in "${WEAK_CRYPTO_PATTERNS[@]}"; do
    pattern="${entry%%:*}"
    rest="${entry#*:}"
    name="${rest%%:*}"
    level="${rest##*:}"

    MATCHES=$(echo "$DIFF_ADDED" | grep -iE "$pattern" 2>/dev/null | head -5 || true)
    if [[ -n "$MATCHES" ]]; then
      print_result "$level" "Weak crypto: $name"
      echo "$MATCHES" | while read -r m; do echo "│     $m"; done
      case "$level" in
        CRITICAL) CRITICAL=$((CRITICAL + 1)) ;;
        HIGH)     HIGH=$((HIGH + 1)) ;;
        MEDIUM)   MEDIUM=$((MEDIUM + 1)) ;;
      esac
    fi
  done

  # ─── 2g. Dangerous Exec ─────────────────────────────────────────
  echo "│  Scanning dangerous functions..."
  for entry in "${DANGEROUS_EXEC_PATTERNS[@]}"; do
    pattern="${entry%%:*}"
    rest="${entry#*:}"
    name="${rest%%:*}"
    level="${rest##*:}"

    MATCHES=$(echo "$DIFF_ADDED" | grep -iE "$pattern" 2>/dev/null | head -5 || true)
    if [[ -n "$MATCHES" ]]; then
      print_result "$level" "Dangerous function: $name"
      echo "$MATCHES" | while read -r m; do echo "│     $m"; done
      case "$level" in
        CRITICAL) CRITICAL=$((CRITICAL + 1)) ;;
        HIGH)     HIGH=$((HIGH + 1)) ;;
      esac
    fi
  done

  echo -e "${BLUE}└────────────────────────────────────────────────────────┘${NC}"
  echo ""
fi

# ══════════════════════════════════════════════════════════════════
# Phase 3: Code Debugging
# ══════════════════════════════════════════════════════════════════
if [[ "$AUDIT_ONLY" != "true" ]]; then
  echo -e "${BLUE}┌── 🔍 Code Debugging ──────────────────────────────────┐${NC}"

  # ─── 3a. Tag markers (TODO, FIXME, HACK, XXX, BUG) ──────────────
  echo "│  Scanning code markers..."
  if [[ "$DETECT_MODE" == "full" ]]; then
    MARKERS=$(grep -rnE '\b(TODO|FIXME|HACK|XXX|BUG)\b' "$TARGET" \
      --include='*.go' --include='*.py' --include='*.js' --include='*.ts' \
      --include='*.java' --include='*.rs' --include='*.c' --include='*.cpp' \
      --include='*.sh' --include='*.rb' --include='*.php' --include='*.cs' \
      --include='*.yaml' --include='*.yml' --include='*.toml' --include='*.md' \
      2>/dev/null | head -20 || echo "")
  else
    MARKERS=$(echo "$SCAN_CONTENT" | grep -nE '^\+.*\b(TODO|FIXME|HACK|XXX|BUG)\b' 2>/dev/null | head -20 || echo "")
  fi

  if [[ -n "$MARKERS" ]]; then
    MARKER_COUNT=$(count_lines "$MARKERS")
    echo "│  ${YELLOW}⚠ Code markers: $MARKER_COUNT found${NC}"
    echo "$MARKERS" | head -10 | while read -r m; do echo "│     $m"; done
    DEBUG_ISSUES=$((DEBUG_ISSUES + MARKER_COUNT))
  else
    echo "│  ${GREEN}✅ No code markers found${NC}"
  fi

  # ─── 3b. Null/undefined risk patterns ───────────────────────────
  if [[ "$DETECT_MODE" != "full" ]]; then
    NULL_RISK=$(echo "$SCAN_CONTENT" | grep -nE '^\+.*(\.(unwrap|expect)\()|(\bnil\b|\bNULL\b|\bnull\b|\bundefined\b|\bNone\b)' 2>/dev/null | head -10 || echo "")
    if [[ -n "$NULL_RISK" ]]; then
      echo "│  ${CYAN}📋 Null-risk patterns detected${NC}"
      echo "$NULL_RISK" | while read -r m; do echo "│     $m"; done
    fi
  fi

  # ─── 3c. Long lines ────────────────────────────────────────────
  if [[ "$DETECT_MODE" != "full" ]]; then
    LONG_LINES=$(echo "$DIFF_ADDED" | grep -cE '.{121,}' 2>/dev/null || echo "0")
    if [[ "$LONG_LINES" -gt 0 ]]; then
      echo "│  ${CYAN}📋 Long lines (>120 chars): $LONG_LINES${NC}"
    fi
  fi

  # ─── 3d. Security markers ───────────────────────────────────────
  if [[ "$DETECT_MODE" != "full" ]]; then
    SEC_MARKERS=$(echo "$SCAN_CONTENT" | grep -nE '^\+.*\b(SECURITY|VULN|CVE-|XSS|CSRF|SQL\s*INJECTION)' 2>/dev/null | head -5 || echo "")
    if [[ -n "$SEC_MARKERS" ]]; then
      echo "│  ${RED}🛑 Security-related markers found${NC}"
      echo "$SEC_MARKERS" | while read -r m; do echo "│     $m"; done
    fi
  fi

  echo -e "${BLUE}└────────────────────────────────────────────────────────┘${NC}"
  echo ""
fi

# ══════════════════════════════════════════════════════════════════
# Phase 4: Report & State Persistence
# ══════════════════════════════════════════════════════════════════

# ─── Determine verdict ────────────────────────────────────────────
if [[ "$CRITICAL" -gt 0 ]]; then
  VERDICT="BLOCKED"
  VERDICT_ICON="🛑"
elif [[ "$HIGH" -gt 0 ]]; then
  VERDICT="WARNINGS"
  VERDICT_ICON="⚠️"
elif [[ "$MEDIUM" -gt 0 ]] || [[ "$DEBUG_ISSUES" -gt 0 ]]; then
  VERDICT="WARNINGS"
  VERDICT_ICON="⚠️"
else
  VERDICT="CLEAR"
  VERDICT_ICON="✅"
fi

# ─── JSON output mode ─────────────────────────────────────────────
if [[ "$JSON_OUTPUT" == "true" ]]; then
  cat <<JSON
{
  "conclusion": "$VERDICT",
  "target": "$TARGET_ABS",
  "target_name": "$TARGET_NAME",
  "branch": "$(get_branch_name "$TARGET")",
  "sha": "$DETECT_TO_SHA",
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "mode": "$DETECT_MODE",
  "range": "$DETECT_MESSAGE",
  "summary": {
    "critical": $CRITICAL,
    "high": $HIGH,
    "medium": $MEDIUM,
    "debug_issues": $DEBUG_ISSUES,
    "files_changed": $FILES_CHANGED
  }
}
JSON
  # Save state
  FINDINGS_JSON="{\"critical\":$CRITICAL,\"high\":$HIGH,\"medium\":$MEDIUM}"
  save_state "$TARGET" "$DETECT_TO_SHA" "$VERDICT" "$FILES_CHANGED" "$FINDINGS_JSON" 2>/dev/null || true

  # Exit with appropriate code
  if [[ "$VERDICT" == "BLOCKED" ]]; then exit 2
  elif [[ "$VERDICT" == "WARNINGS" ]]; then exit 1
  else exit 0
  fi
fi

# ─── Markdown report ──────────────────────────────────────────────
REPORT_FILE="$REPORTS_DIR/audit-${TIMESTAMP}-${TARGET_NAME}.md"
mkdir -p "$REPORTS_DIR"

cat > "$REPORT_FILE" <<REPORT
# 🔍 Cross-Agent Library Audit Report

**Target**: \`$TARGET_ABS\`
**Repository**: $(get_remote_url "$TARGET")
**Branch**: $(get_branch_name "$TARGET") (HEAD: \`${DETECT_TO_SHA:0:8}\`)
**Audit Time**: $(date '+%Y-%m-%d %H:%M:%S')
**Mode**: $DETECT_MODE
**Range**: $DETECT_MESSAGE

---

## 📊 Change Summary

| Metric | Value |
|--------|-------|
| Files changed | $FILES_CHANGED |
| Mode | $DETECT_MODE |

---

## 🔒 Security Audit

| Level | Found |
|-------|-------|
| 🔴 CRITICAL | $CRITICAL |
| 🟠 HIGH | $HIGH |
| 🟡 MEDIUM | $MEDIUM |

$(if [[ "$CRITICAL" -eq 0 && "$HIGH" -eq 0 && "$MEDIUM" -eq 0 ]]; then
  echo "✅ **Passed** — No security issues found."
else
  echo "⚠️  See detailed findings above."
fi)

---

## 🔍 Code Debugging

- Code markers (TODO/FIXME/etc): $DEBUG_ISSUES found

$(if [[ "$DEBUG_ISSUES" -eq 0 ]]; then
  echo "✅ **Clean** — No code quality markers found."
else
  echo "📋 See markers listed above."
fi)

---

## 🏁 Verdict

### $VERDICT_ICON $VERDICT

| Level | Count | Status |
|-------|-------|--------|
| 🔴 CRITICAL | $CRITICAL | $(if [[ "$CRITICAL" -gt 0 ]]; then echo "❌ FAILED"; else echo "✅ PASS"; fi) |
| 🟠 HIGH | $HIGH | $(if [[ "$HIGH" -gt 0 ]]; then echo "⚠️ WARN"; else echo "✅ PASS"; fi) |
| 🟡 MEDIUM | $MEDIUM | $(if [[ "$MEDIUM" -gt 0 ]]; then echo "📋 INFO"; else echo "✅ PASS"; fi) |
| 🔍 Debug | $DEBUG_ISSUES | $(if [[ "$DEBUG_ISSUES" -gt 0 ]]; then echo "📋 INFO"; else echo "✅ PASS"; fi) |

---

## 📁 State

- **Next incremental check** will diff from: \`$DETECT_TO_SHA\`
- **State file**: \`$(state_filename "$TARGET")\`
- **Report file**: \`$REPORT_FILE\`

---
*Generated by code_check cross-agent-audit v2.1*
REPORT

# ─── Output report ─────────────────────────────────────────────────
cat "$REPORT_FILE"

# ─── Save state ────────────────────────────────────────────────────
FINDINGS_JSON="{\"critical\":$CRITICAL,\"high\":$HIGH,\"medium\":$MEDIUM,\"debug_issues\":$DEBUG_ISSUES}"
save_state "$TARGET" "$DETECT_TO_SHA" "$VERDICT" "$FILES_CHANGED" "$FINDINGS_JSON" 2>/dev/null || true

echo ""
echo -e "${BLUE}Report saved: $REPORT_FILE${NC}"

# ─── Exit with appropriate code ────────────────────────────────────
if [[ "$VERDICT" == "BLOCKED" ]]; then
  exit 2
elif [[ "$VERDICT" == "WARNINGS" ]]; then
  exit 1
else
  exit 0
fi
