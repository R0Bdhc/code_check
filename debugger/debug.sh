#!/usr/bin/env bash
# ============================================================
# code_check/debugger/debug.sh
# 调试入口脚本 — 供任何 Agent (Codex, Claude, 等) 调用
# ============================================================
# 用法:
#   bash debugger/debug.sh <file>            # 分析单个文件
#   bash debugger/debug.sh --diff            # 分析 git diff
#   bash debugger/debug.sh --test            # 跑测试并捕获失败
#   bash debugger/debug.sh --log <session>   # 查看历史日志
#   bash debugger/debug.sh --all             # 扫描全部源文件
# ============================================================

set -euo pipefail

LOG_DIR="$(cd "$(dirname "$0")/.." && pwd)/debug-logs"
mkdir -p "$LOG_DIR"

# ─── 颜色 ───
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# ─── 工具函数 ───
timestamp() { date '+%Y-%m-%dT%H:%M:%S'; }
session_id() { echo "DEBUG-$(date '+%Y%m%d-%H%M%S')"; }

# ─── 通用代码质量检查 (所有语言) ───
generic_check() {
  local file="$1"
  echo "### 通用质量检查"
  echo "  - 行数: $(wc -l < "$file")"
  echo "  - 超长行 (>120 chars): $(grep -cE '.{121,}' "$file" 2>/dev/null || echo 0) 处"
  echo "  - 行尾空格: $(grep -cE '[[:space:]]+$' "$file" 2>/dev/null || echo 0) 处"

  # 标签标记 (使用词边界，避免 WARN 匹配 WARNING)
  local tags
  tags=$(grep -nE '\b(TODO|FIXME|HACK|XXX|BUG)\b' "$file" 2>/dev/null | head -10 || echo "")
  local warn_tags
  warn_tags=$(grep -nE '\bWARN(ING)?\b' "$file" 2>/dev/null | head -5 || echo "")
  local tag_count=0
  [[ -n "$tags" ]] && tag_count=$(echo "$tags" | grep -c .)
  [[ -n "$warn_tags" ]] && tag_count=$((tag_count + $(echo "$warn_tags" | grep -c .)))

  if [[ "$tag_count" -gt 0 ]]; then
    echo "  - 标记 (TODO/FIXME/etc): ${tag_count} 处"
    [[ -n "$tags" ]] && echo "$tags" | while read -r line; do echo "     $line"; done
    [[ -n "$warn_tags" ]] && echo "$warn_tags" | while read -r line; do echo "     $line"; done
  else
    echo "  - 标记: 0 处"
  fi
}

