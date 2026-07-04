#!/usr/bin/env bash
# ============================================================
# code_check/audit/audit-trigger.sh
# Pull Request 触发式安全隐私审计
# ============================================================
# 用法:
#   由 CI 或 Agent 在 git pull / PR open 时自动调用
#   bash audit/audit-trigger.sh <PR_NUMBER>
#   bash audit/audit-trigger.sh --branch <branch>
#   bash audit/audit-trigger.sh --diff
#   bash audit/audit-trigger.sh --dry-run --diff
# ============================================================

set -euo pipefail

# --- 确定脚本目录 ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- 加载共享库 ---
if [[ -f "$SCRIPT_DIR/../lib/patterns.sh" ]]; then
  source "$SCRIPT_DIR/../lib/patterns.sh"
fi
if [[ -f "$SCRIPT_DIR/../lib/config.sh" ]]; then
  source "$SCRIPT_DIR/../lib/config.sh"
fi

# --- 加载项目配置 ---
load_project_config 2>/dev/null || true

echo -e "${BLUE}🛡️ Pull Audit — 安全隐私审计启动${NC}"
echo ""

DRY_RUN=0

# ─── 参数解析 ───
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
  esac
done

# ─── 获取变更 ───
DIFF=""
PR_NUM=""

case "${1:-}" in
  --dry-run)
    DRY_RUN=1
    # 继续处理后面的参数
    case "${2:-}" in
      --branch)
        BRANCH="${3:-}"
        if [[ -z "$BRANCH" ]]; then
          echo "用法: bash audit/audit-trigger.sh --dry-run --branch <branch>"
          exit 1
        fi
        echo "→ 审计分支: $BRANCH vs origin/main"
        git fetch origin main 2>/dev/null || true
        DIFF=$(git diff origin/main..."$BRANCH" 2>/dev/null || git diff main..."$BRANCH" 2>/dev/null || echo "")
        ;;
      --diff)
        echo "→ 审计 staged diff"
        DIFF=$(git diff --staged 2>/dev/null || echo "")
        ;;
      *)
        echo "→ 审计当前分支 vs origin/main"
        DIFF=$(git diff origin/main...HEAD 2>/dev/null || git diff main...HEAD 2>/dev/null || echo "")
        ;;
    esac
    ;;
  --branch)
    BRANCH="${2:-}"
    if [[ -z "$BRANCH" ]]; then
      echo "用法: bash audit/audit-trigger.sh --branch <branch>"
      exit 1
    fi
    echo "→ 审计分支: $BRANCH vs origin/main"
    git fetch origin main 2>/dev/null || true
    DIFF=$(git diff origin/main..."$BRANCH" 2>/dev/null || git diff main..."$BRANCH" 2>/dev/null || echo "")
    ;;

  --diff)
    echo "→ 审计 staged diff"
    DIFF=$(git diff --staged 2>/dev/null || echo "")
    ;;

  *)
    PR="${1:-}"
    if [[ -n "$PR" ]] && [[ "$PR" =~ ^[0-9]+$ ]]; then
      PR_NUM="$PR"
      echo "→ 审计 PR #${PR}"
      if command -v gh &>/dev/null; then
        DIFF=$(gh pr diff "$PR" --color=never 2>/dev/null || echo "")
      fi
      if [[ -z "$DIFF" ]]; then
        git fetch origin "pull/${PR}/head:pr-${PR}" 2>/dev/null || true
        # 注册清理 — 审计结束后删除临时分支
        register_cleanup "pr-${PR}"
        DIFF=$(git diff main..."pr-${PR}" 2>/dev/null || git diff master..."pr-${PR}" 2>/dev/null || echo "")
      fi
    else
      echo "→ 审计当前分支 vs origin/main"
      DIFF=$(git diff origin/main...HEAD 2>/dev/null || git diff main...HEAD 2>/dev/null || echo "")
    fi
    ;;
esac

if [[ -z "$DIFF" ]]; then
  echo -e "${YELLOW}无变更内容，审计跳过${NC}"
  exit 0
fi

# ─── 统计 (仅计算新增行，排除 +++ diff headers) ───
FILES_CHANGED=$(echo "$DIFF" | grep -c '^diff --git' 2>/dev/null || echo "0")
LINES_ADDED=$(echo "$DIFF" | grep -cE '^\+[^+]' 2>/dev/null || echo "0")
LINES_DELETED=$(echo "$DIFF" | grep -cE '^\-[^-]' 2>/dev/null || echo "0")

