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
# ============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

echo -e "${BLUE}🛡️ Pull Audit — 安全隐私审计启动${NC}"
echo ""

# ─── 获取变更 ───
DIFF=""

case "${1:-}" in
  --branch)
    BRANCH="${2:-}"
    if [[ -z "$BRANCH" ]]; then
      echo "用法: bash audit/audit-trigger.sh --branch <branch>"
      exit 1
    fi
    echo "→ 审计分支: $BRANCH vs origin/main"
    git fetch origin main 2>/dev/null || true
    DIFF=$(git diff origin/main..."$BRANCH" 2>/dev/null || git diff main..."$BRANCH")
    ;;
  
  --diff)
    echo "→ 审计 staged diff"
    DIFF=$(git diff --staged)
    ;;
  
  *)
    PR="${1:-}"
    if [[ -n "$PR" ]]; then
      echo "→ 审计 PR #${PR}"
      if command -v gh &>/dev/null; then
        DIFF=$(gh pr diff "$PR" --color=never 2>/dev/null || echo "")
      fi
      if [[ -z "$DIFF" ]]; then
        git fetch origin "pull/${PR}/head:pr-${PR}" 2>/dev/null || true
        DIFF=$(git diff main..."pr-${PR}" 2>/dev/null || echo "")
      fi
    else
      echo "→ 审计当前分支 vs origin/main"
      DIFF=$(git diff origin/main...HEAD 2>/dev/null || git diff main...HEAD)
    fi
    ;;
esac

if [[ -z "$DIFF" ]]; then
  echo -e "${YELLOW}无变更内容，审计跳过${NC}"
  exit 0
fi

# ─── 统计 ───
FILES_CHANGED=$(echo "$DIFF" | grep -c '^diff --git' || echo 0)
LINES_ADDED=$(echo "$DIFF" | grep -c '^+' || echo 0)
echo "变更: ${FILES_CHANGED} 个文件, +${LINES_ADDED} 行"
echo ""

# ═══════════════════════════════════════════════════════════
# 🔒 安全审计
# ═══════════════════════════════════════════════════════════
echo -e "${BLUE}--- 🔒 安全审计 ---${NC}"

CRITICAL=0
HIGH=0
MEDIUM=0

# 1. 硬编码密钥
SECRET_PATTERNS=(
  'AKIA[0-9A-Z]{16}:AWS Access Key'
  'sk_live_[0-9a-zA-Z]{24,}:Stripe Live Key'
  'ghp_[0-9a-zA-Z]{36}:GitHub Token'
  'xox[baprs]-[0-9a-zA-Z-]{10,}:Slack Token'
  'AIza[0-9A-Za-z\-_]{35}:Google API Key'
  'ya29\.[0-9A-Za-z\-_]+:Google OAuth Token'
)

for entry in "${SECRET_PATTERNS[@]}"; do
  pattern="${entry%%:*}"
  name="${entry##*:}"
  MATCHES=$(echo "$DIFF" | grep -oE "$pattern" | sort -u || true)
  if [[ -n "$MATCHES" ]]; then
    echo -e "  ${RED}🛑 $name${NC}"
    echo "$MATCHES" | while read m; do echo "     $m"; done
    CRITICAL=$((CRITICAL + 1))
  fi
done

# 2. 通用密钥赋值
GENERIC_SECRETS=$(echo "$DIFF" | grep -iE '(secret|token|password|api_key|apikey)\s*[:=]\s*["'"'"'][^"'"'"']{8,}["'"'"']' | head -10 || true)
if [[ -n "$GENERIC_SECRETS" ]]; then
  echo -e "  ${RED}🛑 检测到疑似硬编码密钥/密码${NC}"
  CRITICAL=$((CRITICAL + 1))
fi

