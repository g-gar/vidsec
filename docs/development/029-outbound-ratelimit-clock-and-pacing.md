# 029 — Analysis: `NetworkRateLimited` Due to Frozen Clock and Missing Pacing in `outbound`

## 1. Observed Symptom

In real runs with more than ~60 outbound HTTP requests (for example, `chapters: "1..10"` in `manga_sync` with `rate_limit: { requests_per_second: 30, burst: 60 }`), the pipeline downloads the first ~45 pages and from that point on **all** requests start failing in a cascade with:

```text
[Task ERROR] netRequest failed for GET '...': NetworkRateLimited
...
[Task ERROR] Task 'download_chapter_page' item 13 failed: RateLimited
```

This happens even though the rate limit (`requests_per_second: 30`, `burst: 60`) is purely local/artificial in `pipeline.yaml` and the remote server has not returned HTTP `429`. A single item exhausting its retries aborts the entire `download_pages` step and halts the full pipeline.

---

## 2. Root Causes in the Code

The failure is the product of three combined issues across the `egress` driver, the rate-limit middleware, and error handling in `.elemental` tasks.

### 2.1. Critical Cause: `EgressAdapter.clock_ms` Is Frozen at `1000` ms in Production

In [`src/transport/outbound/drivers/egress_adapter.zig`](../../src/transport/outbound/drivers/egress_adapter.zig):

- Line `55`: `clock_ms: u64 = 1000`
- Line `172`: `.now_ms = self.clock_ms`
- Line `287`: `s.clock_ms += delta_ms` (only invoked via `advanceClock()` in unit tests)

In real execution (`run` or `serve`), nothing calls `advanceClock()`, so `exchange.now_ms` is **`1000` on every request**.

When [`DualTokenBucketStrategy.refill`](../../src/transport/outbound/strategies/ratelimit/token_bucket.zig#L57-L69) evaluates:

```zig
if (now_ms <= self.last_refill_ms) return;
```

because `now_ms == 1000 == last_refill_ms`, **the bucket never refills a single token**. As soon as the initial `burst: 60` is consumed (in the example: 1 `fetch_details` + 5 `fetch_chapters` + 9 `fetch_pages` + 45 `download_pages` = 60 requests), **all subsequent requests receive `NetworkRateLimited` indefinitely**, regardless of how long the task waits between retries.

*(Note: the same `clock_ms: u64 = 1000` pattern also exists in `sinkhole_adapter.zig` and `isolated_adapter.zig`.)*

### 2.2. Middleware Design: `tryAcquire` Fails Hard Instead of Pacing

In [`src/transport/outbound/middleware/ratelimit_middleware.zig`](../../src/transport/outbound/middleware/ratelimit_middleware.zig#L42-L46):

```zig
const decision = self.limiter.tryAcquire(exchange.now_ms, exchange.req_body.len);
if (decision != .allowed) {
    exchange.metrics.requests_rate_limited += 1;
    return if (decision == .pool_exhausted) error.NetworkAcquireTimeout else error.NetworkRateLimited;
}
```

A user-configured rate limit in `pipeline.yaml` (`requests_per_second: 30`) should act as a **flow regulator (pacing / traffic shaping)**, not as a fatal failure:

1. If the local bucket is temporarily empty, the worker should wait a few milliseconds until a token becomes available (up to a configurable maximum timeout), instead of immediately returning `error.NetworkRateLimited`.
2. Returning `error.NetworkRateLimited` from the local middleware causes adapters (`flowdata_http_adapter.zig:62`) to translate it into the same `error.RateLimited` as a real **HTTP `429`** from the remote server, triggering unnecessary retries, contention across the 4 parallel workers (*thundering herd*), and `[Task ERROR]` log noise.

### 2.3. Amplification via `fail_fast` in `.lift = .elemental`

In [`src/plugin/sdk/define_task_service.zig`](../../src/plugin/sdk/define_task_service.zig#L242-L245), the default policy for `.elemental` tasks is `on_item_error: fail_fast`. If one item exhausts the 8 attempts of [`DownloadChapterPageService`](../../apps/mangadex/plugin/tasks/download_chapter_page.zig#L35-L50), the entire `download_pages` step is canceled and progress for the remaining chapters is lost.

---

## 3. Recommended Solution

### Phase 1 — Real Clock by Default in `EgressAdapter` (Essential)
1. Add a clock mode to `EgressAdapter` (defaulting to the OS **real monotonic clock**, e.g. `clock_gettime(CLOCK_MONOTONIC)` converted to `u64` ms; and deterministic/manual mode only when a test calls `advanceClock()` or sets `use_virtual_clock = true`).
2. Initialize `DualTokenBucketStrategy` with the current `now_ms` from the real clock so `refill(now_ms)` continuously replenishes tokens at the `requests_per_second` rate.

### Phase 2 — Client-Side Pacing in `RateLimitMiddleware`
1. Add a `waitMsUntilReady(now_ms, payload_bytes) -> u64` (or `acquireWaitHint`) method to `RateLimitStrategy` / `DualTokenBucketStrategy`.
2. In `RateLimitMiddleware.intercept`, when `tryAcquire` returns `.rate_limited_rps` or `.rate_limited_bandwidth`:
   - If pacing is enabled (the natural behavior for local limits), sleep for the computed interval (with a bounded upper cap, e.g. `acquire_timeout_ms`) and retry acquisition inside the middleware before emitting `error.NetworkRateLimited`.
   - Reserve `error.NetworkRateLimited` for when `acquire_timeout_ms` is exceeded or when the remote server returns HTTP `429` (`cooldown_until_ms` active via `Retry-After`).

### Phase 3 — Task Resilience and Observability
1. Record local pacing waits as a metric / `DEBUG` log, not as `[Task ERROR]`.
2. Evaluate `on_item_error: collect` or `skip` in `download_pages` if partial per-page fault tolerance is desired without failing entire chapters.
