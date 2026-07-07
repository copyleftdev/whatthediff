# WhatTheDiff (WTD)

## AI Agent Bootstrap Document

**Language:** Zig
**Project Type:** AI-First CLI
**Status:** Greenfield Implementation

---

# Mission

You are building **WhatTheDiff (WTD)**.

WTD is **not** another diff utility.

Traditional diff tools answer:

> "What changed?"

WTD answers:

> "What actually matters?"

The objective is to compare an arbitrary number of artifacts, discover meaningful differences, identify consensus and outliers, and present deterministic evidence that an AI can explain.

The AI is never the source of truth.

The deterministic engine is.

---

# Repository Reference

Before making architectural decisions, study the design philosophy used in the Coelacanth project:

[https://github.com/copyleftdev/coelacanth](https://github.com/copyleftdev/coelacanth)

Do **not** copy the implementation.

Instead, learn the architectural patterns:

* Contract-first design
* Small composable modules
* Strong boundaries
* Deterministic execution
* Streaming-first thinking
* Explicit ownership
* Minimal abstraction
* High observability
* Testability before convenience

These architectural values should carry into WTD.

---

# Product Vision

Given **N** artifacts:

* source code
* contracts
* PDFs
* JSON
* YAML
* Markdown
* XML
* configuration
* logs
* APIs
* documentation

WTD should determine:

* consensus
* drift
* unique behavior
* semantic differences
* structural changes
* confidence
* supporting evidence

The output should tell a human the story hidden inside the corpus.

---

# Core Philosophy

Never optimize for syntax.

Always optimize for meaning.

Never optimize for producing smaller patches.

Always optimize for producing better understanding.

---

# Deterministic Pipeline

Every execution should conceptually follow this pipeline:

Artifacts

↓

Normalization

↓

Primitive Extraction

↓

Canonical Representation

↓

Hashing

↓

Evidence Graph

↓

Consensus Analysis

↓

Difference Analysis

↓

AI Explanation

Every stage should have well-defined inputs and outputs.

---

# AI Responsibilities

The LLM is **not** responsible for discovering differences.

The LLM is responsible for:

* explanation
* summarization
* prioritization
* user interaction

The deterministic engine is responsible for:

* comparison
* evidence
* confidence
* statistics
* clustering
* consensus

Every AI conclusion must be traceable back to evidence.

---

# Engineering Constitution

Prefer:

* streaming algorithms
* immutable data where practical
* deterministic execution
* SIMD-friendly processing
* memory locality
* predictable performance
* composable modules
* explicit interfaces
* property testing
* reproducible behavior

Avoid:

* hidden state
* unnecessary inheritance
* global mutable data
* magic behavior
* architecture driven by frameworks

---

# Performance Philosophy

Assume datasets eventually become enormous.

The architecture should naturally scale from:

2 files

↓

20 files

↓

2,000 files

↓

2 million files

No architectural redesign should be required simply because the dataset grows.

---

# Primitive-Based Comparison

Do not compare files directly.

Convert artifacts into stable primitives.

Each primitive should become a deterministic identity that can participate in:

* intersection
* union
* frequency
* consensus
* uniqueness
* clustering
* drift analysis

The comparison engine operates on primitives—not raw text.

---

# Evidence Model

Every observation should answer:

What changed?

Where?

How many artifacts contain it?

How confident are we?

Can the user inspect the proof?

Nothing should be accepted without evidence.

---

# AI Experience

The CLI should feel conversational while remaining deterministic.

Examples:

```bash
wtd contracts/
```

```bash
wtd configs/ --drift
```

```bash
wtd repo/ --consensus
```

```bash
wtd ask "Why is contract_17 different?"
```

The user should never need to think about algorithms.

Only intent.

---

# Architecture Goals

Design independent modules with clear contracts.

Possible modules include:

* CLI
* Artifact Discovery
* Extractors
* Canonicalization
* Primitive Engine
* Hash Engine
* Evidence Store
* Consensus Engine
* Difference Engine
* AI Adapter
* Output Renderer

Each module should be independently testable and replaceable.

---

# Non-Goals

This project is not:

* another Git replacement
* another line diff viewer
* another AST visualizer
* another embedding search engine

Those may become integrations, but they are not the product.

---

# Success Criteria

A user should be able to point WTD at an unknown corpus and quickly understand:

* What is common?
* What is unique?
* What drifted?
* What is suspicious?
* What changed semantically?
* What should I review first?
* What evidence supports those conclusions?

If WTD can answer those questions deterministically and explain them clearly, it has achieved its mission.

---

# Final Principle

Every engineering decision should move the product toward one outcome:

**Transform overwhelming collections of files into clear, evidence-backed understanding.**

This style gives a new coding agent the context, architectural philosophy, and success criteria up front without over-constraining implementation. It leaves room for the agent to make good Zig-specific design decisions while staying aligned with your engineering principles.
