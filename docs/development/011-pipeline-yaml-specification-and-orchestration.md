# 011 — Declarative Pipeline YAML Specification & End-to-End Orchestration

| Metadata | Value |
| :--- | :--- |
| **ID** | `ARCH-011` |
| **Depends On** | [`ARCH-005`](./005-mangadex-client-library.md) through [`ARCH-010`](./010-multisource-architecture-and-scrapers.md), [`ARCH-013`](./013-engine-jobs-spec-app-aliases-and-yaml-modularization.md), [`ARCH-017`](./017-concurrent-dag-scheduler-and-host-concurrency-contract.md), [`ARCH-018`](./018-type-driven-inbound-router-and-service-catalog.md), [`ARCH-019`](./019-collectors-architecture-and-inbound-agents.md) |
| **Area** | `apps/mangadex/configs/pipeline.yaml` & `apps/mangadex/src/config.zig` |
| **Status** | `COMPLETED & MODERNIZED (Integrated with Collectors, Dynamic Entrypoints, Explicit Least-Privilege Network Isolation, and Fork/Join DAG Backpressure)` |

---

## 1. High-Level Vision & Orchestration Lifecycle

The `apps/mangadex` application operates as an autonomous, dataflow-driven content pipeline powered by **Flowdata v2**. Rather than hardcoding sync loops or CLI scripts, the entire synchronization, ingestion, transformation, and distribution process is defined declaratively in `pipeline.yaml`.

Workload items are decoupled from static pipeline configuration: they arrive dynamically via autonomous collectors (`flowdata-collector-filewatcher` or `flowdata-collector-webhook`), lightweight CLI job dispatchers (`send_mangadex_job.sh`), or static batch files as universal `JobEnvelope` records.

### 1.1. End-to-End Orchestration Topology

```mermaid
flowchart TD
    subgraph Ingress["Dynamic Ingress (collectors/ - ARCH-019 & CLI Dispatcher)"]
        JobsFile["jobs.yaml / Webhooks<br/>(Series Targets)"] --> Collector["file_watcher / webhook<br/>(Emits JobEnvelope)"]
        CLIDispatch["send_mangadex_job.sh<br/>(Direct JobEnvelope POST)"] --> DaemonIn["Flowdata HTTP Ingress<br/>(/v1/jobs)"]
        Collector --> DaemonIn
    end

    subgraph Pipeline["Pipeline: manga_sync (workers: 4, max_inflight_bytes: 512MiB)"]
        DaemonIn --> FetchMeta["1. fetch_details<br/>[network: mangadex_api]<br/><i>where: enabled == true</i>"]
        
        %% Fork / Fan-out from fetch_details
        FetchMeta -->|series_details| FetchChap["2. fetch_chapters<br/>[network: mangadex_api]"]
        FetchChap -->|discovered_chapters| FetchPages["3. fetch_pages<br/>[network: mangadex_api]"]
        FetchPages -->|discovered_pages| DownloadPages["4. download_pages<br/>[concurrency: 4, network: mangadex_api]"]
        DownloadPages -->|downloaded_pages| DetectFmt["5. detect_formats<br/>[concurrency: 4, CPU isolated]"]
        
        %% Fork / Fan-out from detect_formats
        DetectFmt -->|pages_with_types (Fork)| AnalyzeImg["6. analyze_pages<br/>[concurrency: 4, QA, CPU isolated]"]
        DetectFmt -->|pages_with_types (Join input)| BuildCBZ["8. build_cbz<br/>[Join / Fan-in, miniz, CPU isolated]"]
        
        %% Fork / Fan-out from fetch_details to ComicInfo
        FetchMeta -->|series_details (Fork)| GenXML["7. generate_comicinfo<br/>[Anansi XML v2.1, CPU isolated]"]
        GenXML -->|comic_info_xml (Join input)| BuildCBZ
        
        BuildCBZ --> CBZOut["Deliver to komga_library<br/>(retain: true, intermediate RAM deallocated)"]
    end
```

---

## 2. Complete Reference `pipeline.yaml`

