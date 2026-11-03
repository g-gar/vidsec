pub const SdkError = error{
    OutOfBounds,
    InvalidArgument,
    NotFound,
    IoError,
    DbConstraintError,
    PermissionDenied,
    OutOfMemory,
    TypeMismatch,
    UnexpectedHostError,
};