# ─── 语言相关静态分析 ───
analyze_file() {
  local file="$1"

  if [[ "$file" == *.go ]]; then
    echo "### Go 静态分析"
    go vet "$file" 2>&1 || true
    command -v staticcheck &>/dev/null && staticcheck "$file" 2>&1 | head -20 || echo "  (staticcheck 未安装)"
    command -v golangci-lint &>/dev/null && golangci-lint run "$file" 2>&1 | head -20 || true

  elif [[ "$file" == *.py ]]; then
    echo "### Python 静态分析"
    python3 -m py_compile "$file" 2>&1 && echo "  语法: ✅" || true
    command -v pylint &>/dev/null && pylint "$file" 2>&1 | head -20 || echo "  (pylint 未安装)"
    command -v ruff &>/dev/null && ruff check "$file" 2>&1 | head -20 || true

  elif [[ "$file" == *.js || "$file" == *.ts || "$file" == *.mjs || "$file" == *.jsx || "$file" == *.tsx ]]; then
    echo "### JavaScript/TypeScript 静态分析"
    command -v npx &>/dev/null && npx eslint "$file" 2>&1 | head -20 || echo "  (eslint 未安装)"

  elif [[ "$file" == *.rs ]]; then
    echo "### Rust 静态分析"
    rustc --edition 2021 --check "$file" 2>&1 || echo "  (无法编译检查)"
    command -v cargo &>/dev/null && cargo clippy 2>&1 | head -20 || true

  elif [[ "$file" == *.java ]]; then
    echo "### Java 静态分析"
    if command -v javac &>/dev/null; then
      javac -Xlint:all "$file" 2>&1 | head -20 || true
    else
      echo "  (javac 未安装)"
    fi

  elif [[ "$file" == *.c || "$file" == *.h || "$file" == *.cpp || "$file" == *.hpp || "$file" == *.cc || "$file" == *.cxx ]]; then
    echo "### C/C++ 静态分析"
    if command -v gcc &>/dev/null; then
      gcc -fsyntax-only -Wall "$file" 2>&1 | head -20 || true
    elif command -v clang &>/dev/null; then
      clang --analyze -Wall "$file" 2>&1 | head -20 || true
    else
      echo "  (gcc/clang 未安装)"
    fi

  elif [[ "$file" == *.cs ]]; then
    echo "### C# 静态分析"
    if command -v dotnet &>/dev/null; then
      dotnet format --verify-no-changes --include "$file" 2>&1 | head -20 || true
    else
      echo "  (dotnet 未安装)"
    fi

  elif [[ "$file" == *.rb ]]; then
    echo "### Ruby 语法检查"
    ruby -c "$file" 2>&1 && echo "  语法: ✅" || true
    command -v rubocop &>/dev/null && rubocop "$file" 2>&1 | head -20 || echo "  (rubocop 未安装)"

  elif [[ "$file" == *.php ]]; then
    echo "### PHP 语法检查"
    php -l "$file" 2>&1 && echo "  语法: ✅" || true
    command -v phpstan &>/dev/null && phpstan analyse "$file" 2>&1 | head -20 || echo "  (phpstan 未安装)"

  else
    echo "### 通用检查 (未知语言)"
    echo "  - 文件类型: $(file -b "$file" 2>/dev/null || echo 'unknown')"
  fi
}

# ─── 主逻辑 ───

