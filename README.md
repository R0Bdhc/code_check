# 🛡️ code_check

**全方位代码质量与安全工具包** — 覆盖 Push 前审查、PR 安全隐私审计、AI Agent 代码调试与自动改进。

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Reasonix](https://img.shields.io/badge/Reasonix-Skill-7c3aed)](https://github.com/anthropics/reasonix)

---

## 三大核心能力

```
┌──────────────────────────────────────────────────────────┐
│                     code_check                           │
│                                                          │
│  🛡️ pre-push-review   🐛 code-debugger   🔍 pull-audit │
│  推送前拦截             AI 调试改进        PR 安全审计    │
│  ─────────────         ─────────────       ────────────  │
│  安全 + 隐私 + 质量    读代码 → debug      PR 触发 → 安全│
│  git push 前自动执行    → 改进 → 日志      + 隐私 → 结论  │
└──────────────────────────────────────────────────────────┘
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

---

## 审查维度对比

| 维度 | pre-push-review | pull-audit | code-debugger |
|------|:---:|:---:|:---:|
| 硬编码密钥/Token | ✅ | ✅ | ✅ |
| 弱加密算法 | ✅ | ✅ | — |
| PII (手机/身份证/邮箱/IP) | ✅ | ✅ | — |
| 日志泄露敏感数据 | ✅ | ✅ | — |
| 注入/认证/授权 | ✅ | ✅ | — |
| 代码 Bug 定位 | — | — | ✅ |
| 自动修复 + 验证 | — | — | ✅ |
| 结构化调试日志 | — | — | ✅ |
| PR 评论回复 | — | ✅ | — |

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
├── skills/
│   ├── code-debugger.md              # code-debugger Skill 定义
│   └── pull-audit.md                 # pull-audit Skill 定义
│
└── .github/workflows/
    └── test.yml                      # 本仓库的 CI
```

---

## 隐私扫描规则

| 模式 | 正则 | 风险 |
|------|------|------|
| 邮箱 | `[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}` | HIGH |
| 中国手机号 | `1[3-9]\d{9}` | HIGH |
| 身份证号 | `\d{17}[\dXx]` | CRITICAL |
| IPv4 地址 | `\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}` | HIGH |
| AWS Key | `AKIA[0-9A-Z]{16}` | CRITICAL |
| Stripe Key | `sk_live_[0-9a-zA-Z]{24,}` | CRITICAL |
| GitHub Token | `ghp_[0-9a-zA-Z]{36}` | CRITICAL |
| Generic Secret | `(secret\|password\|api_key)\s*[:=]\s*["'][^"']+["']` | CRITICAL |

> 测试夹具中的假数据自动排除。

---

## 贡献

欢迎提 Issue 和 PR！新增检测规则、优化误报率、添加新的集成方式都是受欢迎的贡献。

## License

MIT © 2025
