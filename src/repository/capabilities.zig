/// Universal driver capability flags.
/// Each driver declares its capabilities at init time; the engine and preflight
/// use this to validate pipeline directives and to decide which Repository
/// operations are available at runtime (e.g. `beginTx`, filter pushdown, etc.).
pub const Capabilities = struct {
    /// Driver supports atomic multi-statement transactions (`beginTx` / `commit` / `rollback`).
    transactions: bool = false,
    /// Driver supports named savepoints within a transaction (`beginSavepoint` / `rollbackSavepoint` / `releaseSavepoint`).
    savepoints: bool = false,
    /// `WriteSpec.mode == .update` only writes the columns present in the payload,
    /// leaving all other columns in the row untouched.
    partial_update: bool = false,
    /// Driver compiles `ReadSpec.where` (Predicate AST) into a native parameterized query.
    /// When false, the in-memory evaluator is applied post-fetch.
    filter_pushdown: bool = false,
    /// Driver compiles `ReadSpec.order_by` into a native ORDER BY clause.
    /// When false, Flowdata sorts the fetched slice in-memory.
    order_pushdown: bool = false,
    /// Driver enforces relational constraints declared in `SchemaCatalog`
    /// (`ref` foreign keys, `unique` indexes, `check` expressions).
    relational_constraints: bool = false,
    /// Driver can apply `SchemaCatalog` DDL (CREATE TABLE, CREATE INDEX, etc.)
    /// via `ensureSchema()`.
    schema_ddl: bool = false,
    /// Driver supports streaming row-by-row reads via `readStream()`.
    /// When false, `readStream()` returns a full in-memory slice wrapped in a `RowIterator`.
    streaming: bool = false,
};