case "${1:-}" in

  --diff)
    echo -e "${BLUE}🔍 分析 git diff...${NC}"
    echo ""
    echo "## 📋 变更文件"
    git diff --stat
    echo ""
    echo "## 🔍 潜在问题扫描"
    echo ""

    DIFF=$(git diff 2>/dev/null || echo "")

    # 1. 标签标记 (使用词边界，WARN不匹配WARNING)
    echo "### 可疑标记:"
    MARKERS=$(echo "$DIFF" | grep -nE '^\+.*\b(TODO|FIXME|HACK|XXX|BUG)\b' 2>/dev/null | head -10 || echo "")
    if [[ -n "$MARKERS" ]]; then
      echo "$MARKERS"
    else
      echo "  (无)"
    fi
    echo ""

    # 2. 空值处理缺陷 (跨语言)
    echo "### 空值风险:"
    NULL_RISK=$(echo "$DIFF" | grep -nE '^\+.*(\.(unwrap|expect)\()|nil|NULL|null|undefined|None\b' 2>/dev/null | head -10 || echo "")
    if [[ -n "$NULL_RISK" ]]; then
      echo "$NULL_RISK"
    else
      echo "  (无)"
    fi
    echo ""

    # 3. 异常处理
    echo "### 异常处理:"
    EXCEPTIONS=$(echo "$DIFF" | grep -nE '^\+.*(catch\s*\(|except\s*:|\.catch\()' 2>/dev/null | head -10 || echo "")
    if [[ -n "$EXCEPTIONS" ]]; then
      echo "$EXCEPTIONS"
    else
      echo "  未发现新的异常处理"
    fi
    echo ""

    # 4. 安全相关模式
    echo "### 安全标记:"
    SEC_MARKERS=$(echo "$DIFF" | grep -nE '^\+.*\b(SECURITY|VULN|CVE-|XSS|CSRF|SQL\s*INJECTION)' 2>/dev/null | head -10 || echo "")
    if [[ -n "$SEC_MARKERS" ]]; then
      echo "$SEC_MARKERS"
    else
      echo "  未发现安全相关标记"
    fi
    echo ""

    echo -e "${GREEN}✅ 基础分析完成。详细分析请使用 AI agent。${NC}"
    ;;

  --test)
    echo -e "${BLUE}🧪 运行测试套件...${NC}"
    SESSION=$(session_id)
    LOG_FILE="$LOG_DIR/${SESSION}-test.md"

    {
      echo "# 🧪 Test Run — $SESSION"
      echo ""
      echo "**时间**: $(timestamp)"
      echo ""
      echo "## 测试输出"
      echo '```'

      # 尝试常见测试命令
      if [ -f "Cargo.toml" ]; then
        cargo test 2>&1 | tail -50
      elif [ -f "go.mod" ]; then
        go test ./... 2>&1 | tail -50
      elif [ -f "package.json" ]; then
        if [ -d "node_modules" ]; then
          npm test 2>&1 | tail -50
        else
          npm install --silent 2>/dev/null && npm test 2>&1 | tail -50 || echo "npm install 失败"
        fi
      elif [ -f "Makefile" ]; then
        make test 2>&1 | tail -50
      elif [ -f "pom.xml" ]; then
        mvn test 2>&1 | tail -50 || echo "mvn 未安装"
      elif [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then
        gradle test 2>&1 | tail -50 || echo "gradle 未安装"
      else
        echo "未找到可识别的测试框架"
      fi

      echo '```'
    } | tee "$LOG_FILE"

    echo -e "${GREEN}日志已保存: $LOG_FILE${NC}"
    ;;

  --log)
    SESSION="${2:-}"
    if [[ -z "$SESSION" ]]; then
      echo "最近的调试日志:"
      ls -lt "$LOG_DIR"/*.md 2>/dev/null | head -10 || echo "  (无日志)"
    else
      cat "$LOG_DIR"/DEBUG-${SESSION}*.md 2>/dev/null || echo "未找到 $SESSION"
    fi
    ;;

  --all)
    echo -e "${BLUE}🔍 扫描所有源文件...${NC}"
    echo ""

    # 列出所有文本源文件
    FILES=$(git grep -Il '' 2>/dev/null | grep -vE '(\.git/|node_modules/|vendor/|\.min\.)' | head -100 || echo "")
    if [[ -z "$FILES" ]]; then
      echo "未找到源文件"
      exit 0
    fi

    TOTAL=$(echo "$FILES" | grep -c .)
    echo "扫描 ${TOTAL} 个文件..."
    echo ""

    ISSUES=0
    while IFS= read -r file; do
      if [[ ! -f "$file" ]]; then continue; fi
      local_tags=$(grep -cE '\b(TODO|FIXME|HACK|XXX|BUG)\b' "$file" 2>/dev/null || echo 0)
      if [[ "$local_tags" -gt 0 ]]; then
        echo "  ${YELLOW}$file${NC}: ${local_tags} 个标记"
        ISSUES=$((ISSUES + local_tags))
      fi
    done <<< "$FILES"

    echo ""
    echo -e "${GREEN}✅ 扫描完成，共 ${ISSUES} 个标记${NC}"
    ;;

  *)
    # 分析指定文件
    FILE="${1:-}"
    if [[ -z "$FILE" ]]; then
      echo "用法: bash debugger/debug.sh <file|--diff|--test|--log|--all>"
      exit 1
    fi

    if [[ ! -f "$FILE" ]]; then
      echo -e "${RED}文件不存在: $FILE${NC}"
      exit 1
    fi

    echo -e "${BLUE}🔍 分析 $FILE ...${NC}"
    echo ""
    echo "## 📄 文件: $FILE"
    echo "**大小**: $(wc -l < "$FILE") 行"
    echo "**类型**: $(file -b "$FILE" 2>/dev/null || echo 'unknown')"
    echo ""

    generic_check "$FILE"
    echo ""
    analyze_file "$FILE"
    echo ""

    echo -e "${GREEN}✅ 分析完成${NC}"
    ;;
esac