# 3. .env 文件
ENV_LEAK=$(echo "$DIFF" | grep -E '^\+.*\.env' | head -5 || true)
if [[ -n "$ENV_LEAK" ]]; then
  echo -e "  ${RED}🛑 .env 文件可能泄露${NC}"
  CRITICAL=$((CRITICAL + 1))
fi

# 4. 弱加密
WEAK_CRYPTO=$(echo "$DIFF" | grep -E '(MD5|SHA-?1|DES|RC4|ECB mode)' | head -5 || true)
if [[ -n "$WEAK_CRYPTO" ]]; then
  echo -e "  ${YELLOW}⚠️  检测到弱加密算法${NC}"
  HIGH=$((HIGH + 1))
fi

# 5. eval / exec
DANGEROUS_EXEC=$(echo "$DIFF" | grep -E '\b(eval|exec|system|shell_exec|popen|subprocess\.call)\s*\(' | head -5 || true)
if [[ -n "$DANGEROUS_EXEC" ]]; then
  echo -e "  ${YELLOW}⚠️  检测到潜在危险函数调用${NC}"
  HIGH=$((HIGH + 1))
fi

echo ""

# ═══════════════════════════════════════════════════════════
# 🛡️ 隐私审计
# ═══════════════════════════════════════════════════════════
echo -e "${BLUE}--- 🛡️ 隐私扫描 ---${NC}"

# 手机号
PHONES=$(echo "$DIFF" | grep -oE '1[3-9][0-9]{9}' | sort -u | head -5 || true)
if [[ -n "$PHONES" ]]; then
  echo -e "  ${RED}🛑 检测到手机号${NC}"
  CRITICAL=$((CRITICAL + 1))
fi

# 身份证
ID_CARDS=$(echo "$DIFF" | grep -oE '[1-9][0-9]{5}(19|20)[0-9]{2}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])[0-9]{3}[0-9Xx]' | sort -u | head -5 || true)
if [[ -n "$ID_CARDS" ]]; then
  echo -e "  ${RED}🛑 检测到身份证号！${NC}"
  CRITICAL=$((CRITICAL + 1))
fi

# 邮箱（排除测试）
EMAILS=$(echo "$DIFF" | grep -oE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' | grep -vE '(test@|example@|localhost|your-?email|test_)' | sort -u | head -5 || true)
if [[ -n "$EMAILS" ]]; then
  echo -e "  ${YELLOW}⚠️  检测到疑似真实邮箱${NC}"
  HIGH=$((HIGH + 1))
fi

# IP (排除私有)
IPS=$(echo "$DIFF" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | grep -vE '(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|0\.0\.0\.0)' | sort -u | head -5 || true)
if [[ -n "$IPS" ]]; then
  echo -e "  ${YELLOW}⚠️  检测到疑似真实 IP${NC}"
  MEDIUM=$((MEDIUM + 1))
fi

echo ""

# ═══════════════════════════════════════════════════════════
# 📋 日志泄露
# ═══════════════════════════════════════════════════════════
echo -e "${BLUE}--- 📋 日志泄露检查 ---${NC}"

LOG_LEAK=$(echo "$DIFF" | grep -E '(console\.(log|error|warn|debug|info)|println!|log\.|logger\.|logging\.)' | grep -iE '(password|secret|token|key|credential|pii|ssn|credit|card)' | head -5 || true)
if [[ -n "$LOG_LEAK" ]]; then
  echo -e "  ${RED}🛑 日志中打印了敏感数据${NC}"
  CRITICAL=$((CRITICAL + 1))
else
  echo -e "  ${GREEN}✅ 通过${NC}"
fi

echo ""

# ═══════════════════════════════════════════════════════════
# 结论
# ═══════════════════════════════════════════════════════════
echo -e "${BLUE}============================================${NC}"
echo -e "  🔴 CRITICAL: $CRITICAL"
echo -e "  🟠 HIGH:     $HIGH"
echo -e "  🟡 MEDIUM:   $MEDIUM"
echo ""

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
