#!/usr/bin/env node
// ============================================================
// pre-push-review CLI
// ============================================================
// 用法:
//   npx pre-push-review              # 审查 staged 改动
//   npx pre-push-review --all        # 审查整个仓库
//   npx pre-push-review --ci         # CI 模式 (JSON 输出)
//   npx pre-push-review --dry-run    # 扫描但始终 exit 0
//   npx pre-push-review --install    # 安装 git hook
//   npx pre-push-review --version    # 显示版本
// ============================================================

const { execSync } = require("child_process");
const path = require("path");
const fs = require("fs");

// ─── 加载集中式模式配置 ──────────────────────────────────────
const { getEffectivePatterns } = require("../lib/config.js");

const PKG = require("./package.json");
const VERSION = PKG.version || "2.0.0";

// ─── 文本文件扩展名 (用于 --all 模式过滤) ──────────────────
const TEXT_EXTENSIONS = new Set([
  "js", "ts", "jsx", "tsx", "mjs", "cjs", "vue", "svelte",
  "py", "pyi", "pyx", "ipynb",
  "go",
  "rs",
  "java", "kt", "kts", "scala",
  "c", "h", "cpp", "hpp", "cc", "cxx", "hxx", "c++",
  "cs", "fs", "fsx", "vb",
  "rb", "rake", "gemspec",
  "php", "phtml",
  "swift", "m", "mm",
  "sh", "bash", "zsh", "fish",
  "yaml", "yml", "json", "toml", "xml", "ini", "cfg", "conf",
  "md", "markdown", "rst", "txt", "text",
  "env", "env.example", "env.local", "env.production",
  "sql", "graphql", "gql",
  "html", "htm", "css", "scss", "sass", "less",
  "dockerfile", "makefile", "cmake",
  "tf", "tfvars", "hcl",
  "lua", "r", "jl", "dart", "ex", "exs", "erl", "hrl",
]);

const LEVEL_WEIGHT = { CRITICAL: 3, HIGH: 2, MEDIUM: 1, INFO: 0 };
const COLORS = { CRITICAL: "\x1b[31m", HIGH: "\x1b[33m", MEDIUM: "\x1b[36m", INFO: "\x1b[0m" };
const NC = "\x1b[0m";

// ─── 工具函数 ────────────────────────────────────────────────

function getDiff(args, patterns) {
  const ignorePaths = patterns.ignore_paths || [];

  if (args.includes("--all")) {
    // 审查整个仓库的所有文本文件，排除二进制和忽略路径
    let files;
    try {
      // 使用 git grep -l '' 列出所有文本文件（-I 排除二进制）
      files = execSync('git grep -Il ""', { encoding: "utf-8" }).trim().split("\n").filter(Boolean);
    } catch {
      // 回退: git ls-files + 扩展名过滤
      try {
        const allFiles = execSync("git ls-files", { encoding: "utf-8" }).trim().split("\n");
        files = allFiles.filter((f) => {
          const ext = path.extname(f).toLowerCase().replace(".", "");
          return TEXT_EXTENSIONS.has(ext) || TEXT_EXTENSIONS.has(f.toLowerCase());
        });
      } catch {
        files = [];
      }
    }

    // 过滤忽略路径
    files = files.filter((f) => {
      for (const ignore of ignorePaths) {
        const pattern = ignore.replace(/\*\*/g, ".*").replace(/\*/g, "[^/]*");
        if (new RegExp(pattern).test(f)) return false;
      }
      return true;
    });

    let full = "";
    for (const f of files) {
      try {
        const buf = fs.readFileSync(f);
        // 简单二进制检测：NULL 字节
        if (!buf.includes(0)) {
          full += buf.toString("utf-8") + "\n";
        }
      } catch { /* skip */ }
    }
    return full;
  }

  // 默认: staged diff
  try {
    return execSync("git diff --staged", { encoding: "utf-8" });
  } catch {
    // 无 staged → 尝试未推送的 commits
    try {
      // 先检查 upstream 是否存在
      let upstream;
      try {
        upstream = execSync("git rev-parse --abbrev-ref @{upstream}", {
          encoding: "utf-8", stdio: ["pipe", "pipe", "ignore"]
        }).trim();
      } catch {
        upstream = null;
      }

      if (upstream) {
        return execSync(`git diff ${upstream}..HEAD`, { encoding: "utf-8" });
      } else {
        // 无 upstream — 审查所有 commits（从首个 commit 开始）
        const root = execSync("git rev-list --max-parents=0 HEAD", {
          encoding: "utf-8", stdio: ["pipe", "pipe", "ignore"]
        }).trim();
        if (root) {
          try {
            return execSync(`git diff ${root}..HEAD`, { encoding: "utf-8" });
          } catch { /* fall through */ }
        }
        return execSync("git diff HEAD", { encoding: "utf-8" });
      }
    } catch {
      return execSync("git diff HEAD", { encoding: "utf-8" });
    }
  }
}

