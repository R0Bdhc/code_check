#!/usr/bin/env node
// ============================================================
// pre-push-review CLI
// ============================================================
// 用法:
//   npx pre-push-review              # 审查 staged 改动
//   npx pre-push-review --all        # 审查整个仓库
//   npx pre-push-review --ci         # CI 模式 (JSON 输出)
//   npx pre-push-review --install    # 安装 git hook
// ============================================================

const { execSync } = require("child_process");
const path = require("path");
const fs = require("fs");

// ─── 配置 ───────────────────────────────────────────────────
const PATTERNS = {
  secrets: [
    { name: "AWS Access Key", regex: /AKIA[0-9A-Z]{16}/g, level: "CRITICAL" },
    { name: "Stripe Live Key", regex: /sk_live_[0-9a-zA-Z]{24,}/g, level: "CRITICAL" },
    { name: "GitHub Token", regex: /ghp_[0-9a-zA-Z]{36}/g, level: "CRITICAL" },
    { name: "GitHub OAuth", regex: /gho_[0-9a-zA-Z]{36}/g, level: "CRITICAL" },
    { name: "Slack Token", regex: /xox[baprs]-[0-9a-zA-Z-]{10,}/g, level: "CRITICAL" },
    { name: "Google API Key", regex: /AIza[0-9A-Za-z\-_]{35}/g, level: "CRITICAL" },
    { name: "Generic Secret Assignment", regex: /(?:secret|token|password|api_key|apikey)\s*[:=]\s*["'][^"']{8,}["']/gi, level: "CRITICAL" },
  ],
  pii: [
    { name: "Chinese Phone", regex: /1[3-9]\d{9}/g, level: "HIGH" },
    { name: "Chinese ID Card", regex: /[1-9]\d{5}(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dXx]/g, level: "CRITICAL" },
    { name: "Email (non-test)", regex: /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g, level: "HIGH" },
    { name: "IP Address (non-private)", regex: /\b(?!127\.|10\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.|0\.0\.0\.0)(\d{1,3}\.){3}\d{1,3}\b/g, level: "MEDIUM" },
  ],
  logLeak: [
    { name: "Log Sensitive Data", regex: /(?:console\.(?:log|error|warn|debug|info)|println!|log\.|logger\.|logging\.)[^(]*\([^)]*(?:password|secret|token|key|credential|pii|ssn|credit|card)[^)]*\)/gi, level: "CRITICAL" },
  ],
};

const LEVEL_WEIGHT = { CRITICAL: 3, HIGH: 2, MEDIUM: 1, INFO: 0 };
const COLORS = { CRITICAL: "\x1b[31m", HIGH: "\x1b[33m", MEDIUM: "\x1b[36m", INFO: "\x1b[0m" };
const NC = "\x1b[0m";

// ─── 工具函数 ────────────────────────────────────────────────

function getDiff(args) {
  if (args.includes("--all")) {
    // 审查整个仓库的所有文本文件
    const files = execSync("git ls-files", { encoding: "utf-8" }).trim().split("\n");
    let full = "";
    for (const f of files) {
      try {
        full += fs.readFileSync(f, "utf-8") + "\n";
      } catch { /* 跳过二进制文件 */ }
    }
    return full;
  }

  // 默认: staged diff
  try {
    return execSync("git diff --staged", { encoding: "utf-8" });
  } catch {
    // 无 staged → 尝试未推送的 commits
    try {
      const branch = execSync("git branch --show-current", { encoding: "utf-8" }).trim();
      return execSync(`git diff origin/${branch}..HEAD`, { encoding: "utf-8" });
    } catch {
      return execSync("git diff HEAD", { encoding: "utf-8" });
    }
  }
}

function scan(diff, patterns) {
  const findings = [];
  for (const cat of patterns) {
    for (const { name, regex, level } of cat) {
      const matches = diff.match(regex);
      if (matches) {
        // 去重
        const unique = [...new Set(matches)];
        findings.push({ category: cat === PATTERNS.secrets ? "security" : cat === PATTERNS.pii ? "privacy" : "log-leak", name, level, count: unique.length, samples: unique.slice(0, 3) });
      }
    }
  }
  return findings;
}

function filterFalsePositives(findings) {
  return findings.map((f) => {
    if (f.name === "Email (non-test)") {
      f.samples = f.samples.filter(
        (s) => !/(?:test|example|localhost|your-?email)@/.test(s) && !/@(?:test|example|localhost)\./.test(s)
      );
      f.count = f.samples.length;
    }
    return f;
  }).filter((f) => f.count > 0);
}

