#!/usr/bin/env bash
# ============================================================
# code_check/debugger/debug.sh
# 调试入口脚本 — 供任何 Agent (Codex, Claude, 等) 调用
# ============================================================
# 用法:
#   bash debugger/debug.sh <file>           # 分析单个文件
#   bash debugger/debug.sh --diff           # 分析 git diff
#   bash debugger/debug.sh --test           # 跑测试并捕获失败
#   bash debugger/debug.sh --log <session>  # 查看历史日志
# ============================================================

set -euo pipefail

LOG_DIR="$(cd "$(dirname "$0")/.." && pwd)/debug-logs"
mkdir -p "$LOG_DIR"

# ─── 颜色 ───
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# ─── 工具函数 ───
timestamp() { date '+%Y-%m-%dT%H:%M:%S'; }
session_id() { echo "DEBUG-$(date '+%Y%m%d-%H%M%S')"; }

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
    
    DIFF=$(git diff)
    
    # 1. 语法/类型错误标记
    echo "### 可疑模式:"
    echo "$DIFF" | grep -nE '(TODO|FIXME|HACK|XXX|BUG|WARN)' | head -10 || echo "  (无)"
    echo ""
    
    # 2. 空值处理缺陷
    echo "### 空值风险:"
    echo "$DIFF" | grep -nE '(\.(unwrap|expect)\()|nil|NULL|null|undefined' | head -10 || echo "  (无)"
    echo ""
    
    # 3. 异常处理缺失
    echo "### 异常处理:"
    echo "$DIFF" | grep -nE '(catch\s*\(|except\s*:|\.catch\()' | head -10 || echo "  未发现新的异常处理"
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
        npm test 2>&1 | tail -50
      elif [ -f "Makefile" ]; then
        make test 2>&1 | tail -50
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

  *)
    # 分析指定文件
    FILE="${1:-}"
    if [[ -z "$FILE" ]]; then
      echo "用法: bash debugger/debug.sh <file|--diff|--test|--log>"
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
    
    # 检测语言
    if [[ "$FILE" == *.go ]]; then
      echo "### Go 静态分析"
      go vet "$FILE" 2>&1 || true
      staticcheck "$FILE" 2>&1 || echo "  (staticcheck 未安装)"
    elif [[ "$FILE" == *.py ]]; then
      echo "### Python 静态分析"
      python3 -m py_compile "$FILE" 2>&1 && echo "  语法: ✅" || true
      pylint "$FILE" 2>&1 | head -20 || echo "  (pylint 未安装)"
    elif [[ "$FILE" == *.js || "$FILE" == *.ts ]]; then
      echo "### JavaScript/TypeScript 静态分析"
      npx eslint "$FILE" 2>&1 | head -20 || echo "  (eslint 未安装)"
    elif [[ "$FILE" == *.rs ]]; then
      echo "### Rust 静态分析"
      rustc --edition 2021 --check "$FILE" 2>&1 || echo "  (无法编译检查)"
    else
      echo "### 通用检查"
      echo "  - 行数: $(wc -l < "$FILE")"
      echo "  - TODO/FIXME: $(grep -c 'TODO\|FIXME\|HACK\|XXX' "$FILE" 2>/dev/null || echo 0) 处"
    fi
    
    echo ""
    echo -e "${GREEN}✅ 分析完成${NC}"
    ;;
esac