/**
 * Get only added lines from a diff (exclude removed lines and diff headers).
 * This prevents false BLOCKED when a developer deletes a secret to fix a leak.
 */
function getAddedLines(diff) {
  return diff
    .split("\n")
    .filter((line) => /^\+[^+]/.test(line)) // starts with + but not ++
    .map((line) => line.slice(1))            // remove the + prefix
    .join("\n");
}

function scan(diff, allPatterns) {
  const findings = [];
  // Only scan added lines to avoid flagging secrets being removed
  const addedLines = getAddedLines(diff);

  for (const pat of allPatterns) {
    const { name, regex, level, category, flags } = pat;
    let re;
    try {
      re = new RegExp(regex, flags || "g");
    } catch {
      // Skip invalid regex patterns
      continue;
    }

    const matches = addedLines.match(re);
    if (matches) {
      const unique = [...new Set(matches)];
      findings.push({
        category: category || "unknown",
        name,
        level,
        count: unique.length,
        samples: unique.slice(0, 3),
      });
    }
  }
  return findings;
}

function filterFalsePositives(findings) {
  // Deep clone to avoid mutating the original
  const result = JSON.parse(JSON.stringify(findings));

  for (const f of result) {
    // Email filtering
    if (f.name === "Email (non-test)") {
      const emailExclude = /(test|example|localhost|your-?email)@|@(test|example|localhost)\./i;
      f.samples = f.samples.filter((s) => !emailExclude.test(s));
      f.count = f.samples.length;
    }

    // IP filtering — exclude private, link-local, multicast, CGNAT ranges
    if (f.name === "IP Address (non-private)") {
      const ipExclude = /^(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|0\.0\.0\.0|169\.254\.|22[4-9]\.|23[0-9]\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.|198\.(1[89]|2\d|3[01])\.)/;
      f.samples = f.samples.filter((s) => !ipExclude.test(s));
      f.count = f.samples.length;
    }

    // IP: also exclude IPs where any octet > 255
    if (f.name === "IP Address (non-private)") {
      f.samples = f.samples.filter((s) => {
        const octets = s.split(".").map(Number);
        return octets.length === 4 && octets.every((o) => o >= 0 && o <= 255);
      });
      f.count = f.samples.length;
    }

    // Generic Secret — exclude empty/placeholder values
    if (f.name === "Generic Secret Assignment") {
      const placeholderPattern = /(?:your_?|example|placeholder|test_?|dummy|changeme|xxx|TODO)/i;
      f.samples = f.samples.filter((s) => !placeholderPattern.test(s));
      f.count = f.samples.length;
    }
  }

  return result.filter((f) => f.count > 0);
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
      summary: {
        critical: criticals.length,
        high: highs.length,
        medium: mediums.length,
        total: findings.length,
      },
      findings: findings.map((f) => ({
        category: f.category,
        name: f.name,
        level: f.level,
        count: f.count,
      })),
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
      for (const s of f.samples) out += `      → ${s.trim()}\n`;
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
🛡️  pre-push-review — Push 前代码审查门禁 (v${VERSION})

用法:
  npx pre-push-review              # 审查 staged 改动
  npx pre-push-review --all        # 审查整个仓库 (仅文本文件)
  npx pre-push-review --ci         # CI 模式 (JSON 输出)
  npx pre-push-review --dry-run    # 扫描但始终 exit 0 (不阻止)
  npx pre-push-review --install    # 安装 git pre-push hook
  npx pre-push-review --version    # 显示版本
  npx pre-push-review --help       # 显示帮助

环境变量:
  REVIEW_MODE=strict   — HIGH 级别也阻止推送
  REVIEW_MODE=warn     — 永远不阻止，仅输出警告

项目配置:
  在项目根目录创建 .code_check.yml 来自定义审查规则
  详见: https://github.com/R0Bdhc/code_check
`);
  process.exit(0);
}

if (args.includes("--version")) {
  console.log(`pre-push-review v${VERSION}`);
  process.exit(0);
}

if (args.includes("--install")) {
  installHook();
  process.exit(0);
}

const isCI = args.includes("--ci");
const isDryRun = args.includes("--dry-run");

try {
  const projectRoot = process.cwd();
  const patterns = getEffectivePatterns(projectRoot);

  const diff = getDiff(args, patterns);
  if (!diff || diff.trim().length === 0) {
    console.log(isCI ? JSON.stringify({ conclusion: "CLEAR", summary: { critical: 0, high: 0, medium: 0, total: 0 }, findings: [] }) : "\nNo changes to review. ✅\n");
    process.exit(0);
  }

  const findings = filterFalsePositives(scan(diff, patterns.all));

  console.log(formatReport(findings, isCI));

  if (isDryRun) {
    console.log("(dry-run mode — not blocking)\n");
    process.exit(0);
  }

  const v = verdict(findings);
  if (v === "BLOCKED") {
    process.exit(1);
  }
  process.exit(0);
} catch (err) {
  console.error(`Error: ${err.message}`);
  process.exit(2);
}
