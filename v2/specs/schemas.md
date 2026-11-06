# Schemas and Type System Specification (`v2/specs/schemas.md`)

This document defines the unified data type system, the canonical schema specification in `components.schemas`, and inline schema declarations within pipeline steps.

---

## 1. Unified Data Type System

All schemas in `vidsec v2` adhere to a unified type system with strict bijection between declarative YAML, in-memory Zig data structures, and relational storage in SQLite (`STRICT` mode).

### 1.1. Scalar / Primitive Types

| YAML Type | Native Zig Type | SQLite (`STRICT`) | Description |
| :--- | :--- | :--- | :--- |
| `int64` | `i64` | `INTEGER` | 64-bit signed integers (sizes, offsets, counters, severities). |
| `float64` | `f64` | `REAL` | IEEE-754 64-bit floating point (entropy, metrics, ratios). |
| `bool` | `bool` | `INTEGER` (0 or 1) | Logical boolean (`CHECK (col IN (0, 1))`). |
| `text` | `[]const u8` (UTF-8) | `TEXT` | UTF-8 encoded string. |
| `blob` | `[]const u8` (Raw) | `BLOB` | Arbitrary raw byte sequence. |

### 1.2. Collections and Structured Types

| YAML Type | In-Memory (Zig) | SQLite Storage | Description |
| :--- | :--- | :--- | :--- |
| `array<T>` | Contiguous slice `[]const T` | `JSON` (`CHECK(json_valid)`) | Homogeneous ordered list. |
| `set<T>` | `std.AutoHashMap(T, void)` | `JSON` | Collection of unique elements without duplicates. |
| `map<K, V>` | `std.StringHashMap(V)` | `JSON` | Key-value associative mapping. |

---

## 2. Canonical Catalog (`components.schemas`)

The `components.schemas` block establishes the domain entity structural contract. Structured datasources (such as SQLite) use this specification to compile DDL (`CREATE TABLE ... STRICT`) automatically without requiring hand-maintained SQL migration files.

### 2.1. Grammar and Attributes

```yaml
components:
  schemas:
    <schema_name>:
      # Primary Key: mandatory (single column or composite)
      primary_key: <column> | [<column1>, <column2>]

      # Column definitions dictionary
      columns:
        <column_name>:
          type: <scalar_or_collection_type>     # Required
          pk: <bool>                            # Optional (shorthand for single PK)
          nullable: <bool>                      # Optional (defaults to false)
          default: <literal>                    # Optional (native literal default value)
          ref: <schema>.<column>                # Optional (foreign key constraint)
          defer_fk: <bool>                      # Optional (deferred FK validation at commit)

      # Secondary search indexes (optional)
      indexes:
        - columns: [<column1>, ...]
          unique: <bool>                        # Optional (defaults to false)
          build: immediate | deferred           # Optional (deferred: post-bulk ingestion)

      # Declarative initial seed rows (optional, e.g. for lookup / enum tables)
      seeds:
        - { <column_name>: <literal_value>, ... }
```

### 2.2. Validation Rules
1. **Relational Identity:** Every canonical entity must define a `primary_key`. In memory, this facilitates $O(1)$ lookup (`AutoHashMap`); in SQLite, it defines the clustered index / primary key.
2. **Clean Default Literals:** Defaults are declared as native YAML literals without SQL escaping artifacts:
   - Correct: `default: unknown`, `default: ""`, `default: 0`, `default: false`.
   - Prohibited: `default: "'unknown'"`.
3. **Declarative Catalog Seeds (`seeds:`):** Lookup, enum, and reference tables can declare initial static rows directly in YAML without maintaining hardcoded imperative `INSERT` statements in host or plugin code. Every key in each seed entry must strictly match a declared column in `columns`.
4. **Deferred Indexing (`build: deferred`):** Indexes on high-throughput ingestion tables (such as `ir_regions`) are marked `deferred` to avoid B-Tree rebalancing overhead during sequential bulk inserts.
5. **Deferred Foreign Keys (`defer_fk: true`):** Compiles to `DEFERRABLE INITIALLY DEFERRED` in SQLite, enabling streaming ingestion without hierarchical ordering deadlocks.

### 2.3. Canonical Example

```yaml
components:
  schemas:
    ir_regions:
      primary_key: [container_id, region_id]
      columns:
        container_id:             { type: int64 }
        region_id:                { type: int64 }
        parent_region_id:         { type: int64, nullable: true, ref: ir_regions.region_id, defer_fk: true }
        tag_name:                 { type: text }
        role:                     { type: text }
        header_offset:            { type: int64 }
        payload_offset:           { type: int64 }
        effective_end_offset:     { type: int64 }
        is_truncated_or_overflow: { type: bool, default: false }
      indexes:
        - columns: [role]
          build: deferred
        - columns: [tag_name]

    audit_findings:
      primary_key: finding_id
      columns:
        finding_id:         { type: int64, pk: true }
        rule_id:            { type: text }
        severity:           { type: int64 }
        file_offset:        { type: int64 }
        byte_length:        { type: int64, default: 0 }
        end_offset:         { type: int64, default: 0 }
        region_tag:         { type: text, nullable: true }
        measured_value:     { type: float64, nullable: true }
        message:            { type: text, nullable: true }
        is_remediated:      { type: bool, default: false }
        remediation_action: { type: text, default: "UNRESOLVED" }
      indexes:
        - columns: [rule_id]
        - columns: [severity]
```

---

## 3. Inline Schemas (`schema:` in Steps)

Schemas declared directly within a pipeline step serve three purposes:
1. Retaining control and orchestration variables in `pipeline_memory` for router evaluation.
2. Deriving computed metrics or applying ad-hoc field transformations.
3. Discarding unnecessary intermediate data without polluting `components.schemas`.

### 3.1. Compact Syntax vs. Expanded Syntax

#### A) Compact Syntax
Direct 1:1 mapping when field names and types match the struct returned by the native task:
```yaml
schema:
  track_count: int64
  video_codec: text
  is_valid: bool
```

#### B) Expanded Syntax (Enriched Fields)
Allows renaming, deriving computed expressions, assigning fallbacks, and attaching validation assertions:
```yaml
schema:
  <destination_field>:
    type: <type>                     # Required
    from: <source_field_or_expr>     # Optional (if different from destination name)
    default: <value>                 # Optional (fallback value if null)
    rule: <validation_expression>    # Optional (runtime assertion)
```

### 3.2. Inline Field Capabilities

1. **Renaming and Source Mapping:**
   ```yaml
   critical_count:
     type: int64
     from: total_high_severity_alerts
   ```

2. **Logical Expressions for Routers:**
   The pipeline computes boolean routing flags without bloating Zig task logic:
   ```yaml
   should_quarantine:
     type: bool
     from: "verdict == 'DROP' or critical_count > 0 or exceeds_size_limit == true"
   ```

3. **Unit Transformation and Arithmetic:**
   ```yaml
   file_size_mb:
     type: float64
     from: "file_size_bytes / (1024.0 * 1024.0)"
   ```

4. **Runtime Assertions / Validation Rules:**
   ```yaml
   verdict:
     type: text
     from: raw_status
     rule: "verdict IN ('PASS', 'WARN', 'DROP')"
   ```

---

## 4. External Modularization (`$ref`)

To avoid monolithic configuration files, `components.schemas` supports external schema modularization:

```yaml
components:
  schemas:
    # Option A: Import an entire schema catalog from an external file
    $ref: "./configs/schemas.yaml"

    # Option B: Import a specific entity schema
    audit_findings:
      $ref: "./schemas/audit_findings.yaml"
```
