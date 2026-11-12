# MangaDex Catalog Ingestion & Synchronization Engine

> High-throughput, declarative, and memory-safe manga ingestion and packaging pipeline built on **Flowdata v2**.

---

## 1. Overview

`apps/mangadex` synchronizes and archives manga series from the MangaDex public API into ComicRack-compliant `.cbz` archives containing Anansi `ComicInfo.xml` (v2.1) metadata.

The application is orchestrated entirely via a declarative specification ([`configs/pipeline.yaml`](file:///home/ubuntu/.gemini/antigravity/scratch/vidsec/apps/mangadex/configs/pipeline.yaml)) executing on the native Flowdata v2 runtime. It features:

- **Least-Privilege Network Isolation**: Tasks default to `"isolated"`. Only external I/O tasks (`fetch_details`, `fetch_chapters`, `fetch_pages`, `download_pages`) bind explicitly to the `mangadex_api` egress adapter with token-bucket rate limiting (30 req/s, 60 burst).
- **Zero-Copy Memory Management (ARCH-017)**: Intermediate image buffers and metadata structures run inside refcounted per-step arenas that are reclaimed immediately when consumer tasks complete.
- **Bounded Backpressure**: Concurrent DAG execution bounded by `max_inflight_bytes: 512MiB`.
- **Dynamic Semantic Entrypoint**: The pipeline declares `manga_sync` rather than requiring a hardcoded `"main"`.
- **Unary Predicate Filtering**: Inbound job targets are checked with `where: "enabled == true"` to filter disabled series at zero cost.

---

## 2. DAG Topology & Dataflow

The synchronization pipeline executes a directed acyclic graph (DAG) with **Fork / Fan-Out** and **Join / Fan-In** concurrency patterns:

```mermaid
flowchart TD
    subgraph Inbound["Job Ingress / Datasource"]
        Jobs["JobEnvelope (Collector / Dispatcher / jobs.yaml)"]
    end

    subgraph Pipeline["Pipeline: manga_sync (workers: 4, backpressure: 512MiB)"]
        FetchDetails["1. fetch_details<br/>[network: mangadex_api]<br/><i>where: enabled == true</i>"]
        
        %% Fork 1: series_details (refcount = 2)
        FetchChapters["2. fetch_chapters<br/>[network: mangadex_api]"]
        FetchPages["3. fetch_pages<br/>[network: mangadex_api]"]
        DownloadPages["4. download_pages<br/>[concurrency: 4, network: mangadex_api]"]
        DetectFormats["5. detect_formats<br/>[concurrency: 4, CPU isolated]"]
        
        %% Fork 2: pages_with_types (refcount = 2)
        AnalyzePages["6. analyze_pages<br/>[concurrency: 4, QA spread analysis, CPU isolated]"]
        GenComicInfo["7. generate_comicinfo<br/>[Anansi ComicInfo.xml v2.1, CPU isolated]"]
        
        %% Join: build_cbz merges pages_with_types + comic_info_xml
        BuildCBZ["8. build_cbz<br/>[Archive Engine, Join / Fan-in, CPU isolated]"]
        CBZArchive["CBZ Package<br/>(retain: true -> komga_library)"]
    end

    Jobs --> FetchDetails
    
    %% Branch A: Chapter Retrieval & Page Processing
    FetchDetails -->|series_details| FetchChapters
    FetchChapters -->|discovered_chapters| FetchPages
    FetchPages -->|discovered_pages| DownloadPages
    DownloadPages -->|downloaded_pages| DetectFormats
    
    %% Branch B: Metadata Serialization
    FetchDetails -->|series_details (Fork / Fan-out)| GenComicInfo

    %% Fork on pages_with_types
    DetectFormats -->|pages_with_types (Fork)| AnalyzePages
    DetectFormats -->|pages_with_types (Join input)| BuildCBZ
    
    GenComicInfo -->|comic_info_xml (Join input)| BuildCBZ
    BuildCBZ --> CBZArchive
```

### Memory Lifecycle & Refcounting
1. **`series_details`** has an initial refcount of 2. It feeds `fetch_chapters` and `generate_comicinfo`. As soon as both consume it, its arena memory is immediately released.
2. **`pages_with_types`** has an initial refcount of 2. It feeds image analysis (`analyze_pages`) and archive packaging (`build_cbz`).
3. **`cbz_archive`** is the only step output flagged with `retain: true`, which delivers the compiled archive into `komga_library` (`./output/cbz/`) while all intermediate step arenas are freed.

---

## 3. Execution Modes

### Mode 1: Interactive Job Dispatcher (`send_mangadex_job.sh`)
When the Flowdata daemon is running in the background, send jobs directly using the lightweight CLI dispatcher without spinning up file watchers:

```bash
# Dispatch default series (Low Orbit Human, Chapter 1)
./send_mangadex_job.sh

# Dispatch a specific manga by UUID with chapter range
./send_mangadex_job.sh \
  --series-id "162146eb-672a-4a05-b3b2-0c6303f9614e" \
  --title "Takopi's Original Sin" \
  --chapters "1..3" \
  --lang "en"
```

### Mode 2: Standalone Daemon / Server (`--serve`)
Runs Flowdata as a persistent daemon listening for `JobEnvelope` payloads on `http://127.0.0.1:8080/v1/jobs`:

```bash
./run_pipeline.sh --serve
```

### Mode 3: Offline Batch CLI (`run_pipeline.sh`)
Executes the pipeline directly against static targets configured in [`configs/jobs.yaml`](file:///home/ubuntu/.gemini/antigravity/scratch/vidsec/apps/mangadex/configs/jobs.yaml):

```bash
# Build (if needed), validate, and run offline batch
./run_pipeline.sh

# Target a custom pipeline file
./run_pipeline.sh -p configs/custom_pipeline.yaml
```

### Mode 4: Autonomous Collector (`flowdata-collector-filewatcher`)
Watches `configs/jobs.yaml` for modifications using inotify and streams `JobEnvelope` records asynchronously into the Flowdata engine:

```bash
flowdata-collector-filewatcher \
  --watch configs/jobs.yaml \
  --topic manga_subscription \
  --endpoint http://127.0.0.1:8080/v1/jobs
```

### Mode 5: Pre-Flight DAG & Syntax Validation (`--validate`)
Validates YAML schemas, plugin symbol linkage, DAG cycles, and permissions without executing tasks:

```bash
./run_pipeline.sh --validate
```

---

## 4. Configuration & Security Reference

### Configuration Files
- [`configs/pipeline.yaml`](file:///home/ubuntu/.gemini/antigravity/scratch/vidsec/apps/mangadex/configs/pipeline.yaml): Pipeline topology, datasources, egress network, and task definitions.
- [`configs/jobs.yaml`](file:///home/ubuntu/.gemini/antigravity/scratch/vidsec/apps/mangadex/configs/jobs.yaml): Subscription targets, chapter selectors, and scheduling flags.
- [`configs/schemas.yaml`](file:///home/ubuntu/.gemini/antigravity/scratch/vidsec/apps/mangadex/configs/schemas.yaml): SQLite table schemas for series, chapters, and pages.

### Environment Variables (`.env`)
| Variable | Description | Default |
| :--- | :--- | :--- |
| `MANGADEX_ACCESS_TOKEN` | Optional OAuth2 token for MangaDex API | `""` |
| `MANGADEX_USER_AGENT` | Custom User-Agent header for requests | `VidsecMangaDex/3.0.0` |
| `MANGADEX_DB_PATH` | Path to the SQLite catalog cache database | `./output/mangadex.db` |
| `KOMGA_LIBRARY_DIR` | Output destination for generated `.cbz` files | `./output/cbz/` |

---

## 5. Development & Testing

Run all unit and integration tests across the MangaDex app suite:

```bash
cd apps/mangadex
zig build test --summary all
```

Build the native shared plugin library (`libmanga_catalog.so`) and CLI:

```bash
cd apps/mangadex
zig build
```
