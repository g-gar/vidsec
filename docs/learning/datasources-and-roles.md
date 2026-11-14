# Datasources y Roles en FlowData

En FlowData, los **datasources** abstraen el almacenamiento y el transporte de datos fuera de la lógica de negocio de cada task. Las tasks reciben entradas tipadas y emiten salidas tipadas, mientras que el archivo `pipeline.yaml` decide **de dónde vienen** y **a dónde van** esos datos.

---

## 1. Los tres roles (`DatasourceRole`)

Definidos en `src/ast/ast.zig` (`DatasourceRole`):

| Rol | Dirección de flujo | Uso habitual |
| --- | --- | --- |
| **`source`** | Solo lectura / entrada al pipeline | Cargar trabajos iniciales, lotes o streams de entrada (p. ej. `yaml_file` con `jobs.yaml`, o archivos de entrada). |
| **`sink`** | Solo escritura / salida final | Guardar artefactos binarios sanitizados, archivos en cuarentena, copias en disco o envíos remotos (p. ej. `file_store`, `ssh_store`). |
| **`duplex`** *(por defecto)* | Lectura y escritura | Canal intermedio entre pasos del DAG (`memory`) o base relacional consultable/auditada (`sqlite`). |

### Por qué separar por roles
- **Menor privilegio:** un `sink` como `quarantine` o `artifacts` nunca se consulta como entrada accidental.
- **Sustituibilidad:** cambiar un `sink` local (`file_store`) por uno remoto (`ssh_store`) no requiere recompilar ni tocar ninguna task Zig.
- **Encadenamiento en DAG:** un datasource `duplex` como `pipeline_memory` permite que el resultado de una task alimente a la siguiente sin tocar disco ni SQLite.

---

## 2. Drivers disponibles (`drivers/`)

### 2.1 `memory` (`drivers/memory/`)
- **Rol habitual:** `duplex`.
- **Propósito:** repositorio en RAM de alta velocidad para pasar structs y slices tipados entre pasos del DAG (coordinación, órdenes como `TruncateOrder` / `ZeroOutOrder`, o regiones IR).
- **Ventaja:** cero serialización en disco; junto con `retain_all: false` en `runtime`, FlowData libera automáticamente los payloads cuando ningún paso posterior los necesita.

### 2.2 `sqlite` (`drivers/sqlite/`)
- **Rol habitual:** `duplex` o `sink`.
- **Propósito:** almacenamiento relacional estructurado y consultable offline, provisionado automáticamente desde `schemas.yaml` (`path`, `schema`).
- **Uso en `vidsec`:** `audit_db` guarda el rastro de auditoría (`file_triage`, `container_metadata`, `audit_findings`, `remediation_outcomes`) para inspección posterior.

### 2.3 `file_store` (`drivers/file_store/`)
- **Rol habitual:** `sink`.
- **Propósito:** materializar payloads binarios en un directorio local (`directory`), permitiendo parametrizar subdirectorios y nombres desde el step (`remote_dir`, `filename`).
- **Uso en `vidsec` / `mangadex`:** guardar artefactos sanitizados (`artifacts/`), ficheros rechazados (`quarantine/`) o copias locales de `.cbz` (`cbz_staging`).

### 2.4 `ssh_store` (`drivers/ssh_store/`)
- **Rol habitual:** `sink`.
- **Propósito:** subir artefactos binarios por SSH/SCP a un servidor remoto (`host`, `port`, `user`, `identity_file`, `directory`).
- **Uso en `mangadex`:** enviar los `.cbz` y portadas directamente al servidor de Komga sin pasar por almacenamiento local permanente.

### 2.5 `yaml_file` (`drivers/yaml/`)
- **Rol habitual:** `source`.
- **Propósito:** leer una lista declarativa de trabajos o configuraciones iniciales desde un archivo YAML (`path`).
- **Uso en `mangadex`:** `tracked_targets` lee `configs/jobs.yaml` para iniciar la sincronización por lotes.

---

## 3. Regla de oro al diseñar tasks y pipelines

- **La task** solo conoce sus `Inputs`, sus `Outputs` y (si lee streams binarios) `BoundedStreamReader`. Nunca decide si su salida va a RAM, a SQLite, a un directorio local de cuarentena o a un servidor SSH.
- **El diseñador del `pipeline.yaml`** conecta cada canal de salida al datasource y rol adecuados según el entorno (desarrollo local en RAM/disco vs producción distribuida).