function verdict(findings) {
  const criticals = findings.filter((f) => f.level === "CRITICAL").length;
  const highs = findings.filter((f) => f.level === "HIGH").length;
  const mediums = findings.filter((f) => f.level === "MEDIUM").length;

  if (criticals > 0) return "BLOCKED";
  if (highs >= 3) return "BLOCKED";
  if (highs > 0 || mediums > 0) return "WARNINGS";
  return "CLEAR";
}

function formatReport(findings, isCI) {
  const v = verdict(findings);
  const criticals = findings.filter((f) => f.level === "CRITICAL");
  const highs = findings.filter((f) => f.level === "HIGH");
  const mediums = findings.filter((f) => f.level === "MEDIUM");

  if (isCI) {
    const report = {
      conclusion: v,
      timestamp: new Date().toISOString(),
      summary: { critical: criticals.length, high: highs.length, medium: mediums.length, total: findings.length },
      findings: findings.map((f) => ({ category: f.category, name: f.name, level: f.level, count: f.count })),
    };
    return JSON.stringify(report, null, 2);
  }

  let out = "";
  out += `\n${"=".repeat(50)}\n`;
  out += `  🔍 Pre-Push Review Report\n`;
  out += `${"=".repeat(50)}\n\n`;

  const icon = v === "CLEAR" ? "✅" : v === "WARNINGS" ? "⚠️" : "🛑";
  out += `  Conclusion: ${icon} ${v}\n\n`;

  if (criticals.length > 0) {
    out += `  🔒 CRITICAL (${criticals.length}):\n`;
    for (const f of criticals) {
      out += `    - ${f.name}: ${f.count} occurrences\n`;
      for (const s of f.samples) out += `      → ${s.trim()}\n`;
    }
    out += "\n";
  }

  if (highs.length > 0) {
    out += `  ⚠️  HIGH (${highs.length}):\n`;
    for (const f of highs) {
      out += `    - ${f.name}: ${f.count} occurrences\n`;
      for (const s of f.samples) out += `      → ${s.trim()}\n`;
    }
    out += "\n";
  }

  if (mediums.length > 0) {
    out += `  📋 MEDIUM (${mediums.length}):\n`;
    for (const f of mediums) {
      out += `    - ${f.name}: ${f.count} occurrences\n`;
    }
    out += "\n";
  }

  if (findings.length === 0) {
    out += `  No issues found. 🎉\n\n`;
  }

  return out;
}

function installHook() {
  const hookDest = path.join(process.cwd(), ".git", "hooks", "pre-push");
  const hookSrc = path.join(__dirname, "..", "hooks", "pre-push");

  if (fs.existsSync(hookSrc)) {
    fs.copyFileSync(hookSrc, hookDest);
  } else {
    // npm 安装时 hooks 目录可能不在包里, 尝试从仓库根目录找
    const altSrc = path.join(process.cwd(), "hooks", "pre-push");
    if (fs.existsSync(altSrc)) fs.copyFileSync(altSrc, hookDest);
  }
  fs.chmodSync(hookDest, 0o755);
  console.log(`✅ Git pre-push hook installed → ${hookDest}`);
}

// ─── 主程序 ──────────────────────────────────────────────────

const args = process.argv.slice(2);

if (args.includes("--help") || args.includes("-h")) {
  console.log(`
🛡️  pre-push-review — Push 前代码审查门禁

用法:
  npx pre-push-review              # 审查 staged 改动
  npx pre-push-review --all        # 审查整个仓库
  npx pre-push-review --ci         # CI 模式 (JSON 输出)
  npx pre-push-review --install    # 安装 git pre-push hook
  npx pre-push-review --help       # 显示帮助

环境变量:
  REVIEW_MODE=strict   — HIGH 级别也阻止推送
  REVIEW_MODE=warn     — 永远不阻止，仅输出警告
`);
  process.exit(0);
}

if (args.includes("--install")) {
  installHook();
  process.exit(0);
}

const isCI = args.includes("--ci");

try {
  const diff = getDiff(args);
  const findings = filterFalsePositives([
    ...scan(diff, [PATTERNS.secrets]),
    ...scan(diff, [PATTERNS.pii]),
    ...scan(diff, [PATTERNS.logLeak]),
  ]);

  console.log(formatReport(findings, isCI));

  const v = verdict(findings);
  if (v === "BLOCKED") {
    process.exit(1);
  }
  process.exit(0);
} catch (err) {
  console.error(`Error: ${err.message}`);
  process.exit(2);
}
