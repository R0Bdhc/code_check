# 🛡️ code_check

**全方位代码质量与安全工具包** — 覆盖 Push 前审查、PR 安全隐私审计、AI Agent 代码调试、跨 Agent 库审计。

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Reasonix](https://img.shields.io/badge/Reasonix-Skill-7c3aed)](https://github.com/anthropics/reasonix)

---

## 四大核心能力

```
┌───────────────────────────────────────────────────────────────────┐
│                          code_check                               │
│                                                                   │
│  🛡️ pre-push   🐛 code-debugger  🔍 pull-audit  🔗 cross-agent │
│  推送前拦截        AI 调试改进       PR 安全审计     跨 Agent 审计 │
│  ─────────        ─────────────      ────────────    ──────────── │
│  安全+隐私+质量   读代码 → debug     PR 触发 → 安全  变更检测 →    │
│  git push 前执行  → 改进 → 日志     + 隐私 → 结论   debug+审计     │
└───────────────────────────────────────────────────────────────────┘
```

### 🛡️ pre-push-review — Push 前拦截

在 `git push` 之前自动审查。阻止包含安全漏洞、PII 泄露、密钥暴露的代码进入远程仓库。

```
git push  →  🛡️ 审查  →  ✅ 通过  →  推送成功
                      →  ⚠️ 警告  →  推送（带警告）
                      →  🛑 阻止  →  推送失败
```

### 🐛 code-debugger — AI 调试与改进

供任何 AI Agent (Codex, Claude, Reasonix) 调用的调试工具。读取仓库代码 → 定位根因 → 精准修复 → 回归验证 → 生成结构化日志。

```
Agent 请求 → 🐛 读代码 → 定位 bug → 修复 → 验证 → 📝 日志
```

### 🔍 pull-audit — PR 安全隐私审计

Pull Request 触发式深度审计。当有 PR 提交或收到 "pull" 指令时，自动执行安全漏洞扫描 + PII 检测 + 隐私合规审查，输出 APPROVED / NEEDS CHANGES / BLOCKED 结论。

```
PR opened  →  🔍 安全审计  →  🟢 APPROVED   →  可合并
           →  🔍 PII 扫描  →  🟡 NEEDS CHANGE
           →  🔍 日志泄露  →  🔴 BLOCKED
```

### 🔗 cross-agent-audit — 跨 Agent 库审计 (NEW)

**任何 AI Agent** 都可以调用的库级审计能力。自动检测目标仓库的代码变更，执行安全审计 + 代码调试，生成统一报告。支持增量检查 — 只审查上次检查后变更的文件。

```
Any Agent  →  🔗 变更检测  →  🔒 安全审计  →  🟢 CLEAR
           →  📊 增量追踪  →  🔍 代码调试  →  ⚠️ WARNINGS
           →  📝 统一报告  →  💾 状态持久  →  🔴 BLOCKED
```

**触发方式：**

```bash
# 通过 Skill 调用（Reasonix Agent）
/cross-agent-audit check /path/to/library

# 直接脚本调用（任何 Agent / CI）
bash cross-agent/check.sh /path/to/library            # 增量检查
bash cross-agent/check.sh /path/to/library --full     # 全量重扫
bash cross-agent/check.sh /path/to/library --json     # JSON 输出
bash cross-agent/check.sh /path/to/library --debug-only  # 仅代码调试
bash cross-agent/check.sh /path/to/library --audit-only  # 仅安全审计
bash cross-agent/check.sh --list                      # 列出追踪库
```

**核心特性：**
- **增量检查**: 追踪上次检查的 commit SHA，只扫描新变更
- **状态持久化**: 检查状态存储在 `state/` 目录，不提交到 git
- **统一报告**: Markdown 报告 + JSON 输出，含 CLEAR/WARNINGS/BLOCKED 结论
- **跨 Agent**: 任何 Agent 通过 Skill 或 bash 脚本均可调用

---

## 审查维度对比

| 维度 | pre-push-review | pull-audit | code-debugger | cross-agent-audit |
|------|:---:|:---:|:---:|:---:|
| 硬编码密钥/Token | ✅ | ✅ | ✅ | ✅ |
| 弱加密算法 | ✅ | ✅ | — | ✅ |
| PII (手机/身份证/邮箱/IP) | ✅ | ✅ | — | ✅ |
| 日志泄露敏感数据 | ✅ | ✅ | — | ✅ |
| 注入/认证/授权 | ✅ | ✅ | — | — |
| 代码 Bug 定位 | — | — | ✅ | — |
| 自动修复 + 验证 | — | — | ✅ | — |
| 结构化调试日志 | — | — | ✅ | ✅ |
| PR 评论回复 | — | ✅ | — | — |
| **增量检查** | — | — | — | ✅ |
| **跨 Agent 调用** | — | — | ✅ | ✅ |
| **状态持久化** | — | — | — | ✅ |
| **库级变更检测** | — | — | — | ✅ |

---

## 快速开始

### 作为 Reasonix Skill

```bash
# 安装全部三个 Skill
reasonix install-capability --source github.com/R0Bdhc/code_check

# 使用
/pre-push-review              # Push 前审查
/code-debugger                # 调试代码
/pull-audit                   # PR 安全审计
```

### 作为 Git Hook

```bash
# Push 前自动审查
cp hooks/pre-push .git/hooks/pre-push && chmod +x .git/hooks/pre-push
```

### 作为 CI 模板

**GitHub Actions** — 复制 `ci/github-actions.yml` 到 `.github/workflows/`。
**GitLab CI** — 合并 `ci/gitlab-ci.yml` 内容。

### 作为独立 CLI / 脚本

```bash
# 安全扫描 CLI
npx pre-push-review

# 调试脚本
bash debugger/debug.sh --diff          # 分析变更
bash debugger/debug.sh --test          # 跑测试 + 日志
bash debugger/debug.sh src/main.go     # 分析单个文件

# PR 审计脚本
bash audit/audit-trigger.sh 42         # 审计 PR #42
bash audit/audit-trigger.sh --branch feat/new-api  # 审计分支
bash audit/audit-trigger.sh --diff     # 审计 staged changes

# 跨 Agent 库审计 (NEW)
bash cross-agent/check.sh /path/to/library            # 增量检查
bash cross-agent/check.sh /path/to/library --full     # 全量重扫
bash cross-agent/check.sh /path/to/library --json     # JSON 输出
bash cross-agent/check.sh --list                      # 查看追踪库
```

---

## 严重等级

| 等级 | 含义 | pre-push-review | pull-audit |
|------|------|:---:|:---:|
| 🔴 **CRITICAL** | 安全漏洞、PII 泄露、密钥暴露 | 🛑 阻止推送 | 🔴 BLOCKED |
| 🟠 **HIGH** | 潜在注入点、隐私风险 | 🛑 阻止推送 | 🟡 NEEDS CHANGES |
| 🟡 **MEDIUM** | 代码异味、测试缺失 | ⚠️ 警告 | 🟡 NEEDS CHANGES |
| 🔵 **INFO** | 风格建议 | ✅ 放行 | 🟢 APPROVED |

---

## 目录结构

```
code_check/
├── README.md
├── SKILL.md                          # pre-push-review Skill 定义
├── LICENSE                           # MIT
├── patterns.json                     # 集中式模式配置 (所有消费者共享)
├── .code_check.yml                   # 项目级配置模板
│
├── lib/                              # 共享库
│   ├── patterns.sh                   # Shell 模式库 (bash 消费者引用)
│   ├── config.sh                     # Shell 配置加载器
│   ├── config.js                     # Node.js 配置加载器
│   ├── state.sh                      # 🆕 跨 Agent 状态管理
│   └── git-utils.sh                  # 🆕 Git 变更检测工具
│
├── hooks/
│   └── pre-push                      # Git pre-push hook
│
├── ci/
│   ├── github-actions.yml            # GitHub Actions 模板
│   └── gitlab-ci.yml                 # GitLab CI 模板
│
├── cli/
│   ├── package.json                  # npm 包 (npx pre-push-review)
│   └── index.js                      # CLI 入口
│
├── debugger/
│   └── debug.sh                      # 调试入口脚本 (供 Agent 调用)
│
├── audit/
│   └── audit-trigger.sh              # PR 审计触发器
│
├── cross-agent/                      # 🆕 跨 Agent 库审计
│   ├── check.sh                      # 编排脚本 (change→audit→debug→report)
│   └── reports/                      # 审计报告输出目录
│
├── state/                            # 🆕 状态文件目录
│   └── .gitkeep
│
├── skills/
│   ├── code-debugger.md              # code-debugger Skill 定义
│   ├── pull-audit.md                 # pull-audit Skill 定义
│   └── cross-agent-audit.md          # 🆕 cross-agent-audit Skill 定义
│
└── .github/workflows/
    └── test.yml                      # 本仓库的 CI
```

---

## 隐私扫描规则

> 所有模式集中定义在 `patterns.json` 中，bash/Node.js/CI 脚本统一引用。

| 模式 | 正则 | 风险 |
|------|------|------|
| 邮箱 | `[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}` | HIGH |
| 中国手机号 | `1[3-9]\d{9}` | HIGH |
| 身份证号 | `[1-9]\d{5}(19\|20)\d{2}(0[1-9]\|1[0-2])(0[1-9]\|[12]\d\|3[01])\d{3}[\dXx]` | CRITICAL |
| IPv4 地址 | `\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}` (排除私有/链路本地/多播) | MEDIUM |
| AWS Key | `AKIA[0-9A-Z]{16}` | CRITICAL |
| Stripe Key | `sk_live_[0-9a-zA-Z]{24,}` | CRITICAL |
| GitHub Token | `ghp_[0-9a-zA-Z]{36}` | CRITICAL |
| GitHub Fine-grained PAT | `github_pat_[A-Za-z0-9_]{36,}` | CRITICAL |
| OpenAI API Key | `sk-(proj-\|org-)?[A-Za-z0-9]{32,}` | CRITICAL |
| JWT Token | `eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}` | CRITICAL |
| Private Key | `-----BEGIN (RSA\|EC\|DSA\|OPENSSH) PRIVATE KEY-----` | CRITICAL |
| Generic Secret | `(secret\|password\|api_key)\s*[:=]\s*["'][^"']+["']` | CRITICAL |
| Weak Crypto | `MD5\|SHA-?1\|DES\|RC4` | HIGH |
| Dangerous Exec | `eval\|exec\|system\|shell_exec\|popen` | HIGH |

> 测试夹具中的假数据自动排除。**仅扫描新增行**，避免删除密钥的修复 commit 被误拦。

---

## 项目级配置

在项目根目录创建 `.code_check.yml` 来自定义审查行为：

```yaml
# 审查模式: normal | strict | warn
review_mode: normal

# 按名称禁用模式 (减少误报)
ignore_patterns:
  - "GitHub OAuth"
  - "Email (non-test)"

# 按路径排除
ignore_paths:
  - "vendor/"
  - "**/testdata/"

# 新增项目特定模式
custom_patterns:
  secrets:
    # - "Internal Key | mykey_[A-Za-z0-9]{20} | CRITICAL"
```

配置被所有消费者 (CLI, git hook, CI) 统一加载。

## 贡献

欢迎提 Issue 和 PR！新增检测规则请同步更新 `patterns.json`（唯一配置源），然后运行 `node scripts/generate-patterns-sh.js` 重新生成 shell 库。

## License

MIT © 2025
