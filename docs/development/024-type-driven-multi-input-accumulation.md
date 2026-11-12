# ARCH-024: Multi-Input Accumulation (Join) in `TypeDrivenRouter`

> **Status:** `COMPLETED`
> **Prerequisite:** [`ARCH-023`](./023-pluggable-routing-strategy-decoupling.md) (isolated `RoutingStrategy` and `TypeDrivenRouter`)
> **Goal:** Allow [`TypeDrivenRouter`](../../src/engine/routing/type_driven.zig) to synchronize converging parallel branches (multi-input **Join** nodes) without declaring `inputs:` in `pipeline.yaml`, by accumulating outputs from completed steps and checking when all `inputFields()` (or `requiredParams()`) of the target service are satisfied.

---

## 1. Current Problem

Previously, [`TypeDrivenRouter`](../../src/engine/routing/type_driven.zig) evaluated `desc.canHandle(&abi_payload)` against each individual payload in `onPipelineStart` and `onStepComplete`:

* **Works well for 1-to-1 and Fork (1-to-N) flows:** a producer emits a struct/slice and one or more compatible consumers process it.
* **Fails on Join (N-to-1) nodes:** when a service defines an input struct with fields coming from **distinct branches** (for example `BuildCbzArchiveInputs { pages, comic_info_xml }`), no single payload contains both fields at once. `desc.canHandle(single_payload)` returns `false` for both branches, and the Join step never activates.

---

## 2. Proposed Solution

[`TaskDescriptor_ABI`](../../src/plugin/types/task_descriptor_abi.zig) exposes over the C-ABI:
* `inputFields() []const [*:0]const u8` — complete list of required fields in the service's `Inputs` struct, including slice inputs (`[]const T` where `T != u8`).
* `requiredParams() []const [*:0]const u8` — list of required scalar/string parameters for CLI `params:` validation.
* `outputFields() []const [*:0]const u8` — output fields declared by the service.

With this metadata, [`TypeDrivenRouter`](../../src/engine/routing/type_driven.zig) can act as a per-run state accumulator without coupling to `Coordinator` or `ExecutionPlan`:

### 2.1. Accumulated Input Pool (`accumulated_named` & `accumulated_payloads`)
* As each step completes (`onStepComplete`), `TypeDrivenRouter` records in its internal arena-backed structures (`self.arena`):
  1. `step_id -> event.output`
  2. Each channel in `event.channel_outputs` (`ch.name -> ch.payload`)
  3. Declared `outputFields()` from `TaskDescriptor_ABI` mapped to `event.output` (when `event.output` is non-empty), plus raw payloads in `accumulated_payloads` for reflected field lookup (`payload.getReflected(req_param) != null`).

### 2.2. Activation Rule (Direct + Join)
For each unvisited step `node_id` (`!visited_mask[node_id]`):
1. **Direct activation (`canHandle`):** if `desc.canHandle(&abi_payload)` is `true` on the newly arrived payload and `where:` filters pass, it activates immediately with that payload + accumulated `bound_inputs` + ambient context.
2. **Join activation (`inputFields` / `requiredParams`):** if `req_params.len > 1`, `TypeDrivenRouter` checks whether **all** required fields in `req_params` are already available in the accumulated pool:
   * If at least one is missing -> **do not activate** (wait for the other branch to complete).
   * If all are satisfied -> bind each `req_param` in `bound_inputs` (alongside `stream`, `input`, and ambient context), validate `where:` filters, and emit a `TaskActivation` marking `visited_mask[node_id] = true`.

---

## 3. Implementation Phases

### Phase 1: Accumulator & Multi-Input Resolution in `TypeDrivenRouter`
* **Files:**
  * [`src/plugin/types/task_descriptor_abi.zig`](../../src/plugin/types/task_descriptor_abi.zig)
  * [`src/plugin/sdk/input_injector.zig`](../../src/plugin/sdk/input_injector.zig)
  * [`src/plugin/sdk/define_task_service.zig`](../../src/plugin/sdk/define_task_service.zig)
  * [`src/engine/routing/type_driven.zig`](../../src/engine/routing/type_driven.zig)
* **Changes:**
  1. Expose `inputFields()` on `TaskDescriptor_ABI` via `computeRequiredInputFields(Inputs)` so slice inputs (`[]const T`, `T != u8`) are included alongside scalar/string fields.
  2. Add `accumulated_named` and `accumulated_payloads` to `TypeDrivenRouter` and record step outputs on `onPipelineStart` and `onStepComplete`.
  3. Add `activateSatisfiedJoins` to check `inputFields()` (falling back to `requiredParams()`) across accumulated payloads and bind every required input by name into `bound_inputs`.

### Phase 2: Unit & E2E Tests
* **File:** [`tests/core/routing_strategy_test.zig`](../../tests/core/routing_strategy_test.zig)
* **Verification:**
  1. Pure unit test of `TypeDrivenRouter` with a **Fork -> 2 branches -> multi-input Join** topology without `inputs:` in YAML: verify the Join **does not** activate after only the first branch completes, and **does** activate once the second branch completes with both `bound_inputs`.
  2. E2E test with `PipelineEngine.run` in `routing: type_driven` and `scheduler: dag` mode executing the full Join.

---

## 4. Acceptance Criteria
1. **Zero `inputs:` required for Joins:** A step with `Inputs { a: ..., b: ... }` produced by two parallel steps activates automatically once both branches complete.
2. **No false positives:** If only one branch has completed, the Join step remains inactive (`pending`).
3. **Intact isolation:** `TypeDrivenRouter` still does not import `Coordinator`, `WorkerPool`, or `DirectedRouter`.
