# Architectural Rationale: From Verbose YAML to Natural DSL, CLI Compositions, and Formal Grammar

## 1. The Core Problem: Serialization vs. Domain Calculus

In distributed and analytical dataflow systems, configuration formats frequently suffer from **accidental complexity**. Modern pipelines (Kubernetes manifests, GitHub Actions, CI/CD engines) often default to YAML as their primary authoring interface.

However, **YAML is merely a serialization format, not a dataflow language**. 

When declaring pipelines purely in YAML:
1. **Structural Verbosity & Hyphen Fatigue:** Declaring a simple task invocation requires 15–25 lines of nested mappings (`- id:`, `uses:`, `params:`, `inputs:`, `outputs:`).
2. **Cognitive Overhead:** The actual flow of data (`A -> B -> C`) is obscured by indentation levels and boilerplate keys.
3. **Impedance Mismatch with Developers:** Developers think in terms of functional composition:
   $$\text{Output} = \text{Task}(\text{Inputs})$$
   Representing this basic relationship requires dozens of structural tokens in YAML.

---

## 2. Precedents in Modern Systems Architecture

To design an extensible, developer-friendly pipeline syntax, we draw inspiration from three battle-tested paradigms:

### 2.1. The Docker Compose Precedent (`compose.yml` $\longleftrightarrow$ `docker run`)
Docker Compose does not invent a closed runtime engine. Instead, every stanza in a `compose.yml` file has a direct, isomorphic 1:1 mapping to an independent CLI invocation:
```yaml
services:
  web:
    image: nginx
    ports: ["8080:80"]
```
$$\Updownarrow$$
```bash
docker run -p 8080:80 nginx
```
**Application to VidSec:**
Every task in the pipeline should be runnable as an independent, deterministic CLI command:
```bash
vidsec probe_file --min-size 8 --strict sample.mp4
```
The pipeline file is simply a declarative composition of these atomic CLI primitives.

### 2.2. The Unix Philosophy & Pipe Calculus
The Unix pipeline model (`stdin | stdout`) represents the most durable abstraction in computing:
```bash
cat input.mp4 | probe_file | lower_mp4 | audit_topology
```
By enforcing that tasks are pure *Black Boxes* with typed inputs and outputs, our engine behaves as a strongly-typed, structured Unix pipeline operating over heterogeneous datasources (RAM, SQLite, streams).

### 2.3. The GStreamer Pipeline String Precedent
Media processing engines like GStreamer faced this exact dilemma: XML and JSON configurations were too cumbersome for complex media graphs. GStreamer introduced a compact, human-readable pipeline description syntax:
```text
filesrc location=video.mp4 ! qtdemux ! h264parse ! avdec_h264 ! autovideosink
```
A single expressive line replaced hundreds of lines of XML, without losing any expressive power or schema strictness.

---

## 3. The Unified Solution: AST-First Architecture

Rather than treating YAML as the hardcoded syntax of the engine, the engine operates on a formal **Pipeline Abstract Syntax Tree (AST)**.

This AST can be serialized into three complementary representations:

```
                  ┌──────────────────────────────┐
                  │    Formal Pipeline AST       │
                  │   (Engine In-Memory Model)   │
                  └──────────────┬───────────────┘
                                 │
         ┌───────────────────────┼───────────────────────┐
         ▼                       ▼                       ▼
┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐
│   Expanded YAML  │   │   Compact DSL    │   │  Direct CLI /    │
│  (Config Files)  │   │  (One-Liner DSL) │   │   Unix Pipes     │
└──────────────────┘   └──────────────────┘   └──────────────────┘
```

1. **Expanded YAML:** Optimal for complex, multi-stage pipelines requiring extensive inline schemas, documentation, and database configurations.
2. **Compact Natural DSL:** A streamlined, whitespace-tolerant notation designed for human readability, eliminating hyphens, braces, and repetitive keywords.
3. **Direct CLI Invocations:** Terminal commands for interactive debugging, shell scripting, and ad-hoc analysis.

---

## 4. Side-by-Side Equivalence

### Level 1: Verbose YAML (22 lines)
```yaml
      - id: stage0
        uses: analyzer/probe_file
        params:
          min_file_size_bytes: 8
          strict_extension: true
        outputs:
          triage_record:
            from: result
            schema: components/schemas/file_triage
            datasource: audit_db
          coordination:
            datasource: pipeline_memory
```

### Level 2: Compact DSL (1 line)
```text
stage0: analyzer/probe_file(min_file_size=8, strict=true) => [file_triage] >> audit_db, coord >> pipeline_memory
```

### Level 3: Direct CLI Invocation
```bash
vidsec probe_file --min-file-size 8 --strict input.mp4 --out-db audit.db --out-mem
```

---

## 5. Formalizing via EBNF

To guarantee that the compact DSL and the YAML representation parse into the exact same deterministic AST without ambiguity, the grammar must be specified using **ISO/IEC 14977 Extended Backus-Naur Form (EBNF)**.

The formal specification is documented in [grammar_ebnf.md](./grammar_ebnf.md).
