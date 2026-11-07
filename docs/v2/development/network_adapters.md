# Declarative Virtual Network Adapters — Development Roadmap (`v2/development/network_adapters.md`)

> [!IMPORTANT]
> **Formal Specification Promoted to `v2/specs/`:**
> * **Modular `networks:` Specification:** [`docs/v2/specs/networks.md`](../specs/networks.md)
> * **Unified Master `pipeline.yaml` Reference:** [`docs/v2/yaml_reference.md`](../yaml_reference.md)

---

## Implementation Roadmap in Zig (`src/`)

* **Phase 1 (Grammar & AST):** Extend [`v2/specs/grammar_ebnf.md`](../specs/grammar_ebnf.md), [`src/ast/ast.zig`](../../../src/ast/ast.zig), and [`src/yaml/ast_loader.zig`](../../../src/yaml/ast_loader.zig) to parse top-level `networks:` definitions (`driver: none | ingress_only | egress | sinkhole`, L7 `policy`, `pool`, `timeouts`, `backpressure`, `rate_limit`, `proxies` + `circuit_breaker`, `dns`, `tls`, `redirects`, `routes`, `capture`) and step-level `network:` / `networks:` multi-homed bindings.
* **Phase 2 (Task-Scoped Reactive Adapter Runtime & C-ABI):** Extend [`HostApiVTable_ABI`](../../../src/abi/types/host_api_vtable_abi.zig) with `net_fetch` and bind the step's resolved `NetworkAdapter` to `TaskContext_ABI` (enforcing L7 Host+Verb+Path ACLs, Anti-SSRF IP checks, Token Bucket rate-limiting, Multi-Strategy Proxy Selection with Circuit Breaker, and bounded buffer allocation).
* **Phase 3 (PCAPNG Packet Writer, Embedded TLS `DSB` & `Network-as-a-Stream`):** Implement the native zero-dependency Zig `.pcapng` writer (`SHB`, `IDB` per virtual adapter, `EPB` with `step_id` comments, and `DSB` TLS key log blocks for instant Wireshark decryption) alongside `network.captured_events` and `network.metrics` channel dispatch.
* **Phase 4 (Optional OS-Level Hardening):** Integrate Linux unprivileged Network Namespaces (`CLONE_NEWNET`) and Landlock ABI v4+ TCP rules for `isolation: strict` steps and external subprocess tasks.
