<div align="center">

# 🔍 WhatTheDiff

**Traditional diff tools answer *"what changed?"* — WTD answers *"what actually matters?"***

[![Zig](https://img.shields.io/badge/Zig-0.14-f7a41d?logo=zig&logoColor=white)](https://ziglang.org)
[![Tests](https://img.shields.io/badge/tests-29%2F29-brightgreen)](#-testing)
[![Property iterations](https://img.shields.io/badge/property_iterations-565-brightgreen)](#-testing)
[![Scale](https://img.shields.io/badge/200k_files-23µs%2Ffile-blue)](#-scale)
[![Deterministic](https://img.shields.io/badge/reports-byte--identical-8A2BE2)](#-testing)
[![Dependencies](https://img.shields.io/badge/dependencies-0-lightgrey)](#-architecture)
[![Platforms](https://img.shields.io/badge/platforms-Linux%20·%20macOS%20·%20Windows-informational)](#-quick-start)

</div>

Point WTD at **N artifacts** — configs, JSON, YAML, Markdown, logs, anything text —
and it tells you what they agree on, what drifted, which one is the outlier,
and shows the **evidence** behind every claim. The deterministic engine is the
source of truth; an AI only ever explains what the engine proved.

```console
$ wtd configs/
WhatTheDiff — corpus analysis
Corpus: 5 artifacts · 12 distinct primitives · 34 observations

Consensus
  universal       2  (present in all 5 artifacts)
  majority        5
  minority        0
  unique          5
  consensus core: 7 primitives

Drift (distance from consensus core, 0 = pure consensus)
  0.727  configs/svc-d.yaml   ⚠ OUTLIER
  0.375  configs/svc-c.yaml
  0.000  configs/svc-a.yaml
  ...

Evidence — unique primitives
  configs/svc-d.yaml  (4 unique)
    kv        admin_backdoor=enabled  (line 7)
    kv        tls=false               (line 5)
    kv        db.host=10.9.9.9        (line 3)
```

## ✨ Why WTD

- **Meaning over syntax.** Key order, whitespace, quoting, and comments never
  register as difference — only facts do.
- **Evidence over vibes.** Every observation answers: what, where, in how many
  artifacts, and can I inspect the proof?
- **Determinism over magic.** Same corpus in → byte-identical report out.
  The LLM (roadmap) explains conclusions; it never invents them.

## ⚙️ How it works

```
artifacts → normalization → primitive extraction → canonical form
          → BLAKE3 identity → evidence store → consensus → drift → report
```

Artifacts are never compared as raw text. Each is decomposed into
**primitives** — stable semantic facts:

| kind        | source            | canonical form      |
|-------------|-------------------|---------------------|
| `json_leaf` | JSON (parsed)     | `$.db.port=5432`    |
| `kv`        | YAML-lite, config | `db.host=localhost` |
| `heading`   | Markdown          | `h2:Deployment`     |
| `line`      | text fallback     | trimmed line        |

Each primitive's identity is `BLAKE3(kind ‖ 0x00 ‖ canonical)`. Every identity
keeps its full occurrence list (artifact + line): nothing is claimed without
inspectable evidence.

With N artifacts and a primitive present in k of them:

> **universal** (k = N) · **majority** (2k > N) · **minority** (1 < k, 2k ≤ N) · **unique** (k = 1)

The **consensus core** is every primitive held by a strict majority. An
artifact's **drift** is 1 − Jaccard(its primitives, core); outliers are
flagged at mean + 1.5σ (N ≥ 4).

## 🚀 Quick start

Grab a prebuilt binary from [Releases](../../releases) — static, zero-install,
for Linux (x86_64/aarch64, fully static musl), macOS (Intel/Apple Silicon),
and Windows (x86_64/aarch64). Or build from source:

```sh
zig build -Doptimize=ReleaseFast    # → zig-out/bin/wtd  (Zig 0.14, zero deps)
zig build test                      # unit + property + e2e tests
zig build release                   # cross-compile all six targets
scripts/release.sh                  # test + package dist/*.tar.gz|zip + SHA256SUMS
```

| command | result |
|---|---|
| `wtd <path>...` | full human report |
| `wtd configs/ --drift` | drift ranking only |
| `wtd configs/ --consensus` | consensus buckets only |
| `wtd configs/ --json` | machine-readable evidence graph (`wtd.report.v0`) |
| `wtd configs/ --json --evidence` | uncapped occurrence lists |

## 🧪 Testing

Three deterministic layers:

**Unit tests** — per-module contracts (extractors, store, buckets, renderers).

**Property-based tests** (`src/proptest.zig`) — seeded random corpora checked
against independent oracles, QuickCheck-style; every failure prints its seed:

- **Counting oracle** — analysis must agree with statistics recomputed from a
  raw membership matrix (buckets, core, drift to 1e-12, Σ totals = Σ k)
- **Permutation invariance** — feed order never changes the analysis
- **Twin property** — identical artifacts get identical statistics
- **Planted rogue** — a mostly-unique artifact among conformers is *always*
  the flagged outlier
- **JSON equivalence** — documents reserialized with shuffled keys and random
  whitespace yield byte-identical primitives
- **Pipeline determinism** — same on-disk corpus → byte-identical JSON report

**Scale benchmark** (`scripts/bench.sh`) — generates deterministic corpora
with planted rogues (`gencorpus`), then **fails unless WTD flags exactly the
planted set** at every size.

## 📈 Scale

Measured 2026-07-07, ReleaseFast, tmpfs:

| files | planted rogues | wall | per file | RSS | verdict |
|---:|---:|---:|---:|---:|:---:|
| 1,000 | 20 | 0.02 s | 20 µs | 9.5 MB | ✅ exact |
| 10,000 | 200 | 0.22 s | 22 µs | 93 MB | ✅ exact |
| 50,000 | 1,000 | 1.14 s | 23 µs | 478 MB | ✅ exact |
| 200,000 | 4,000 | 4.63 s | 23 µs | 1.9 GB | ✅ exact |

Per-file cost is **flat** — time scales linearly, zero false positives at
every size. Memory (~9.6 KB/artifact resident, ~3× for JSON parse trees) is
the current ceiling: 2M artifacts extrapolates to ~46 s CPU but ~19 GB RSS,
which is why the streaming evidence store is on the roadmap. Oversized
(>64 MiB) artifacts are skipped cleanly, never fatal.

```sh
scripts/bench.sh                  # 100 → 50k files, yaml
SIZES="200000" scripts/bench.sh   # bigger
FORMAT=json scripts/bench.sh      # json corpora
```

## 🏗 Architecture

```
src/
  types.zig        core contracts: Artifact, Primitive, Identity, Occurrence
  discovery.zig    paths → sorted candidates (skips VCS/dot dirs, binaries)
  extract.zig      kind → extractor dispatch, graceful text fallback
  extractors/      json · yamlish · config · markdown · text
  hash.zig         BLAKE3 primitive identity
  evidence.zig     identity → observation (occurrences, artifact counts)
  analysis.zig     consensus buckets, core, drift, outlier detection
  render.zig       deterministic text + JSON reports
  engine.zig       pipeline orchestration
  cli.zig          argument parsing, exit codes
tools/gencorpus.zig  deterministic corpus generator for scale testing
```

Contract-first, small composable modules, no hidden state, no dependencies.
Each module is independently testable and replaceable; extractors degrade
(malformed JSON falls back to line primitives) rather than fail.

## 🗺 Roadmap

- [ ] `wtd ask "why is contract_17 different?"` — AI adapter explaining the
  evidence graph (the `--json` report is already its input contract)
- [ ] Cross-format canonical unification (same fact in JSON and YAML → same identity)
- [ ] Pairwise similarity / clustering — find factions, not just outliers
- [ ] PDF, XML, and source-code extractors
- [ ] Streaming evidence store for millions of artifacts

## 📜 Design notes

The full engineering philosophy — deterministic pipeline, evidence model,
AI responsibilities, non-goals — lives in [intent.md](intent.md).