```yaml
version: 2

# =============================================================================
# MangaDex Catalog Ingestion & Synchronization Pipeline
# Declarative, field-routed analytical pipeline with black-box tasks.
# Memory is a first-class datasource; SQLite is an analytical sink.
# Employs concurrent DAG orchestration, isolated CPU tasks, explicit egress
# network bindings, and zero-copy refcounted memory reclamation (ARCH-017).
# =============================================================================

runtime:
  workers: 4
  scheduler: dag
  max_inflight_bytes: 512MiB
  retain_all: false

datasources:
  # 1. External work items / jobs target datasource (fallback for offline batch CLI runs;
  # in daemon / collector mode, items arrive dynamically via JobEnvelope from collectors)
  tracked_targets:
    driver: yaml_file
    path: "${MANGADEX_JOBS_PATH:-./configs/jobs.yaml}"

  # 2. Fast in-memory repository for zero-copy step chaining and RAM coordination
  pipeline_memory:
    driver: memory

  # 3. Relational sink for long-term catalog caching and offline queries
  catalog_db:
    driver: sqlite
    path: "${MANGADEX_DB_PATH:-./output/mangadex.db}"
    schema: "${MANGADEX_SCHEMA_PATH:-./configs/schemas.yaml}"

  # 4. Storage destination for compiled .cbz comic archives
  komga_library:
    driver: file_store
    directory: "${KOMGA_LIBRARY_DIR:-./output/cbz/}"

networks:
  # Isolated egress virtual network adapter with ACL rules, token-bucket rate limiter,
  # and declarative environment-driven headers (interpolated from .env / host environment).
  # Principle of least privilege: bound ONLY to tasks performing external HTTP calls.
  mangadex_api:
    driver: egress
    headers:
      User-Agent: "${MANGADEX_USER_AGENT:-VidsecMangaDex/3.0.0}"
      Authorization: "${MANGADEX_ACCESS_TOKEN:-}"
    policy:
      block_private_ranges: true
      allow_rules:
        - schemes: [https]
          hosts:
            - "api.mangadex.org"
            - "auth.mangadex.org"
            - "uploads.mangadex.org"
            - "*.mangadex.org"
            - "*.mangadex.network"
          operations: [GET, POST]
    rate_limit:
      requests_per_second: 30
      burst: 60

modules:
  manga_catalog:
    path: "./zig-out/lib/libmanga_catalog.so"

pipelines:
  # ===========================================================================
  # MANGA CATALOG SYNCHRONIZATION PIPELINE
  #
  # DAG TOPOLOGY (Fork / Fan-Out & Join / Fan-In with Refcounted Arenas):
  #
  #                         [tracked_targets]
  #                                |
  #                       (1. fetch_details)
  #                           /        \  (Fork / Asynchronous fan-out)
  #                          /          \
  #               (2. fetch_chapters)    (7. generate_comicinfo) [CPU-only]
  #                        |                       |
  #                (3. fetch_pages)                |
  #                        |                       |
  #             (4. download_pages) [elemental: 4] |
  #                        |                       |
  #              (5. detect_formats) [CPU-only]    |
  #                     /      \                   |
  #                    /        \                  |
  #        (6. analyze_pages)    \                 |
  #        [elemental: 4, CPU]    \                |
  #                                \               /
  #                                 (8. build_cbz) [Join / Fan-in, CPU-only]
  # ===========================================================================
  manga_sync:
    steps:
      # -----------------------------------------------------------------------
      # STEP 1: Fetch Series Metadata from Inbound Job / tracked_targets
      # Unary filter rejects disabled jobs with zero overhead.
      # -----------------------------------------------------------------------
      - id: fetch_details
        uses: manga_catalog/fetch_series_details
        where: "enabled == true"
        networks:
          - mangadex_api
        inputs:
          input: tracked_targets
        outputs:
          series_details:
            datasource: pipeline_memory
          catalog_series:
            datasource: catalog_db

      # -----------------------------------------------------------------------
      # STEP 2: Fetch Chapters List
      # Receives series_id from step 1's series_details
      # -----------------------------------------------------------------------
      - id: fetch_chapters
        uses: manga_catalog/fetch_chapters
        networks:
          - mangadex_api
        inputs:
          input: series_details
        outputs:
          discovered_chapters:
            datasource: catalog_db

      # -----------------------------------------------------------------------
      # STEP 3: Scrape Chapter Pages
      # Elemental expansion over discovered chapters (filtered by tracking job)
      # -----------------------------------------------------------------------
      - id: fetch_pages
        uses: manga_catalog/fetch_chapter_pages
        concurrency: 4
        networks:
          - mangadex_api
        inputs:
          input: discovered_chapters
        outputs:
          discovered_pages:
            datasource: catalog_db

      # -----------------------------------------------------------------------
      # STEP 4: Download Chapter Pages over HTTP
      # Elemental task processing pages concurrently with token-bucket rate limiter
      # -----------------------------------------------------------------------
      - id: download_pages
        uses: manga_catalog/download_chapter_page
        concurrency: 4
        networks:
          - mangadex_api
        inputs:
          input: fetch_pages.discovered_pages
        outputs:
          downloaded_pages:
            datasource: pipeline_memory

      # -----------------------------------------------------------------------
      # STEP 5: Magic Bytes Content-Type Detection
      # Elemental task inspecting raw bytes to identify MIME format.
      # Network: isolated (CPU-only image parsing)
      # -----------------------------------------------------------------------
      - id: detect_formats
        uses: manga_catalog/detect_content_type
        concurrency: 4
        inputs:
          input: download_pages.downloaded_pages
        outputs:
          pages_with_types:
            datasource: pipeline_memory

      # -----------------------------------------------------------------------
      # STEP 6: Simulated Static Image Analysis & Spread Detection
      # Elemental task with broadcast parameters configured declaratively.
      # Network: isolated (CPU-only quality validation)
      # -----------------------------------------------------------------------
      - id: analyze_pages
        uses: manga_catalog/analyze_image
        concurrency: 4
        inputs:
          input: detect_formats.pages_with_types
        params:
          default_width: 1200
          default_height: 1800
          spread_threshold: 1.3
        outputs:
          analyzed_pages:
            datasource: pipeline_memory

      # -----------------------------------------------------------------------
      # STEP 7: Generate ComicInfo.xml Metadata
      # Serializes chapter and series metadata into Anansi ComicInfo XML buffer.
      # Network: isolated (CPU-only XML generation)
      # -----------------------------------------------------------------------
      - id: generate_comicinfo
        uses: manga_catalog/generate_comicinfo
        inputs:
          input: series_details
        params:
          series_title: "${MANGADEX_SERIES_TITLE:-}"
          language: "en"
          manga_type: "YesAndRightToLeft"
        outputs:
          comic_info_xml:
            datasource: pipeline_memory

      # -----------------------------------------------------------------------
      # STEP 8: Bundle into Standard .cbz (ZIP) Archive
      # Packages image pages with STORE compression and ComicInfo.xml.
      # Network: isolated (CPU-only ZIP compression)
      # -----------------------------------------------------------------------
      - id: build_cbz
        uses: manga_catalog/build_cbz_archive
        inputs:
          pages: detect_formats.pages_with_types
          comic_info_xml: generate_comicinfo.comic_info_xml
        params:
          output_dir: "${MANGADEX_CBZ_DIR:-./output/cbz/}/{series}/"
        after:
          - generate_comicinfo
        outputs:
          cbz_archive:
            datasource: pipeline_memory
            retain: true
```

