# Declarative Virtual Network Adapters (`v2/development/network_adapters.md`)

## 1. Introduction and Architectural Rationale

`flowdata` is designed as a general-purpose, declarative dataflow engine whose authoring ergonomics draw direct inspiration from **Docker Compose**, **Unix pipelines**, and **GStreamer** ([`v2/specs/dsl_and_cli_rationale.md`](../specs/dsl_and_cli_rationale.md)).

While the core specification already provides first-class declarative abstractions for **computation** (`steps` and dynamic `modules`) and **storage** (`datasources`: `memory`, `sqlite`, `file_store`, `amqp`), network access remains an implicit side-effect of the underlying host operating system rather than a property governed by the pipeline graph.

Following the `docker network` and `compose.yml` precedent, this specification introduces **Virtual Network Adapters (`networks:`)** as a first-class primitive in `flowdata`. This enables pipeline authors to declaratively control:
1. **Deterministic Isolation (`driver: none`):** Ensuring pure *Black Box* transformation tasks ($Inputs \rightarrow Outputs$) execute completely offline with zero hidden network dependencies or exfiltration risks.
2. **Controlled Egress (`driver: egress`):** Granting explicit, policy-bounded outbound connectivity (allowlists, timeouts, proxies) only to steps that legitimately interact with external services.
3. **Virtualized Capture, Mocking, and Telemetry (`driver: sinkhole`):** Running tasks against an ephemeral virtual network adapter that intercepts outbound requests, emulates responses for deterministic offline testing, and exposes captured network activity as a **typed data stream (`Network-as-a-Stream`)** inside the pipeline.

---

## 2. Virtual Network Drivers and Topology

```
                        ┌──────────────────────────────────────────────┐
                        │           flowdata Pipeline Engine           │
                        └──────────────────────┬───────────────────────┘
                                               │
            ┌──────────────────────────────────┼──────────────────────────────────┐
            │ network: isolated                │ network: api_egress              │ network: virtual_tap
            ▼                                  ▼                                  ▼
   ┌─────────────────┐                ┌─────────────────┐                ┌─────────────────┐
   │  driver: none   │                │ driver: egress  │                │ driver: sinkhole│
   │                 │                │                 │                │                 │
   │ • Zero sockets  │                │ • Host/Port ACL │                │ • 100% Offline  │
   │ • Pure compute  │                │ • Proxy routing │                │ • Mock / Catch  │
   │ • Air-gapped    │                │ • Timeouts      │                │ • Emits Stream  │
   └─────────────────┘                └────────┬────────┘                └────────┬────────┘
                                               │                                  │
                                               ▼                                  ▼
                                     [ Allowed External ]               [ Pipeline Channel ]
                                     [   API / Broker   ]               (network.captured_events)
```

### 2.1. Air-Gapped Driver (`driver: none`)
* **Behavior:** Rejects all outbound and inbound socket operations.
* **Default Policy:** Serves as the default adapter for pure computational steps when `runtime.default_network: none` is configured.
* **Guarantee:** Enforces strict functional reproducibility—given identical inputs, the step cannot depend on external network state or leak data outside the pipeline.

### 2.2. Controlled Egress Driver (`driver: egress`)
* **Behavior:** Permits outbound connections strictly matching declared hostnames, CIDR blocks, and ports (`allow_hosts`), optionally routing traffic through an explicit HTTP/SOCKS5 proxy.
* **Use Cases:** REST/GraphQL API ingestion connectors, webhook dispatchers, remote object storage hydration, or distributed cluster coordination.

### 2.3. Virtual Sinkhole / Tap Driver (`driver: sinkhole`)
* **Behavior:** Attaches the task to an isolated virtual network environment with no route to the external internet. Every connection attempt (DNS resolution, HTTP request, SMB handshake, raw TCP/UDP packet) is intercepted by the `flowdata` runtime.
* **Capabilities:**
  1. **Service Mocking:** Optionally returns synthetic responses (`emulate_responses: true`) for offline pipeline testing.
  2. **Network-as-a-Stream Telemetry:** Serializes intercepted requests into a built-in output source (`network.captured_events`) that can be routed into `pipeline_memory` (for $O(1)$ `router` branching) or persisted into `sqlite` datasources.
  3. **Security Detonation (e.g., `vidsec`):** Dynamically catches SSRF (`CWE-918`), SMB/NTLM hash exfiltration (`T1187`), or tracking beacons triggered when parsing or transcoding untrusted media containers ([`R05`](../../v1/rules/R05_external_data_reference.md)).

