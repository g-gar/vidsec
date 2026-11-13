# ARCH-032: TypeScript WebApp & Low-Overhead Realtime Transport

**Status**: Proposed  
**Date**: 2026-11-13  
**Related**: [ARCH-001](001-transport-layer-unification.md), [ARCH-004](004-observability-otel-and-dag-visualizer.md), [ARCH-019](019-collectors-architecture-and-inbound-agents.md)

---

## 1. Context & Goal

Build a TypeScript web frontend (e.g. Vite + React/Svelte/Solid) to control the Flowdata daemon, submit jobs, inspect DAG topology, and monitor execution in real time.

The existing `extensions/inbound_http/src/http_transport.zig` already exposes `/v1/health`, `/v1/version`, `/v1/validate`, `/v1/run`, `/v1/jobs`, and `/v1/custom/*`, while `extensions/dag_viz/` already produces DAG topology representations (DOT, Mermaid, HTML).

---

## 2. Transport Strategy (Avoiding Unnecessary Parse Overhead)

| Traffic Type | Recommended Protocol | Rationale |
| :--- | :--- | :--- |
| Control & job submission (`/v1/jobs`, `/v1/run`, `/v1/validate`) | **HTTP + JSON** | Small payloads (few KB); V8 `JSON.parse` and Zig JSON parsing have negligible overhead and are trivial to debug. |
| Live progress, logs & `TelemetryBus` events | **SSE (`GET /v1/events`) or WebSocket** | Avoids repeated HTTP polling and full-state JSON re-parsing; pushes incremental node state transitions as they happen. |
| Binary artifacts (`.cbz`, covers, media chunks) | **Raw HTTP binary (`GET /v1/artifacts/{id}`) or binary WebSocket frames** | Never wrap binary blobs in JSON/Base64; stream raw bytes (`application/octet-stream`, `image/*`, HTTP `Range` requests) directly into browser `ArrayBuffer` / `Blob`. |

*(Note: `extensions/inbound_grpc` is kept for backend-to-backend services; browsers cannot speak raw HTTP/2 gRPC without a proxy like Envoy/gRPC-Web, so HTTP + SSE/WebSocket is preferred for direct browser communication.)*

---

## 3. Implementation Plan

### Phase 1: Browser Compatibility in `inbound_http`
- Update `extensions/inbound_http/src/http_transport.zig`:
  - Add **CORS** support (`OPTIONS` preflight returning `204 No Content` and `Access-Control-Allow-Origin` / `Access-Control-Allow-Methods` / `Access-Control-Allow-Headers` on responses) for local frontend dev servers (e.g. Vite on `:5173`).
  - Optionally serve built static frontend assets (`dist/`) from `/` in production mode for single-binary distribution.

### Phase 2: Realtime Event Stream & Raw Artifact Endpoint
- **Event stream (`GET /v1/events`)**:
  - Implement a **Server-Sent Events (SSE)** endpoint (`Content-Type: text/event-stream`) subscribed to `src/kernel/telemetry.zig` (`TelemetryBus`), streaming step lifecycle events (`started`, `completed`, `failed`, throughput/inflight metrics) as compact JSONL/SSE frames.
  - Upgrade path: if bidirectional high-frequency binary streaming is needed later, add a WebSocket handler emitting binary frames.
- **Artifact download (`GET /v1/artifacts/{id}`)**:
  - Serve generated files/artifacts with proper MIME types and `Content-Length` / `Range` support without JSON serialization.

### Phase 3: TypeScript WebApp (`apps/web/` or standalone)
- Create a typed API client (`src/api/client.ts`) covering `/v1/health`, `/v1/validate`, `/v1/run`, and `/v1/jobs`.
- Subscribe to `GET /v1/events` via native `EventSource` to update job/step state reactively.
- Integrate `extensions/dag_viz/` output (Mermaid or structured topology) to render the pipeline DAG and highlight active/completed/failed nodes in real time.
- Add a binary preview/download panel for artifacts (images, `.cbz`, inspection reports).

---

## 4. Verification Criteria

- Frontend running on Vite dev server communicates with `inbound_http` without CORS errors.
- Submitting a `JobEnvelope` via `POST /v1/jobs` triggers live node state updates in the UI via `GET /v1/events` (SSE) with zero HTTP polling.
- Binary artifacts produced by a pipeline can be previewed or downloaded directly via HTTP without Base64/JSON wrapping.