---

## 3. Key Architectural Alignments

1. **Autonomous Collector Ingress & Job Dispatcher (`collectors/`, `send_mangadex_job.sh`)**:
   - Work items can arrive via `flowdata-collector-filewatcher` or webhook receiver.
   - Alternatively, developers can dispatch single jobs using `send_mangadex_job.sh` directly to a running Flowdata engine daemon without launching collector background daemons.
   - `tracked_targets` is preserved purely as an optional batch fallback for offline CLI invocation (`./run_pipeline.sh`).

2. **Unary Predicate Job Filtering (`where: "enabled == true"`)**:
   - Rather than routing through synthetic intermediate router tasks, the entrypoint step `fetch_details` declares `where: "enabled == true"`.
   - Disabled jobs are discarded immediately before initiating network or database calls.

3. **Dynamic Entrypoint Selection**:
   - The engine automatically selects the declared pipeline `manga_sync` via `ast.getEntrypoint()`, eliminating the legacy requirement of naming pipelines literally `"main"`.

4. **Principle of Least Privilege for Virtual Networks**:
   - The runtime defaults to `"isolated"`.
   - Outbound HTTP access is restricted strictly to the 4 I/O steps (`fetch_details`, `fetch_chapters`, `fetch_pages`, `download_pages`) that explicitly declare `networks: [mangadex_api]`.
   - Analytical, formatting, XML generation, and archive compression steps remain strictly CPU-isolated.

5. **Concurrent DAG & Zero-Copy Memory Lifecycle (ARCH-017)**:
   - Configured with `scheduler: dag`, `workers: 4`, and `max_inflight_bytes: 512MiB`.
   - Per-step arenas deallocate intermediate buffers (`downloaded_pages`, `pages_with_types`, `comic_info_xml`) as soon as downstream consumers finish.
   - The final artifact declares `retain: true` on `cbz_archive`.

---

## 4. Verification and Acceptance Criteria

1. **AST Parsing Test**:
   - Validates that `apps/mangadex/configs/pipeline.yaml` parses completely via `flowdata.yaml.ast_loader` into 8 DAG tasks with custom entrypoint `manga_sync` and default isolated runtime network.
2. **Environment Variable Expansion**:
   - Asserts that secrets (`${MANGADEX_ACCESS_TOKEN}`, `${KOMGA_LIBRARY_DIR}`) interpolate properly from process env and `.env` files via `EnvInterpolator`.
3. **Automated Suite**:
   - Fully verified with `cd apps/mangadex && zig build test --summary all` (44/44 tests green).