---

## 3. Enforcement Architecture: User-Space Mediation vs. OS Confinement

A key architectural trade-off in `flowdata` is balancing **zero-privilege portability** (running as a normal user binary on macOS, Linux, and CI environments) against **kernel-enforced sandboxing** for untrusted native code.

| Dimension | Tier 1: User-Space Runtime Mediation (Default) | Tier 2: OS-Level Kernel Confinement (Hardened) |
| :--- | :--- | :--- |
| **Mechanism** | Mediated via `flowdata` C-ABI VTable (`HostApiVTable_ABI`) and ephemeral local loopback sockets (`127.0.0.1:0`) managed by the Host process. | Kernel Network Namespaces (`CLONE_NEWUSER \| CLONE_NEWNET`), `bwrap --unshare-net`, user-space stacks (`slirp4netns`/`pasta`), and Landlock ABI v4+ (`LANDLOCK_ACCESS_NET_*`). |
| **Root / Admin Privileges** | **None (`0` privileges required).** Runs entirely within the standard user permissions granted to the `flowdata` binary on spawn. | **Linux:** Rootless via unprivileged user namespaces + Landlock.<br/>**macOS / BSD:** Requires `root` (`sudo`) or signed `NetworkExtension` entitlements to create virtual interfaces (`utun`/`feth`) or `pf` rules. |
| **Execution Model** | **In-Process & Zero-Copy.** Tasks run as native functions on the Host `ThreadPool`, sharing `pipeline_memory` slices directly. | **Subprocess / Thread Boundary.** Requires spawning an isolated child process (`fork`/`exec`) or irreversibly restricting the worker thread. |
| **Security Posture** | **Cooperative Isolation:** Ideal for trusted ETL connectors, native `flowdata` modules, and deterministic testing. A rogue C library invoking raw `connect()` syscalls directly could bypass the VTable. | **Mandatory Kernel Isolation:** Physically blocks raw `socket()`/`connect()` syscalls at the kernel boundary (`EACCES` / `ENETUNREACH`), even against malicious `.so` plugins or external binaries (`ffmpeg`). |

### Recommended Hybrid Strategy
`flowdata` adopts a **progressive two-tier model**:
1. **Tier 1 (User-Space Adapter Engine — Cross-Platform Default):**
   All `networks:` declarations operate out-of-the-box without superuser privileges on both macOS and Linux. Compliant tasks and connectors perform network I/O through the Host runtime's virtual socket API or injected local proxy endpoints.
2. **Tier 2 (OS-Level Enforcement — Opt-In Hardening):**
   When a network profile specifies `isolation: strict` (or when a step spawns an external subprocess on Linux), the engine reinforces the virtual adapter using unprivileged Linux Network Namespaces (`CLONE_NEWNET`) and Landlock TCP rules ([`ADR-005`](../../v1/ADR/ADR-005_unprivileged_self_sandboxing_landlock_and_bwrap.md)).

---

## 4. Declarative Configuration and CLI Controls

### 4.1. `pipeline.yaml` Specification