# Sanitize — ensure numeric
if ! [[ "$FILES_CHANGED" =~ ^[0-9]+$ ]]; then FILES_CHANGED=0; fi
if ! [[ "$LINES_ADDED" =~ ^[0-9]+$ ]]; then LINES_ADDED=0; fi
if ! [[ "$LINES_DELETED" =~ ^[0-9]+$ ]]; then LINES_DELETED=0; fi

echo "变更: ${FILES_CHANGED} 个文件, +${LINES_ADDED}/-${LINES_DELETED} 行"
echo ""

# 提取仅新增行 (排除删除行，防止修复 bug 时误报)
DIFF_ADDED=$(echo "$DIFF" | grep -E '^\+[^+]' 2>/dev/null || echo "")

# ═══════════════════════════════════════════════════════════
# 🔒 安全审计
# ═══════════════════════════════════════════════════════════
echo -e "${BLUE}--- 🔒 安全审计 ---${NC}"

CRITICAL=0
HIGH=0
MEDIUM=0

# 1. 硬编码密钥
for entry in "${SECRET_PATTERNS[@]}"; do
  pattern="${entry%%:*}"
  rest="${entry#*:}"
  name="${rest%%:*}"
  level="${rest##*:}"

  # 跳过被忽略的模式
  if command -v should_ignore_pattern &>/dev/null && should_ignore_pattern "$name"; then
    continue
  fi

  MATCHES=$(echo "$DIFF_ADDED" | grep -oE -- "$pattern" 2>/dev/null | sort -u || true)
  if [[ -n "$MATCHES" ]]; then
    print_result "$level" "$name"
    echo "$MATCHES" | while read -r m; do echo "     $m"; done
    case "$level" in
      CRITICAL) CRITICAL=$((CRITICAL + 1)) ;;
      HIGH)     HIGH=$((HIGH + 1)) ;;
      MEDIUM)   MEDIUM=$((MEDIUM + 1)) ;;
    esac
  fi
done

# 2. 高熵字符串
HIGH_ENTROPY=$(echo "$DIFF_ADDED" | grep -oE "[A-Za-z0-9+/=]{${ENTROPY_THRESHOLD:-40},}" 2>/dev/null | sort -u | head -20 || true)
if [[ -n "$HIGH_ENTROPY" ]]; then
  for ex_pattern in "${ENTROPY_EXCLUDE_PATTERNS[@]}"; do
    HIGH_ENTROPY=$(echo "$HIGH_ENTROPY" | grep -vE "$ex_pattern" 2>/dev/null || true)
  done
fi
if [[ -n "$HIGH_ENTROPY" ]]; then
  print_result "MEDIUM" "检测到高熵字符串（可能是密钥/Token）"
  echo "$HIGH_ENTROPY" | while read -r line; do echo "     $line"; done
  MEDIUM=$((MEDIUM + 1))
fi

# 3. .env 文件
ENV_LEAK=$(echo "$DIFF" | grep -E '^\+.*\.env' 2>/dev/null | head -5 || true)
if [[ -n "$ENV_LEAK" ]]; then
  print_result "CRITICAL" ".env 文件可能泄露"
  CRITICAL=$((CRITICAL + 1))
fi

echo ""

# ═══════════════════════════════════════════════════════════
# 🛡️ 隐私审计
# ═══════════════════════════════════════════════════════════
echo -e "${BLUE}--- 🛡️ 隐私扫描 ---${NC}"

for entry in "${PII_PATTERNS[@]}"; do
  pattern="${entry%%:*}"
  rest="${entry#*:}"
  name="${rest%%:*}"
  level="${rest##*:}"

  if command -v should_ignore_pattern &>/dev/null && should_ignore_pattern "$name"; then
    continue
  fi

  MATCHES=$(echo "$DIFF_ADDED" | grep -oE -- "$pattern" 2>/dev/null | sort -u || true)

  # 邮箱排除
  if [[ "$name" == "Email (non-test)" ]] && [[ -n "$MATCHES" ]]; then
    MATCHES=$(echo "$MATCHES" | grep -vE '(test@|example@|localhost|your-?email|test_)' 2>/dev/null || true)
  fi

  # IP 排除
  if [[ "$name" == "IP Address (non-private)" ]] && [[ -n "$MATCHES" ]]; then
    MATCHES=$(echo "$MATCHES" | grep -vE '(^127\.|^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[01])\.|^0\.0\.0\.0|^169\.254\.|^22[4-9]\.|^23[0-9]\.)' 2>/dev/null || true)
  fi

  if [[ -n "$MATCHES" ]]; then
    print_result "$level" "$name"
    echo "$MATCHES" | head -5 | while read -r m; do echo "     $m"; done
    case "$level" in
      CRITICAL) CRITICAL=$((CRITICAL + 1)) ;;
      HIGH)     HIGH=$((HIGH + 1)) ;;
      MEDIUM)   MEDIUM=$((MEDIUM + 1)) ;;
    esac
  fi
