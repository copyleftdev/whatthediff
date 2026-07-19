<div align="center">

# <img src="docs/peek.png" width="46" alt="Peek, the WhatTheDiff mantis shrimp mascot"> WhatTheDiff

**Traditional diff tools answer *"what changed?"* — WTD answers *"what actually matters?"***

[![Version](https://img.shields.io/badge/version-1.11.1-0090ff)](https://github.com/copyleftdev/whatthediff/releases/latest)
[![Zig](https://img.shields.io/badge/Zig-0.14-f7a41d?logo=zig&logoColor=white)](https://ziglang.org)
[![Tests](https://img.shields.io/badge/tests-109%2F109-brightgreen)](#-testing)
[![Property iterations](https://img.shields.io/badge/property_iterations-1915-brightgreen)](#-testing)
[![Scale](https://img.shields.io/badge/1M_files-22µs%2Ffile-blue)](#-scale)
[![Deterministic](https://img.shields.io/badge/reports-byte--identical-8A2BE2)](#-testing)
[![Dependencies](https://img.shields.io/badge/dependencies-0-lightgrey)](#-architecture)
[![Platforms](https://img.shields.io/badge/platforms-Linux%20·%20macOS%20·%20Windows-informational)](#-quick-start)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[![Tip my tokens](https://tokentip.to/badge/copyleftdev.svg?logo=1)](https://tokentip.to/@copyleftdev)

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
  The optional `wtd ask` LLM layer explains conclusions; it never invents them.

## ⚙️ How it works

```
artifacts → normalization → primitive extraction → canonical form
          → BLAKE3 identity → evidence store → consensus → drift → report
```

Artifacts are never compared as raw text. Each is decomposed into
**primitives** — stable semantic facts:

| kind        | source                                | canonical form                 |
|-------------|---------------------------------------|--------------------------------|
| `kv`        | JSON/JSONC, YAML-lite, XML-lite, CBOR, config | `db.port=5432`, `features[]=x` |
| `heading`   | Markdown                         | `h2:Deployment`                |
| `line`      | PDF text, text fallback          | normalized text line           |
| `chunk`     | binaries / executables (SSDeep-style) | content-defined chunk hash |
| `kv` (bag)  | executable imports/exports/sections/strings | `imports[]=CreateRemoteThread` |
| `kv` (bag)  | HTML/DOM structure, form fields, resource hosts | `shape[]=a1b2c3`, `field[]=password` |

Each primitive's identity is `BLAKE3(kind ‖ 0x00 ‖ canonical)`.
**The canonical form is cross-format**: `{"db":{"port":5432}}` in JSON,
`db:\n  port: 5432` in YAML, `[db]\nport = 5432` in INI,
`<db port="5432"/>` in XML, and the **CBOR bytes** `A2 62 64 62 …` all hash to
the same identity — a mixed-format
corpus finds real consensus instead of splitting into format factions. XML
attributes unify with child elements (attribute-vs-element is syntax, not
meaning). Lists are index-less (`features[]=x`), so reordering a list is
not drift. JSON parsing is **JSONC-tolerant** — comments and trailing commas
are handled, so `tsconfig.json`, VS Code `settings.json`, and `devcontainer.json`
parse semantically instead of degrading to line comparison. Every identity keeps its full occurrence
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

Pin a version with `WTD_VERSION=v1.11.1`, choose a directory with
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
| `wtd configs/ --conflicts` | keys the fleet disagrees on: majority value + the deviant files |
| `wtd configs/ --fail-on conflicts` | CI gate: exit 3 if the fleet disagrees |
| `wtd configs/ --factions` | groups deviating from consensus together |
| `wtd creds/ --keys-only` | compare structure not values — secret-safe schema drift |
| `wtd configs/ --json` | machine-readable evidence graph (`wtd.report.v1`) |
| `wtd configs/ --json --evidence` | uncapped occurrence lists |
| `wtd ask "<question>" configs/` | AI explains the evidence (see below) |
| `wtd yara ./samples` | candidate YARA rule per detected binary family |
| `wtd ./pages --factions` | cluster captured web pages — find the shared phishing kit |
| `wtd web <url>… [--timeout s] [--snapshot-dir d]` | fetch pages and cluster them; bounded, reproducible |
| `wtd kit ./pages` | kit signature per web family (fields, action host, resources) |
| `wtd ./pages --fail-on credential-forms` | flag/gate pages harvesting credentials (per-page) |

> **Secret-safe schema comparison.** `--keys-only` drops the value from every
> `key=value` primitive (`db.port=5432` → `db.port`) and hashes structureless
> lines, so no secret ever enters the report — point it straight at
> `~/.creds`, `.env` files across environments, or any credential profiles to
> find *schema* drift ("which env is missing a key?", "which profiles share an
> auth shape?") without exposing a single value. Shell `export KEY=…` is
> normalized to `KEY` so it matches bare declarations.

## 🎯 Conflicts — the odd-one-out report

Drift and factions tell you *which files* differ. `--conflicts` answers the
sharper operational question: for a given key, **what value does the fleet
agree on, and exactly which files disagree?**

```console
$ wtd configs/ --conflicts

Conflicts (scalar keys the fleet disagrees on)
  db.port
    ✓   40×  5432
         1×  5433   prod-17.yaml
  logging.level
    ✓   38×  info
         3×  debug  staging-2.json, staging-7.json, staging-9.json
  2 keys in conflict
```

The `✓` marks the plurality (consensus) value; every other row names the files
holding a deviant value. It is **cross-format**: the 40 votes for `5432` may be
JSON while the deviant is YAML — same key, same canonical, one reconciliation.

Two deliberate exclusions keep the signal clean: **list keys** (`features[]`)
are bags, not scalars, so multiple values are never a conflict; and a key is
only reported when its plurality value is shared by **≥ 2 files**, which drops
identifier fields (hostnames, node ids) where every file legitimately differs.
Under `--keys-only` values are gone entirely, so conflicts reports nothing —
secret-safe by construction. Machine-readable via `--json` (`conflicts[]`, each
with `key`, `holders`, `deviants`, and per-value witness sets).

## 🚦 CI gate — `--fail-on`

Turn any of that into an enforcement rule. `--fail-on` evaluates a policy and
**exits `3`** when the corpus violates it, so a pipeline blocks the change:

```console
$ wtd configs/ --fail-on conflicts
...
Gate (--fail-on)
  ✗ conflicts  1 (threshold > 0)  FAIL
  GATE FAILED
$ echo $?
3
```

The spec is a comma-separated list of conditions — a bare count means "> 0":

| condition | fails when |
|---|---|
| `conflicts` / `conflicts>N` | any conflicting key / more than N |
| `outliers` / `outliers>N` | any drift outlier / more than N |
| `drift>F` | any artifact's drift exceeds `F` (0–1) |
| `credential-forms` / `>N` | any page harvests credentials / more than N |

e.g. `--fail-on 'conflicts,drift>0.5'`. **Exit codes:** `0` ok · `1` error ·
`2` usage · `3` gate failed. The verdict is in `--json` too (a `gate` object,
`null` when the flag is absent), so machine consumers read `.gate.failed`.

Drop it into GitHub Actions to block config drift on every PR:

```yaml
- name: Guard config fleet
  run: |
    curl -fsSL https://raw.githubusercontent.com/copyleftdev/whatthediff/main/install.sh | sh
    wtd ./configs --fail-on 'conflicts,outliers'
```

Point it at credential profiles with `--keys-only --fail-on conflicts` and the
gate stays secret-safe — no value is ever compared or printed.

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

### Structured RE features — triage on meaning, not opaque bytes

Chunks cluster binaries, but `chunk a1b2c3…` tells an analyst nothing. So wtd
also lifts the facts a reverse engineer actually triages on and emits them as
primitives that flow through the *same* engine:

| primitive | from |
|---|---|
| `imports[]=` / `exports[]=` | ELF dynsym · PE import/export dirs · Mach-O symtab |
| `needs[]=` | shared libraries / imported DLLs |
| `sections[]=` | section / segment names |
| `strings[]=` | ASCII + UTF-16LE runs (all inputs, incl. raw firmware) |

Now consensus/drift/factions work on *behavior*: a network tool dropped into a
folder of coreutils is the outlier because it **uniquely imports** socket and
TLS functions — surfaced as named evidence, not a chunk hash. A feature shared
across a subgroup *is* a faction signature; one in a single sample is unique
evidence. The parsers are validated against `nm`/`readelf`/`objdump`/`llvm-nm`
on real binaries — imports, exports, needs, and sections match exactly — and
every parser is bounds-checked, so a truncated or hostile binary yields fewer
features, never a crash.

```console
$ wtd ./coreutils-and-curl        # curl.bin flagged at 0.990 drift
  Evidence — unique primitives
    curl.bin
      imports[]=curl_easy_ssls_export     # behavior no coreutil has
      ...
```

## 🌐 Web pages & phishing-kit clustering

A captured DOM is just another artifact. Point wtd at a folder of saved HTML
pages and it decomposes each into **structural facts** — a fuzzy skeleton
(`shape[]`, w-shingles of the tag stream), form field names (`field[]`), the
form's action host, and external resource hosts — then runs the same
consensus / drift / **faction** engine. A phishing kit reused across many
domains produces near-identical structure, so it clusters even when every
deployment is rebranded:

```console
$ wtd ./captured-pages --factions
  faction of 4 · cohesion 0.95
    members: deploy-northbank.html, deploy-westcu.html, deploy-pacific.html, deploy-metro.html
    shared: field[]=email · field[]=password · field[]=otp   # what the kit harvests
    shared: formaction[]=collect.kit-hoster.example          # where it exfiltrates
    shared: formfields[]=bd2123…                             # the field-set fingerprint
```

Four pages impersonating four different banks — one kit, surfaced by structure,
not branding. The whole trick is **normalization**: hashed class names, session
tokens, inline styles and injected ads are dropped, repeated siblings collapse
to a bag, and the tag-stream is w-shingled so an injected element only disturbs
local windows (property-tested: reformatting never changes a primitive). A kit
shows up as a *faction* when it's a minority among diverse pages — exactly how
you'd scan a suspect set.

Point it at **saved `.html` snapshots**, or let wtd **fetch** the pages itself:

```console
$ wtd web https://a.example/login https://b.example/signin … --snapshot-dir ./caps --factions
wtd: fetched 8/8 URLs
  faction of 6 · cohesion 0.94   # one kit across six domains
```

`wtd web` retrieves raw HTML over a zero-dep `std.http` client, the report shows
the **URLs** as artifact names, and `--snapshot-dir` persists exactly what was
fetched so the analysis is reproducible: fetching is I/O, the analysis over
those bytes is deterministic. Each request has a hard **`--timeout`** (default
10 s) so dead or stalling hosts — endemic in real phishing feeds — can't hang
the run; per-URL failures are skipped, never fatal. *(You choose the targets —
fetching suspected-malicious URLs touches attacker infra from your host; run it
where that's acceptable.)*

> **JS-rendered forms need a rendered capture.** `wtd web` fetches
> *server-rendered* HTML. Many modern phishing pages inject the credential
> `<form>` with JavaScript, so a raw fetch sees the skeleton, branding and
> resource hosts (enough to cluster the kit) but not the harvested fields. To
> get those, capture the **rendered DOM** with a headless browser and feed the
> `.html` to wtd:
>
> ```sh
> # one page, rendered DOM → snapshot
> chromium --headless --disable-gpu --dump-dom "https://site.example/login" > caps/site.html
> # …repeat per URL (Playwright's page.content() works too), then:
> wtd kit ./caps
> ```
>
> Rendering is out of scope for the zero-dependency core; the snapshot workflow
> keeps that boundary clean while still handling SPAs.

### `wtd kit` — turn a web family into a signature

The web analog of `wtd yara`. For each detected family, `wtd kit` computes the
**discriminative core** — features present in every member and absent from
every other page — and emits a kit descriptor:

```console
$ wtd kit ./captured-pages
Kit signature #0 — 4 members
  members: deploy-northbank.html, deploy-westcu.html, deploy-pacific.html, deploy-metro.html
  harvests (form fields): email, otp, password
  field-set fingerprint:  bd2123…
  posts to (form action): collect.kit-hoster.example
  loads (resources):      cdn.kit-hoster.example
  structure:              24 exclusive skeleton shingles
```

Same soundness as `wtd yara`: every atom's witness set equals the member set
exactly, so it matches the whole family and nothing else you scanned. A family
with only shared structure (and no fields/action/resource) is labelled a
*structural cluster*, not a kit. Machine-readable via `--json` (`wtd.kit.v1`) —
drop it into a SOC pipeline. Rebranded deployments still cluster because the
signature is the kit's *function*, not its branding.

### Credential-form flag — per page, no clustering needed

Kit signatures need a *family* (≥2 deployments). Real feeds are full of
**one-off harvesters** — a lone login page on a throwaway domain — that never
cluster. wtd flags each of those on its own: any page whose form collects a
password (or ≥2 sensitive fields — card, cvv, ssn, otp, seed/mnemonic for
wallet phishing) is reported, and posting **off-domain** is marked as an
exfiltration signal:

```console
$ wtd web https://lure.example/signin        # or: wtd ./captured-pages
Credential forms (1 page harvesting credentials)
  https://lure.example/signin
    harvests: password, username   posts to: collect.attacker.example  ⚠ OFF-DOMAIN
```

It shows in the report and `--json` (`credential_forms[]`), `wtd kit` lists the
un-clustered ones after its family signatures, and **`--fail-on
credential-forms`** turns it into a CI gate — brand monitoring that fails the
moment a watched page sprouts a login form posting to someone else's host.
(Benign pages stay silent — a search box or a lone newsletter email never flag.)

### `wtd yara` — turn a family into a detection rule

Clustering tells you *these are related*. The next step an analyst needs is
*what defines the family, and can I detect it?* `wtd yara` computes each
family's **discriminative core** — features present in **every member and
absent from every other sample in the corpus** — and writes a candidate YARA
rule from them:

```console
$ wtd yara ./samples
rule wtd_family_0
{
    meta:
        description = "wtd discriminative signature for a 3-member family"
        members = "sampleA.bin, sampleB.bin, sampleC.bin"
    strings:
        $imp0 = "CreateRemoteThread" ascii wide
        $str3 = "%s\\svchost.exe" ascii wide
        $c7   = { e8 ?? ?? ?? ?? 8b 45 fc ... }
    condition:
        6 of them
}
```

The soundness guarantee is what makes it trustworthy: **an atom is emitted only
when its witness set equals the family's member set exactly** — shared across
the whole family, matching nothing else in the corpus you ran it on
(property-tested). Atoms are drawn from the structured features (imports,
strings, sections) and from discriminative code chunks (as YARA hex); symbolic,
readable atoms are preferred over raw bytes. It's the anti-`yarGen`:
deterministic, and every atom traces to evidence, not a heuristic. It's a
*candidate* — "absent elsewhere" is only proven against your corpus — so review
before shipping.

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

**v1.0** — the full [intent.md](intent.md) vision is shipped: deterministic
pipeline, evidence model, consensus/drift/factions, AI explanation, cross-format
unification, million-file scale — plus two capabilities that weren't in the
original spec (SSDeep-class binary analysis, secret-safe schema comparison).

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
- [x] Secret-safe schema comparison — `--keys-only` + `export` normalization
  (v0.9.0: compare credential/env profiles by key structure, no value ever
  reaches the report)

**Post-1.0, shipped:**

- [x] JSONC tolerance (v1.1.0: `tsconfig.json` / VS Code settings — comments and
  trailing commas stripped on parse failure, string literals preserved)
- [x] CBOR extractor (v1.2.0: RFC 8949 binary decoder — the same fact in CBOR
  and JSON hashes to one identity; property-tested JSON↔CBOR)
- [x] Conflicts — the odd-one-out report (v1.3.0: `--conflicts` reports the
  fleet's agreed value per scalar key and names the deviant files; cross-format,
  secret-safe under `--keys-only`; property-tested planted-conflict recovery)
- [x] CI gate (v1.4.0: `--fail-on conflicts|outliers|drift>F` exits 3 on policy
  violation — turns wtd into a pipeline guard; verdict in text + JSON;
  property-tested against an independent threshold oracle)
- [x] Structured RE features (v1.5.0: ELF/PE/Mach-O imports, exports, sections,
  needed libs, and strings as primitives — triage binaries by behavior;
  parsers validated exactly against nm/readelf/objdump/llvm-nm)
- [x] Discriminative family signatures → candidate YARA rules (v1.6.0:
  `wtd yara` emits a rule per family from features exclusive to its members;
  soundness property-tested — every atom's witness set equals the member set)
- [x] HTML/DOM extractor for web-page clustering (v1.7.0: structural shingles,
  form fields, resource hosts → phishing-kit / clone detection over captured
  pages; formatting-invariance property-tested)
- [x] `wtd web <url>…` fetching (v1.8.0: zero-dep std.http GET + `--snapshot-dir`
  reproducible capture; URLs become artifact names, per-URL failures skipped)
- [x] DOM kit signatures (v1.9.0: `wtd kit` emits a per-family descriptor —
  harvested fields, action host, resources, skeleton — the web analog of
  `wtd yara`; text + `wtd.kit.v1` JSON)
- [x] `wtd web` per-request timeout (v1.10.0) + credential-form flag (v1.11.0:
  per-page harvest detection with off-domain exfil, `--fail-on credential-forms`
  gate — catches the one-off harvesters that never cluster into a kit)

*Still ideas:* semantic source-code extractors, pairwise similarity matrix
export, a `wtd triage` recipe for sample sets.

## 📜 Design notes

The full engineering philosophy — deterministic pipeline, evidence model,
AI responsibilities, non-goals — lives in [intent.md](intent.md).

## 📄 License

[MIT](LICENSE) © copyleftdev
