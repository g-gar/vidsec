# Pipeline Engine Specifications (`vidsec v2`)

This directory contains the modular formal specifications for each building block of `flowdata` / `vidsec v2`.

For the unified master document that aggregates all sections (`runtime:`, `networks:`, `datasources:`, `modules:`, `pipelines:`, and `components.schemas:`) into a complete `pipeline.yaml` reference, see:
👉 **[Unified Declarative Reference (`v2/yaml_reference.md`)](../yaml_reference.md)**

---

## Modular Specification Index

| Document | Scope (`pipeline.yaml` Section) | Description |
| :--- | :--- | :--- |
| **[runtime.md](./runtime.md)** | `runtime:` & `modules:` | Environment interpolation (`.env`), worker thread budgets, default network isolation, memory quotas, and C-ABI `.so` module catalog. |
| **[networks.md](./networks.md)** | `networks:` & `step.network` | Reactive L4/L7 Virtual Network Adapters (`none`, `ingress_only`, `egress`, `sinkhole`), L7 ACLs, Anti-SSRF, connection pooling, TCP window backpressure, Token Bucket rate-limiting, multi-proxy routing (`round_robin`, `weighted`, `failover`, `least_latency`, `sticky_host`, `random`), async DoH/DNS, and Wireshark `PCAPNG` capture with embedded TLS `DSB` keys. |
| **[datasources.md](./datasources.md)** | `datasources:` | Decoupled storage sinks: zero-copy in-memory (`type: memory`), relational SQLite (`type: sqlite`), file stores (`type: file_store`), and message brokers (`type: amqp`). |
| **[schemas.md](./schemas.md)** | `components.schemas:` & `step.schema` | Unified type system, canonical relational/in-memory schemas, composite primary keys, deferred FKs, seed rows, and inline step schemas. |
| **[pipeline_and_tasks.md](./pipeline_and_tasks.md)** | `pipelines:`, `steps:` & `router:` | Black Box task model, cardinality matrix & automatic lifting, multi-stream algebra (`merge`/`zip`/`join`), concurrency overrides, and $O(1)$ routers. |
| **[grammar_ebnf.md](./grammar_ebnf.md)** | Formal Grammar (EBNF) | ISO/IEC 14977 EBNF lexical & syntactic grammar mapping both Compact DSL and YAML into the canonical `PipelineAST`. |
| **[dsl_and_cli_rationale.md](./dsl_and_cli_rationale.md)** | Rationale & CLI | Architectural rationale: Docker Compose / Unix / GStreamer analogies and 1:1 CLI equivalence. |

---

## Reference Implementations

- **[configs/pipeline.yaml](../../../apps/vidsec/configs/pipeline.yaml):** Canonical reference pipeline demonstrating the practical application of these specifications.
