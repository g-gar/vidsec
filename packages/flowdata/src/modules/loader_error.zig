pub const LoaderError = error{
    ModuleFileNotFound,
    NotARegularFile,
    InsecureModulePermissions,
    DynamicLibraryOpenFailed,
    MissingManifestSymbol,
    AbiVersionMismatch,
    EmptyModuleTaskList,
    DuplicateTaskNameInModule,
    DuplicateModuleRegistration,
    UnknownModule,
    UnknownTaskInModule,
    OutOfMemory,
};
