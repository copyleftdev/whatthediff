# GitHub repository metadata

Applied to copyleftdev/whatthediff. Kept in sync with the live repo settings.

## About (description)

> What actually matters across N files: consensus, drift, outliers and variant families — for configs, JSON, YAML, XML, PDF, even executables (SSDeep-class fuzzy analysis). Deterministic, evidence-backed, zero-dependency Zig.

## Topics (20 — GitHub's maximum)

Reweighted at v0.8.0 once the tool grew from a config differ into a
cross-format + binary-fuzzy analysis engine. Measured topic traffic
(repos, 2026-07-07) drove the mix — big-reach ponds for search matching,
precise low-competition niches where a new repo can actually rank:

- **Reach:** `cli` (103k), `developer-tools` (42k), `clustering` (10k),
  `reverse-engineering` (9.5k), `static-analysis` (5.7k),
  `anomaly-detection` (5.5k), `zig` (5.2k), `malware-analysis` (3k),
  `configuration-management` (2.5k), `diff` (2.3k)
- **Winnable niches:** `similarity` (498), `drift-detection` (710),
  `ssdeep` (33), `semantic-diff` (33), `fuzzy-hashing` (6)
- **Identity:** `command-line-tool`, `devops`, `ai-tools`, `outlier-detection`,
  `deterministic`

Dropped at v0.8.0 (generic noise where wtd was invisible / implementation
detail, not what the project *is*): `blake3`, `json`, `yaml`.

```
reverse-engineering malware-analysis ssdeep fuzzy-hashing similarity
anomaly-detection clustering outlier-detection drift-detection semantic-diff
diff static-analysis configuration-management devops cli command-line-tool
developer-tools ai-tools deterministic zig
```

## Re-apply with gh

```sh
gh repo edit copyleftdev/whatthediff \
  --description "What actually matters across N files: consensus, drift, outliers and variant families — for configs, JSON, YAML, XML, PDF, even executables (SSDeep-class fuzzy analysis). Deterministic, evidence-backed, zero-dependency Zig." \
  --add-topic reverse-engineering --add-topic malware-analysis \
  --add-topic ssdeep --add-topic fuzzy-hashing --add-topic similarity \
  --add-topic anomaly-detection --add-topic clustering \
  --add-topic outlier-detection --add-topic drift-detection \
  --add-topic semantic-diff --add-topic diff --add-topic static-analysis \
  --add-topic configuration-management --add-topic devops \
  --add-topic cli --add-topic command-line-tool --add-topic developer-tools \
  --add-topic ai-tools --add-topic deterministic --add-topic zig
```
