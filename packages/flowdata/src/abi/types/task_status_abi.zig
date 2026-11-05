/// Return status of a plugin task execution (`TaskDescriptor_ABI.execute`).
pub const TaskStatus_ABI = enum(u32) {
    /// Commits the step `SAVEPOINT` and continues to the next step.
    ok = 0,
    /// Commits the step `SAVEPOINT`, records a warning in the execution trace, and continues.
    recoverable_warning = 1,
    /// Commits the step `SAVEPOINT` (persisting findings/quarantine metadata) and cleanly halts the pipeline.
    halt_pipeline = 2,
    /// Rolls back the step `SAVEPOINT` (`ROLLBACK TO SAVEPOINT`) and aborts pipeline execution.
    fatal_error = 3,
};
