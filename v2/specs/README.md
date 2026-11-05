# Pipeline Engine Specifications (`vidsec v2`)

This directory contains formal specifications and architectural documentation for pipeline orchestration, schemas, datasources, and grammar in `vidsec v2`.

---

## Specification Index

| Document | Language | Description |
| :--- | :--- | :--- |
| **[dsl_and_cli_rationale.md](./dsl_and_cli_rationale.md)** | EN | Architectural Rationale: From verbose YAML to clean dataflow, Docker CLI analogies, and Unix / GStreamer pipe model. |
| **[grammar_ebnf.md](./grammar_ebnf.md)** | EN | Formal EBNF Specification (ISO/IEC 14977): Lexical, syntactic grammar, AST structure, stream algebra, and runtime options. |
| **[schemas.md](./schemas.md)** | EN | Unified type system, canonical `components.schemas` catalog, composite primary keys, deferred FKs, and inline schemas. |
| **[datasources.md](./datasources.md)** | EN | Decoupled storage sinks: in-memory (`type: memory`), relational SQLite (`type: sqlite`), file stores, and message queues. |
| **[pipeline_and_tasks.md](./pipeline_and_tasks.md)** | EN | Black Box task model, step syntax, multi-stream operations (`merge`/`zip`/`join`), concurrency budgets, and RAM routers. |

---

## Reference Implementations

- **[configs/pipeline.next.yaml](../../configs/pipeline.next.yaml):** Canonical reference pipeline demonstrating the practical application of these specifications for Vidsec video forensics.