done

echo ""

# ═══════════════════════════════════════════════════════════
# 📋 日志泄露
# ═══════════════════════════════════════════════════════════
echo -e "${BLUE}--- 📋 日志泄露检查 ---${NC}"

for entry in "${LOG_LEAK_PATTERNS[@]}"; do
  pattern="${entry%%:*}"
  rest="${entry#*:}"
  name="${rest%%:*}"
  level="${rest##*:}"

  LOG_LEAK=$(echo "$DIFF_ADDED" | grep -iE "$pattern" 2>/dev/null | head -5 || true)
  if [[ -n "$LOG_LEAK" ]]; then
    print_result "$level" "日志中打印了敏感数据 ($name)"
    echo "$LOG_LEAK" | while read -r m; do echo "     $m"; done
    case "$level" in
      CRITICAL) CRITICAL=$((CRITICAL + 1)) ;;
      HIGH)     HIGH=$((HIGH + 1)) ;;
    esac
  else
    echo -e "  ${GREEN}✅ 通过${NC}"
  fi
done

echo ""

# ═══════════════════════════════════════════════════════════
# 🔐 弱加密检测
# ═══════════════════════════════════════════════════════════
echo -e "${BLUE}--- 🔐 弱加密检测 ---${NC}"

for entry in "${WEAK_CRYPTO_PATTERNS[@]}"; do
  pattern="${entry%%:*}"
  rest="${entry#*:}"
  name="${rest%%:*}"
  level="${rest##*:}"

  MATCHES=$(echo "$DIFF_ADDED" | grep -iE "$pattern" 2>/dev/null | head -5 || true)
  if [[ -n "$MATCHES" ]]; then
    print_result "$level" "弱加密: $name"
    echo "$MATCHES" | while read -r m; do echo "     $m"; done
    case "$level" in
      CRITICAL) CRITICAL=$((CRITICAL + 1)) ;;
      HIGH)     HIGH=$((HIGH + 1)) ;;
      MEDIUM)   MEDIUM=$((MEDIUM + 1)) ;;
    esac
  fi
done

echo ""

# ═══════════════════════════════════════════════════════════
# ⚡ 危险函数调用
# ═══════════════════════════════════════════════════════════
echo -e "${BLUE}--- ⚡ 危险函数调用检测 ---${NC}"

for entry in "${DANGEROUS_EXEC_PATTERNS[@]}"; do
  pattern="${entry%%:*}"
  rest="${entry#*:}"
  name="${rest%%:*}"
  level="${rest##*:}"

  MATCHES=$(echo "$DIFF_ADDED" | grep -iE "$pattern" 2>/dev/null | head -5 || true)
  if [[ -n "$MATCHES" ]]; then
    print_result "$level" "危险函数: $name"
    echo "$MATCHES" | while read -r m; do echo "     $m"; done
    case "$level" in
      CRITICAL) CRITICAL=$((CRITICAL + 1)) ;;
      HIGH)     HIGH=$((HIGH + 1)) ;;
    esac
  fi
done

echo ""

# ═══════════════════════════════════════════════════════════
# 结论
# ═══════════════════════════════════════════════════════════
echo -e "${BLUE}============================================${NC}"
echo -e "  🔴 CRITICAL: $CRITICAL"
echo -e "  🟠 HIGH:     $HIGH"
echo -e "  🟡 MEDIUM:   $MEDIUM"
echo ""

# --- 清理临时 git 分支 (trap 注册的函数会在 EXIT 时自动运行) ---
# 如果没有注册 trap，手动清理
if [[ -n "${PR_NUM:-}" ]]; then
  git branch -D "pr-${PR_NUM}" 2>/dev/null || true
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo -e "${YELLOW}(dry-run mode — 不阻止)${NC}"
  exit 0
fi

if [[ "$CRITICAL" -gt 0 ]]; then
  echo -e "${RED}🔴 BLOCKED — 存在严重安全/隐私问题，禁止合并${NC}"
  exit 2
elif [[ "$HIGH" -gt 0 ]]; then
  echo -e "${YELLOW}🟡 NEEDS CHANGES — 请修复安全问题后重新提交${NC}"
  exit 1
else
  echo -e "${GREEN}🟢 APPROVED — 安全隐私审计通过${NC}"
  exit 0
fi
