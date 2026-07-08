<div align="center">

# <img src="docs/peek.png" width="46" alt="Peek, the WhatTheDiff mantis shrimp mascot"> WhatTheDiff

**Traditional diff tools answer *"what changed?"* — WTD answers *"what actually matters?"***

[![Zig](https://img.shields.io/badge/Zig-0.14-f7a41d?logo=zig&logoColor=white)](https://ziglang.org)
[![Tests](https://img.shields.io/badge/tests-64%2F64-brightgreen)](#-testing)
[![Property iterations](https://img.shields.io/badge/property_iterations-1065-brightgreen)](#-testing)
[![Scale](https://img.shields.io/badge/1M_files-22µs%2Ffile-blue)](#-scale)
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

| kind        | source                                | canonical form                 |
|-------------|---------------------------------------|--------------------------------|
| `kv`        | JSON, YAML-lite, XML-lite, config     | `db.port=5432`, `features[]=x` |
| `heading`   | Markdown                         | `h2:Deployment`                |
| `line`      | PDF text, text fallback          | normalized text line           |
| `chunk`     | binaries / executables (SSDeep-style) | content-defined chunk hash |

Each primitive's identity is `BLAKE3(kind ‖ 0x00 ‖ canonical)`.
**The canonical form is cross-format**: `{"db":{"port":5432}}` in JSON,
`db:\n  port: 5432` in YAML, `[db]\nport = 5432` in INI, and
`<db port="5432"/>` in XML all hash to the same identity — a mixed-format
corpus finds real consensus instead of splitting into format factions. XML
attributes unify with child elements (attribute-vs-element is syntax, not
meaning). Lists are index-less (`features[]=x`), so reordering a list is
not drift. Every identity keeps its full occurrence
list (artifact + line): nothing is claimed without inspectable evidence.

With N artifacts and a primitive present in k of them:

> **universal** (k = N) · **majority** (2k > N) · **minority** (1 < k, 2k ≤ N) · **unique** (k = 1)

The **consensus core** is every primitive held by a strict majority. An
artifact's **drift** is 1 − Jaccard(its primitives, core); outliers are
flagged at mean + 1.5σ (N ≥ 4).

**Factions** go beyond outliers: clustering runs over *minority* primitives
only (the core can't distinguish groups; unique primitives belong to one
file), so a faction is precisely a set of files sharing the same deviations —
Jaccard ≥ 0.5 edges, union-find components, and each faction reports its
*signature* (`region=eu (3/3 members)`). Files matching the consensus form
the implicit main group and are never listed.

## 🚀 Quick start

**One-liner** (Linux, macOS, Git Bash — detects your OS/arch, verifies the
SHA256, installs to `/usr/local/bin` or `~/.local/bin`):

```sh
curl -fsSL https://raw.githubusercontent.com/copyleftdev/whatthediff/main/install.sh | sh
```

**Windows PowerShell:**

```powershell
irm https://raw.githubusercontent.com/copyleftdev/whatthediff/main/install.ps1 | iex
```

Pin a version with `WTD_VERSION=v0.5.0`, choose a directory with
`WTD_INSTALL_DIR`. Or grab a binary yourself from
[Releases](../../releases) — static, zero-install, for Linux
(x86_64/aarch64, fully static musl), macOS (Intel/Apple Silicon), and
Windows (x86_64/aarch64). Or build from source:

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
| `wtd configs/ --factions` | groups deviating from consensus together |
| `wtd configs/ --json` | machine-readable evidence graph (`wtd.report.v1`) |
| `wtd configs/ --json --evidence` | uncapped occurrence lists |
| `wtd ask "<question>" configs/` | AI explains the evidence (see below) |

## 🤖 wtd ask

```console
$ wtd ask "why is svc-d.yaml different from the others?" configs/
```

The deterministic engine runs first and selects the evidence relevant to your
question — the focus file's unique primitives (with line numbers), the
consensus-core primitives it's *missing*, and the corpus drift table. That
evidence block is the **only** thing the model sees, under a system prompt
that forbids stating anything not present in it and requires `(path:line)`
citations. The engine proves; the AI narrates. It can never invent a finding.

Works with three kinds of providers (checked in this order):

| provider | configure |
|---|---|
| Any custom/local endpoint (Ollama, llama.cpp, vLLM) | `WTD_AI_URL=http://localhost:11434/v1/chat/completions WTD_AI_MODEL=<model>` — no key needed |
| Anthropic Messages API | `ANTHROPIC_API_KEY=...` (default model `claude-opus-4-8`) |
| OpenRouter / OpenAI-compatible | `OPENROUTER_API_KEY=...` (honors `OPENROUTER_BASE_URL`, `OPENROUTER_MODEL`) |

`--model <m>` overrides the model; `--dry-run` prints the exact prompt
(system + evidence) without calling anything — useful for auditing what the
model is allowed to know, and it needs no key.

## 🔬 Binary & executable analysis

<img src="docs/peek-re.png" align="right" width="220" alt="Peek in RE mode — the mascot suited up with a scanner cannon and targeting reticle for hunting through binaries">

Point wtd at a directory of executables and it does **SSDeep-class fuzzy
analysis** — but self-explaining. Each binary is cut into *content-defined
chunks* (the same content-triggered piecewise hashing technique inside
SSDeep/CTPH: a rolling hash picks chunk boundaries from the bytes, so
inserting or removing data only disturbs nearby chunks and the rest re-sync).
Each chunk is a primitive, so the existing consensus/drift/**faction** engine
clusters binaries by shared code — and tells you *which* chunks, at what byte
offsets.

```console
$ wtd ./samples --factions
Factions (groups deviating from consensus in the same way)
  faction of 3 · cohesion 1.00
    members: samples/mathapp-v1, samples/mathapp-v2, samples/mathapp-v3
    shared: chunk f722a9b73035213b…  (3/3 members)
  faction of 3 · cohesion 1.00
    members: samples/textproc-v1, samples/textproc-v2, samples/textproc-v3
    shared: chunk 2123887eae9ddcfe…  (3/3 members)
```

Six stripped ELF binaries, two families of three variants each — clustered
correctly with nothing but the bytes. Unlike SSDeep's pairwise 0–100 score,
you get family clustering, the shared-vs-unique regions as evidence, and
`wtd ask "which binaries are variants of the same program?"`. A single
`binary.format=elf/x86_64` primitive also groups by platform, so a lone PE
among ELF files is an outlier before chunk analysis even matters. ELF, PE,
Mach-O, Wasm, and JVM/ar formats are recognized; any other binary is chunked
generically. Executable extensions (`.exe .dll .so .dylib .bin .o .wasm` …)
route here, and extensionless files that sniff as binary do too.

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

Measured 2026-07-07, ReleaseFast (v0.5.0 streaming store):

| files | planted rogues | wall | per file | RSS | verdict |
|---:|---:|---:|---:|---:|:---:|
| 1,000 | 20 | 0.02 s | 20 µs | 4 MB | ✅ exact |
| 10,000 | 200 | 0.18 s | 18 µs | 37 MB | ✅ exact |
| 50,000 | 1,000 | 0.93 s | 19 µs | 186 MB | ✅ exact |
| 200,000 | 4,000 | 3.88 s | 19 µs | 754 MB | ✅ exact |
| **1,000,000** | **20,000** | **21.8 s** | **22 µs** | **3.8 GB** | ✅ exact |

Per-file cost is **flat** — time scales linearly, zero false positives at
every size (at 1M files: 2.56M distinct primitives, 41.8M observations, all
20,000 planted rogues flagged with zero false positives). The streaming
evidence store keeps file contents and parse trees in a per-artifact arena
that's reset after each file, so **resident memory scales with distinct
facts, not corpus bytes** — engine-only RSS at 1M files is 3.35 GB
(~3.3 KB/artifact for this corpus profile); `--json` adds the materialized
report on top. Oversized (>64 MiB) artifacts are skipped cleanly, never
fatal.

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

- [x] `wtd ask "why is contract_17 different?"` — AI adapter explaining the
  evidence graph (v0.2.0: Anthropic / OpenAI-compatible / local endpoints)
- [x] Cross-format canonical unification (v0.3.0: same fact in JSON, YAML, or
  INI → same identity; property-tested with random structures serialized both ways)
- [x] Pairwise similarity / clustering — find factions, not just outliers
  (v0.4.0: minority-set Jaccard + union-find, faction signatures, property-tested
  exact recovery of planted factions)
- [x] Streaming evidence store for millions of artifacts (v0.5.0: per-artifact
  scratch arena + one-copy canonicals + u32 index sets; 1M files in 21.8 s /
  3.8 GB RSS, detection still exact)
- [x] XML extractor (v0.6.0: XML-lite with entities/CDATA/DOCTYPE; attributes
  unify with child elements; property-tested against JSON on random structures)
- [x] PDF text extractor (v0.7.0: zero-dependency — FlateDecode via
  std.compress.zlib, text operators BT/Tj/TJ/quote, escapes/hex/CID filtering;
  validated against pandoc/LaTeX and ghostscript output; roundtrip property test)
- [x] Binary / executable fuzzy analysis (v0.8.0: content-defined chunking —
  the SSDeep/CTPH core — so the consensus/drift/faction engine clusters
  binaries by shared code; validated clustering real compiled ELF variants
  into families; format+arch detection for ELF/PE/Mach-O/Wasm)
- [ ] Source-code extractors (semantic, beyond line-level)

## 📜 Design notes

The full engineering philosophy — deterministic pipeline, evidence model,
AI responsibilities, non-goals — lives in [intent.md](intent.md).
