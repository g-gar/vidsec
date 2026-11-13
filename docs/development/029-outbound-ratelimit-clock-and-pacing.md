# 029 — Análisis: `NetworkRateLimited` por reloj congelado y ausencia de *pacing* en `outbound`

## 1. Síntoma observado

En ejecuciones reales con más de ~60 peticiones HTTP salientes (por ejemplo, `chapters: "1..10"` en `manga_sync` con `rate_limit: { requests_per_second: 30, burst: 60 }`), el pipeline descarga las primeras ~45 páginas y a partir de ese punto **todas** las peticiones empiezan a fallar en cascada con:

```text
[Task ERROR] netRequest failed for GET '...': NetworkRateLimited
...
[Task ERROR] Task 'download_chapter_page' item 13 failed: RateLimited
```

Esto ocurre aunque el *rate limit* (`requests_per_second: 30`, `burst: 60`) sea puramente local/artificial en `pipeline.yaml` y el servidor remoto no haya devuelto HTTP `429`. Un único ítem que agote sus reintentos aborta todo el paso `download_pages` y detiene el pipeline completo.

---

## 2. Causas raíz en el código

El fallo es producto de tres problemas combinados entre el driver `egress`, el middleware de *rate limit* y la gestión de errores en tareas `.elemental`.

### 2.1. Causa crítica: `EgressAdapter.clock_ms` está congelado en `1000` ms en producción

En [`src/transport/outbound/drivers/egress_adapter.zig`](../../src/transport/outbound/drivers/egress_adapter.zig):

- Línea `55`: `clock_ms: u64 = 1000`
- Línea `172`: `.now_ms = self.clock_ms`
- Línea `287`: `s.clock_ms += delta_ms` (solo se invoca mediante `advanceClock()` en tests unitarios)

En ejecución real (`run` o `serve`), nadie llama a `advanceClock()`, por lo que `exchange.now_ms` vale **`1000` en todas las peticiones**.

Cuando [`DualTokenBucketStrategy.refill`](../../src/transport/outbound/strategies/ratelimit/token_bucket.zig#L57-L69) evalúa:

```zig
if (now_ms <= self.last_refill_ms) return;
```

como `now_ms == 1000 == last_refill_ms`, **el bucket nunca recarga ni un solo token**. En cuanto se consume el `burst: 60` inicial (en el ejemplo: 1 `fetch_details` + 5 `fetch_chapters` + 9 `fetch_pages` + 45 `download_pages` = 60 peticiones), **todas las peticiones posteriores reciben `NetworkRateLimited` indefinidamente**, sin importar cuánto tiempo espere la tarea entre reintentos.

*(Nota: el mismo patrón `clock_ms: u64 = 1000` existe también en `sinkhole_adapter.zig` e `isolated_adapter.zig`.)*

### 2.2. Diseño del middleware: `tryAcquire` falla en seco en lugar de hacer *pacing*

En [`src/transport/outbound/middleware/ratelimit_middleware.zig`](../../src/transport/outbound/middleware/ratelimit_middleware.zig#L42-L46):

```zig
const decision = self.limiter.tryAcquire(exchange.now_ms, exchange.req_body.len);
if (decision != .allowed) {
    exchange.metrics.requests_rate_limited += 1;
    return if (decision == .pool_exhausted) error.NetworkAcquireTimeout else error.NetworkRateLimited;
}
```

Un *rate limit* configurado por el usuario en `pipeline.yaml` (`requests_per_second: 30`) debería actuar como **regulador de caudal (*pacing* / *traffic shaping*)**, no como un fallo fatal:

1. Si el bucket local está temporalmente vacío, el worker debería esperar unos milisegundos hasta que haya un token disponible (hasta un *timeout* máximo configurable), en vez de devolver `error.NetworkRateLimited` inmediatamente.
2. Devolver `error.NetworkRateLimited` desde el middleware local hace que los adaptadores (`flowdata_http_adapter.zig:62`) lo traduzcan al mismo `error.RateLimited` que un **HTTP `429`** real del servidor remoto, provocando reintentos innecesarios, contienda entre los 4 workers paralelos (*thundering herd*) y ruido de `[Task ERROR]` en los logs.

### 2.3. Amplificación por `fail_fast` en `.lift = .elemental`

En [`src/plugin/sdk/define_task_service.zig`](../../src/plugin/sdk/define_task_service.zig#L242-L245), la política por defecto para tareas `.elemental` es `on_item_error: fail_fast`. Si un ítem agota los 8 intentos de [`DownloadChapterPageService`](../../apps/mangadex/plugin/tasks/download_chapter_page.zig#L35-L50), todo el paso `download_pages` se cancela y se pierde el progreso del resto de capítulos.

---

## 3. Solución recomendada

### Fase 1 — Reloj real por defecto en `EgressAdapter` (imprescindible)
1. Añadir un modo de reloj en `EgressAdapter` (por defecto **reloj monotónico real** del SO, p. ej. `clock_gettime(CLOCK_MONOTONIC)` convertido a `u64` ms; y modo determinista/manual solo cuando un test llame a `advanceClock()` o configure `use_virtual_clock = true`).
2. Inicializar `DualTokenBucketStrategy` con el `now_ms` actual del reloj real para que `refill(now_ms)` recargue tokens de forma continua al ritmo `requests_per_second`.

### Fase 2 — *Client-side pacing* en `RateLimitMiddleware`
1. Añadir un método `waitMsUntilReady(now_ms, payload_bytes) -> u64` (o `acquireWaitHint`) en `RateLimitStrategy` / `DualTokenBucketStrategy`.
2. En `RateLimitMiddleware.intercept`, cuando `tryAcquire` devuelva `.rate_limited_rps` o `.rate_limited_bandwidth`:
   - Si está habilitado el *pacing* (comportamiento natural para límites locales), dormir el intervalo calculado (con tope máximo acotado, p. ej. `acquire_timeout_ms`) y reintentar la adquisición dentro del propio middleware antes de emitir `error.NetworkRateLimited`.
   - Reservar `error.NetworkRateLimited` para cuando se exceda el `acquire_timeout_ms` o cuando el servidor remoto devuelva HTTP `429` (`cooldown_until_ms` activo por `Retry-After`).

### Fase 3 — Resiliencia y observabilidad en tareas
1. Registrar los bloqueos locales de *pacing* como métrica / `DEBUG`, no como `[Task ERROR]`.
2. Evaluar `on_item_error: collect` o `skip` en `download_pages` si se desea tolerancia a fallos parciales por página sin tumbar capítulos completos.

