# Datasources and Roles in FlowData

In FlowData, **datasources** abstract data storage and transport out of each task's business logic. Tasks receive typed inputs and emit typed outputs, while `pipeline.yaml` decides **where that data comes from** and **where it goes**.

---

## 1. The Three Roles (`DatasourceRole`)

Defined in `src/ast/ast.zig` (`DatasourceRole`):

| Role | Flow direction | Typical usage |
| --- | --- | --- |
| **`source`** | Read-only / pipeline input | Load initial jobs, batches, or input streams (e.g., `yaml_file` with `jobs.yaml`, or input files). |
| **`sink`** | Write-only / final output | Persist sanitized binary artifacts, quarantined files, disk copies, or remote uploads (e.g., `file_store`, `ssh_store`). |
| **`duplex`** *(default)* | Read and write | Intermediate channel between DAG steps (`memory`) or queryable/auditable relational store (`sqlite`). |

### Why separate by roles
- **Least privilege:** a `sink` such as `quarantine` or `artifacts` is never accidentally queried as an input.
- **Substitutability:** swapping a local `sink` (`file_store`) for a remote one (`ssh_store`) requires no recompilation and no changes to any Zig task.
- **DAG chaining:** a `duplex` datasource such as `pipeline_memory` lets one task's output feed the next without touching disk or SQLite.

---

## 2. Available Drivers (`drivers/`)

### 2.1 `memory` (`drivers/memory/`)
- **Typical role:** `duplex`.
- **Purpose:** high-speed in-RAM repository for passing typed structs and slices between DAG steps (coordination, orders such as `TruncateOrder` / `ZeroOutOrder`, or IR regions).
- **Advantage:** zero disk serialization; together with `retain_all: false` in `runtime`, FlowData automatically frees payloads when no downstream step needs them.

### 2.2 `sqlite` (`drivers/sqlite/`)
- **Typical role:** `duplex` or `sink`.
- **Purpose:** structured relational storage queryable offline, automatically provisioned from `schemas.yaml` (`path`, `schema`).
- **Usage in `vidsec`:** `audit_db` stores the audit trail (`file_triage`, `container_metadata`, `audit_findings`, `remediation_outcomes`) for later inspection.

### 2.3 `file_store` (`drivers/file_store/`)
- **Typical role:** `sink`.
- **Purpose:** materialize binary payloads into a local directory (`directory`), allowing subdirectories and filenames to be parameterized from the step (`remote_dir`, `filename`).
- **Usage in `vidsec` / `mangadex`:** store sanitized artifacts (`artifacts/`), rejected files (`quarantine/`), or local `.cbz` copies (`cbz_staging`).

### 2.4 `ssh_store` (`drivers/ssh_store/`)
- **Typical role:** `sink`.
- **Purpose:** upload binary artifacts over SSH/SCP to a remote server (`host`, `port`, `user`, `identity_file`, `directory`).
- **Usage in `mangadex`:** send `.cbz` files and covers directly to the Komga server without intermediate permanent local storage.

### 2.5 `yaml_file` (`drivers/yaml/`)
- **Typical role:** `source`.
- **Purpose:** read a declarative list of jobs or initial configurations from a YAML file (`path`).
- **Usage in `mangadex`:** `tracked_targets` reads `configs/jobs.yaml` to initiate batch synchronization.

---

## 3. Golden Rule When Designing Tasks and Pipelines

- **The task** only knows its `Inputs`, its `Outputs`, and (if reading binary streams) `BoundedStreamReader`. It never decides whether its output goes to RAM, SQLite, a local quarantine directory, or an SSH server.
- **The `pipeline.yaml` author** wires each output channel to the appropriate datasource and role according to the environment (local RAM/disk development vs. distributed production).