```yaml
version: 2

runtime:
  workers: auto
  default_network: isolated

# =============================================================================
# VIRTUAL NETWORK ADAPTER CATALOG
# =============================================================================
networks:
  # 1. Default air-gapped adapter for deterministic Black Box tasks
  isolated:
    driver: none

  # 2. Controlled egress adapter for external API ingestion / notifications
  api_egress:
    driver: egress
    allow_hosts:
      - "api.example.com:443"
      - "10.20.0.0/16:5432"
    timeout_ms: 5000

  # 3. Virtual sinkhole/tap adapter for traffic capture and sandboxed execution
  virtual_tap:
    driver: sinkhole
    subnet: "10.254.0.0/24"
    capture_protocols: [dns, http, smb, tcp, udp]
    emulate_responses: false
    isolation: runtime # "runtime" (user-space default) | "strict" (OS namespace/Landlock)

datasources:
  pipeline_memory:
    type: memory
  state_db:
    type: sqlite
    path: "./pipeline_state.db"

# =============================================================================
# PIPELINE DEFINITION
# =============================================================================
pipelines:
  main:
    steps:
      # Step 1: External ingestion with explicit egress policy
      - id: fetch_records
        uses: connectors/http_fetch
        network: api_egress
        params:
          endpoint: "https://api.example.com/v1/items"
        outputs:
          raw_items:
            from: body
            datasource: pipeline_memory

      # Step 2: Pure transformation running with zero network access
      - id: transform_batch
        uses: processors/normalize
        network: isolated
        inputs:
          items: fetch_records.raw_items
        outputs:
          normalized:
            from: result
            datasource: pipeline_memory

      # Step 3: Instrumented or untrusted task attached to the virtual tap adapter
      - id: evaluate_target
        uses: sandbox/inspect_payload
        network: virtual_tap
        inputs:
          payload: transform_batch.normalized
        outputs:
          processed_data:
            from: output
            datasource: state_db
          # Built-in telemetry channel exposed by the virtual network adapter
          net_events:
            from: network.captured_events
            schema: components/schemas/network_event
            datasource: pipeline_memory

      # Router branching on captured network telemetry in O(1) from RAM
      - router: check_unexpected_egress
        cases:
          - when: "count(evaluate_target.net_events) > 0"
            goto: policy_violation_flow
        default: finalize_flow

components:
  schemas:
    network_event:
      primary_key: event_id
      columns:
        event_id:   { type: int64, pk: true }
        step_id:    { type: text }
        timestamp:  { type: int64 }
        protocol:   { type: text }
        dst_host:   { type: text }
        dst_port:   { type: int64 }
        uri_path:   { type: text, nullable: true }
        verdict:    { type: text } # "BLOCKED" | "CAPTURED" | "MOCKED"
```

### 4.2. YAML $\leftrightarrow$ Compact DSL $\leftrightarrow$ CLI Equivalence

Following [`dsl_and_cli_rationale.md`](../specs/dsl_and_cli_rationale.md), network attachment maps cleanly across all three representations:

* **Compact DSL:**
  ```text
  evaluate_target: sandbox/inspect_payload(payload=transform_batch.normalized) @net(virtual_tap) => [network_event] >> pipeline_memory
  ```
* **Direct CLI Invocation:**
  ```bash
  # Run a single task completely offline (air-gapped)
  vidsec run processors/normalize --network none input.bin

  # Run a task attached to a virtual sinkhole and inspect captured network events
  vidsec run sandbox/inspect_payload --network virtual_tap input.bin
  ```

---

## 5. Implementation Roadmap

* **Phase 1 (Grammar & AST):** Extend [`v2/specs/grammar_ebnf.md`](../specs/grammar_ebnf.md) and the YAML AST loader (`packages/flowdata/src/`) to parse top-level `networks:` definitions and step-level `network:` bindings, validating references during pre-flight checks.
* **Phase 2 (User-Space Adapter Runtime & ABI):** Extend the task execution context with virtual network policy hooks (`none`, `egress` allowlist validation, and `sinkhole` event recording) operating in user space with zero elevated privileges.
* **Phase 3 (`Network-as-a-Stream` Channel Dispatch):** Wire the built-in `network.captured_events` source into the output dispatcher so intercepted connection attempts populate `pipeline_memory` slices or `sqlite` tables automatically.
* **Phase 4 (Optional OS-Level Hardening):** Integrate Linux unprivileged Network Namespaces (`CLONE_NEWNET`) and Landlock ABI v4+ TCP rules for `isolation: strict` steps and external subprocess tasks.
