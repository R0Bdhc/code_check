// ============================================================
// code_check/lib/config.js — Node.js config loader
// ============================================================
// Loads patterns.json and merges with project-level .code_check.yml.
// ============================================================

const fs = require("fs");
const path = require("path");

// ─── Built-in patterns (from patterns.json) ──────────────────
const builtinPatterns = (() => {
  try {
    return JSON.parse(
      fs.readFileSync(path.join(__dirname, "..", "patterns.json"), "utf-8")
    );
  } catch {
    // Fallback inline patterns if patterns.json is missing
    return {
      version: "1.0.0",
      entropy: { threshold: 40, excludePatterns: [] },
      patterns: {
        secrets: [
          { name: "AWS Access Key", regex: "AKIA[0-9A-Z]{16}", level: "CRITICAL" },
          { name: "Stripe Live Key", regex: "sk_live_[0-9a-zA-Z]{24,}", level: "CRITICAL" },
          { name: "GitHub Token", regex: "ghp_[0-9a-zA-Z]{36}", level: "CRITICAL" },
          { name: "GitHub OAuth", regex: "gho_[0-9a-zA-Z]{36}", level: "CRITICAL" },
          { name: "Slack Token", regex: "xox[baprs]-[0-9a-zA-Z-]{10,}", level: "CRITICAL" },
          { name: "Google API Key", regex: "AIza[0-9A-Za-z\\-_]{35}", level: "CRITICAL" },
        ],
        pii: [
          { name: "Chinese Phone", regex: "1[3-9]\\d{9}", level: "HIGH" },
          { name: "Chinese ID Card", regex: "[1-9]\\d{5}(?:19|20)\\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\\d|3[01])\\d{3}[\\dXx]", level: "CRITICAL" },
          { name: "Email (non-test)", regex: "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}", level: "HIGH", exclude: ["test@", "example@", "localhost", "@test", "@example", "@localhost", "your-?email"] },
          { name: "IP Address (non-private)", regex: "\\b(?!127\\.|10\\.|192\\.168\\.|172\\.(?:1[6-9]|2\\d|3[01])\\.|0\\.0\\.0\\.0)(\\d{1,3}\\.){3}\\d{1,3}\\b", level: "MEDIUM" },
        ],
        logLeak: [
          { name: "Log Sensitive Data", regex: "(?:console\\.(?:log|error|warn|debug|info)|println!|log\\.|logger\\.|logging\\.)[^(]*\\([^)]*(?:password|secret|token|key|credential|pii|ssn|credit|card)[^)]*\\)", level: "CRITICAL", flags: "i" },
        ],
        weakCrypto: [],
        dangerousExec: [],
      },
    };
  }
})();

// ─── Project config loading ──────────────────────────────────

/**
 * Simple YAML-like config parser — handles the .code_check.yml schema only.
 * Does NOT parse arbitrary YAML.
 */
function parseCodeCheckYml(filePath) {
  try {
    const content = fs.readFileSync(filePath, "utf-8");
    const lines = content.split("\n");
    const config = {
      review_mode: "normal",
      skip_review: false,
      ignore_patterns: [],
      ignore_paths: [],
      custom_patterns: { secrets: [], pii: [], logLeak: [], weakCrypto: [], dangerousExec: [] },
    };

    let currentSection = null;

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;

      // Top-level keys
      const reviewMode = trimmed.match(/^review_mode:\s*(.+)/);
      if (reviewMode) { config.review_mode = reviewMode[1].replace(/['"]/g, "").trim(); continue; }

      const skipReview = trimmed.match(/^skip_review:\s*(.+)/);
      if (skipReview) { config.skip_review = skipReview[1] === "true" || skipReview[1] === "1"; continue; }

      // Section headers
      if (trimmed === "ignore_patterns:") { currentSection = "ignore_patterns"; continue; }
      if (trimmed === "ignore_paths:") { currentSection = "ignore_paths"; continue; }
      if (trimmed === "custom_patterns:") { currentSection = "custom_patterns"; continue; }

      // Sub-sections under custom_patterns
      if (currentSection === "custom_patterns") {
        if (trimmed === "secrets:") { currentSection = "custom_secrets"; continue; }
        if (trimmed === "pii:") { currentSection = "custom_pii"; continue; }
        if (trimmed === "logLeak:") { currentSection = "custom_logLeak"; continue; }
        if (trimmed === "weakCrypto:") { currentSection = "custom_weakCrypto"; continue; }
        if (trimmed === "dangerousExec:") { currentSection = "custom_dangerousExec"; continue; }
        if (trimmed.match(/^[a-zA-Z]/)) { currentSection = null; continue; }
      }

      // List items
      const listItem = trimmed.match(/^-\s+(.+)/);
      if (listItem) {
        const value = listItem[1].replace(/['"]/g, "").trim();
        if (currentSection === "ignore_patterns") config.ignore_patterns.push(value);
        else if (currentSection === "ignore_paths") config.ignore_paths.push(value);
        else if (currentSection && currentSection.startsWith("custom_")) {
          const cat = currentSection.replace("custom_", "");
          // Parse "name | regex | level" format
          const parts = value.split("|").map((s) => s.trim());
          if (parts.length >= 3) {
            config.custom_patterns[cat].push({
              name: parts[0],
              regex: parts[1],
              level: parts[2].toUpperCase(),
            });
          }
        }
        continue;
      }

      // Exit sections
      if (trimmed.match(/^[a-zA-Z]/) && currentSection && !currentSection.startsWith("custom_")) {
        currentSection = null;
      }
    }

    return config;
  } catch {
    return null;
  }
}

/**
 * Get effective patterns after merging project config.
 * @param {string} projectRoot — path to project root
 * @returns {object} merged patterns with all categories flattened
 */
function getEffectivePatterns(projectRoot) {
  const configPath = path.join(projectRoot || process.cwd(), ".code_check.yml");
  const projectConfig = parseCodeCheckYml(configPath) || {};

  const ignorePatterns = projectConfig.ignore_patterns || [];
  const customPatterns = projectConfig.custom_patterns || {};
  const ignorePaths = projectConfig.ignore_paths || [];

  // Deep clone builtin patterns
  const effective = JSON.parse(JSON.stringify(builtinPatterns));

  // Filter out ignored patterns by name
  for (const category of Object.keys(effective.patterns)) {
    effective.patterns[category] = effective.patterns[category].filter(
      (p) => !ignorePatterns.includes(p.name)
    );
  }

  // Append custom patterns
  for (const category of Object.keys(customPatterns)) {
    if (effective.patterns[category]) {
      effective.patterns[category].push(...(customPatterns[category] || []));
    }
  }

  // Flatten all categories into a single array for scanning
  effective.all = [
    ...effective.patterns.secrets.map((p) => ({ ...p, category: "security" })),
    ...effective.patterns.pii.map((p) => ({ ...p, category: "privacy" })),
    ...effective.patterns.logLeak.map((p) => ({ ...p, category: "log-leak" })),
    ...effective.patterns.weakCrypto.map((p) => ({ ...p, category: "weak-crypto" })),
    ...effective.patterns.dangerousExec.map((p) => ({ ...p, category: "dangerous-exec" })),
  ];

  effective.ignore_paths = ignorePaths;
  effective.review_mode = projectConfig.review_mode || "normal";

  return effective;
}

module.exports = { builtinPatterns, parseCodeCheckYml, getEffectivePatterns };
