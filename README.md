# 🛡️ pre-push-review

**推送前代码审查门禁** — 在每次 `git push` 之前自动执行安全审计、隐私扫描和代码质量检查。

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Reasonix](https://img.shields.io/badge/Reasonix-Skill-7c3aed)](https://github.com/anthropics/reasonix)

---

## 这是什么？

`pre-push-review` 是一个**可嵌入任何开发流程**的代码审查门禁。它在代码推送到远程仓库之前拦截并审查，如果发现安全漏洞、隐私泄露或严重质量问题，则**阻止推送**。

```
git push  →  🛡️ pre-push-review  →  ✅ 通过  →  推送成功
                                  →  ⚠️ 警告  →  推送成功（带警告）
                                  →  🛑 阻止  →  推送失败（需修复）
```

## 三层审查

| 层 | 内容 | 示例 |
|----|------|------|
| 🔒 **安全审计** | 注入攻击、认证绕过、弱加密、密钥泄露、依赖漏洞 | SQL 注入、硬编码 API key、`eval()` 误用 |
| 🛡️ **隐私扫描** | PII 暴露、日志泄露、错误消息泄露、API 过度返回 | 日志中打印手机号、身份证号、邮箱地址 |
| 📋 **代码质量** | 逻辑错误、错误处理缺失、并发安全、测试覆盖 | 未处理的 promise、nil pointer dereference |

## 集成方式

你可以在以下四个层面使用它：

| 方式 | 适合场景 | 安装 |
|------|---------|------|
| **Reasonix Skill** | 在 Reasonix Agent 中自动调用 | `install-capability` 一键安装 |
| **Git Hook** | 终端 `git push` 时自动触发 | 复制 `hooks/pre-push` 到 `.git/hooks/` |
| **CI 模板** | 嵌入 GitHub Actions / GitLab CI | 复制 `ci/` 下的模板到项目 |
| **CLI 工具** | 独立命令行使用 | `npx pre-push-review` |

---

## 快速开始

### 方式 1：Reasonix Skill（AI 审查）

```bash
# 安装 Skill
reasonix install-capability --source github.com/your-org/pre-push-review

# 在 dev-workflow 中自动调用，或手动触发：
/pre-push-review
```

### 方式 2：Git Hook（本地拦截）

```bash
# 安装 pre-push hook
cp hooks/pre-push .git/hooks/pre-push
chmod +x .git/hooks/pre-push

# 之后每次 git push 都会自动审查
git push
```

### 方式 3：CI 模板（流水线集成）

**GitHub Actions** — 将 `ci/github-actions.yml` 放入 `.github/workflows/`：

```yaml
# 在你的 workflow 中引用
jobs:
  review:
    uses: your-org/pre-push-review/.github/workflows/review.yml@main
```

**GitLab CI** — 将 `ci/gitlab-ci.yml` 内容合并到你的 `.gitlab-ci.yml`。

### 方式 4：CLI（独立运行）

```bash
npx pre-push-review          # 审查 staged 改动
npx pre-push-review --all    # 审查整个仓库
npx pre-push-review --ci     # CI 模式（JSON 输出）
```

---

## 严重等级

| 等级 | 含义 | 动作 |
|------|------|------|
| 🔴 **CRITICAL** | 安全漏洞、PII 泄露、密钥暴露 | 🛑 阻止推送 |
| 🟠 **HIGH** | 潜在注入点、隐私风险 | 🛑 阻止推送 |
| 🟡 **MEDIUM** | 代码异味、测试缺失 | ⚠️ 警告（不阻止） |
| 🔵 **INFO** | 风格建议 | ✅ 放行 |

**阻塞规则**：存在 ≥1 个 CRITICAL 或 ≥3 个 HIGH → 阻止推送。

---

## 隐私扫描规则

| 模式 | 正则 | 风险 |
|------|------|------|
| 邮箱地址 | `[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}` | HIGH |
| 中国手机号 | `1[3-9]\d{9}` | HIGH |
| 身份证号 | `\d{17}[\dXx]` | CRITICAL |
| IPv4 地址 | `\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}` | HIGH |
| AWS Access Key | `AKIA[0-9A-Z]{16}` | CRITICAL |
| Generic Secret | `(secret\|token\|password\|api_key)\s*[:=]\s*["'][^"']+["']` | CRITICAL |

> 测试夹具中的假数据（如 `test@example.com`、`127.0.0.1`）自动排除。

---

## 目录结构

```
pre-push-review/
├── README.md                     # 本文件
├── SKILL.md                      # Reasonix Skill 定义
├── LICENSE                       # MIT
├── hooks/
│   └── pre-push                  # Git pre-push hook 脚本
├── ci/
│   ├── github-actions.yml        # GitHub Actions 模板
│   └── gitlab-ci.yml             # GitLab CI 模板
├── cli/
│   ├── package.json              # npm 包配置
│   └── index.js                  # CLI 入口
└── .github/
    └── workflows/
        └── test.yml              # 本仓库的 CI
```

---

## 贡献

欢迎提 Issue 和 PR！新增检测规则、优化误报率、添加新的集成方式都是受欢迎的贡献。

## License

MIT © 2025
