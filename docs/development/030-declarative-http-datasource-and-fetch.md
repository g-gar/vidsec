# ARCH-030: First-Class `endpoint` Steps & Versioned REST Contracts

**Status**: Proposed  
**Date**: 2026-11-13  
**Related**: [ARCH-025](025-datasource-roles-and-batch-emission-decoupling.md), [ARCH-026](026-builtin-and-serviceless-tasks.md), [ARCH-029](029-outbound-ratelimit-clock-and-pacing.md)

---

## 1. Problem

Flowdata's `network: egress` handles low-level HTTP policy (ACLs, rate limits, auth headers), while `extensions/datasource/` only covers storage (`file_store`, `ssh_store`, `sqlite`, `memory`, `yaml_file`).

As a result, every REST call or asset download requires ~60–140 lines of repetitive Zig code per task/SDK method:
- Manual URL formatting, query percent-encoding, and empty-body `POST`/`PUT`/`PATCH` handling.
- Duplicated `RateLimited` / `429` retry loops (`nanosleep`).
- Duplicated status checks, MIME-to-extension detection, and pagination loops (`offset`/`limit`, `page`, `cursor`).
- Recompiling Zig plugins whenever an external API changes paths, query parameters, or versions.

---

## 2. Chosen Direction: `endpoint` + `api.<service>.vN.yaml`

Introduce **`endpoint`** as a first-class pipeline step kind alongside `task` and `router`, backed by **versioned API contract files** and a single generic runtime **`EndpointExecutor`**:

```text
  api.mangadex.v3.yaml / api.komga.v1.yaml   (REST contract: endpoints, pagination, response mode)
                   │
                   ▼
  pipeline.yaml (step: endpoint: ...) ──► EndpointExecutor (single generic runtime engine)
                                                │
                                                ▼
                                          network: egress (ACL, rate limit, auth headers)
```

### 2.1 Versioned API Contract (`api.<service>.vN.yaml`)

Declares the operations, HTTP methods, URL/query/body templates, pagination strategy, and response decoding without writing or recompiling Zig code:

```yaml
api: mangadex
version: v3
network: mangadex_api
base_url: "https://api.mangadex.org"

endpoints:
  get_chapters_feed:
    method: GET
    path: "/manga/{series_id}/feed"
    query:
      translatedLanguage[]: "{language}"
      includes[]: "scanlation_group"
      order[chapter]: "asc"
    pagination:
      type: offset_limit        # offset_limit | page_number | cursor | link_header
      limit_param: limit
      offset_param: offset
      page_size: 100
      items_path: "data"
      total_path: "total"
    response: json

  download_asset:
    method: GET
    url: "{url}"                # absolute URL validated against bound egress ACL
    response: bytes             # emits { data, content_type, ext, status_code, url }
```

### 2.2 Usage in `pipeline.yaml`

```yaml
- id: download_cover
  endpoint: mangadex.v3/download_asset
  when_present: cover_url
  params:
    url: "{cover_url}"
  outputs:
    series_cover:
      datasource: komga_remote
      params:
        remote_dir: "{library}/{series}"
        filename: "cover.{ext}"
    chapter_cover:
      datasource: komga_remote
      params:
        remote_dir: "{library}/{series}"
        filename: "chapter_{chapter_number}.{ext}"
```

### 2.3 Key Properties

- **Zero Recompilation on API Changes**: Updating a path, query parameter, or moving from `v1` to `v2` only edits the `api.*.yaml` contract; `validate` verifies `pipeline.yaml` steps against the contract at startup.
- **Unified Transport Mechanics**: `EndpointExecutor` handles path/query `{field}` interpolation, automatic query percent-encoding, empty-body `POST`/`PUT`/`PATCH`, `RateLimited`/`429` backoff, pagination loops, and `json` (`DynamicRecord`) or `bytes` (`{ data, content_type, ext }`) output.
- **Clean Boundary with `task`**:
  - `endpoint`: all HTTP `GET`/`POST`/`PUT`/`PATCH`/`DELETE` transport, retries, and pagination.
  - `task`: domain-specific logic over the fetched data (e.g. MangaDex `1..10` chapter range filtering, deduplication, `ComicInfo.xml` generation).

---

## 3. Open Design Questions

1. **Context Field Propagation**: When `download_cover` only emits `{ data, content_type, ext }`, how should downstream `komga_remote` resolve `{library}`, `{series}`, and `{chapter_number}`? (Fallback lookup in `pipeline_memory` / `accumulated_payloads` inside `coordinator.writeChannelToRepo`, or declarative `carry_fields` on the step?)
2. **Retry Ownership**: Should `RateLimited` / `429` / `5xx` retries live in `transport/outbound/middleware/` (so both `endpoint` and Zig `task`s share one retry middleware) rather than inside `EndpointExecutor`?
3. **Optional Inputs (`when_present`)**: Define clean skip semantics when a dynamic field like `cover_url` is `null` or empty.
4. **Security (SSRF)**: Dynamic `{url}` interpolation must still pass through the bound `egress` network's `allow_rules` before any socket connection is opened.

---

## 4. Phased Plan & Success Criteria

- **Phase 1 — Shared Transport Primitives**: Move `RateLimited`/`429` retry middleware and query percent-encoding into `src/transport/outbound/`.
- **Phase 2 — API Contract Parser & `EndpointExecutor`**: Load `api.*.yaml` at `validate`/`serve`, implement `endpoint:` step kind in AST/DAG/Coordinator for `GET`/`POST`/`PUT`/`PATCH`/`DELETE` (`json`, `bytes`, `empty`).
- **Phase 3 — Pagination & Adoption**: Add `offset_limit`/`page_number`/`cursor` pagination and migrate `download_cover.zig` + Komga triggers (`scan_library`, `analyze_series`) to `api.*.yaml` contracts.

**Done looks like**:
- `download_cover.zig` is replaced by a declarative `endpoint:` step in `pipeline.yaml`.
- Changing an API path/query parameter in `api.*.yaml` requires zero Zig recompilation.
- All `endpoint` requests remain enforced by `egress` ACLs and rate limiters.
