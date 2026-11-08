const std = @import("std");
const vidsec = @import("vidsec");
const abi = @import("flowdata_abi");

const pipeline = vidsec.pipeline;
const ModuleRegistry = pipeline.ModuleRegistry;
const validateManifest = pipeline.validateManifest;
const verifySafeModulePermissions = pipeline.verifySafeModulePermissions;
const LoaderError = pipeline.LoaderError;

const defineTask = abi.defineTask;
const defineManifest = abi.defineManifest;
const TaskDescriptor_ABI = abi.TaskDescriptor_ABI;
const ModuleManifest_ABI = abi.ModuleManifest_ABI;
const TaskContext = abi.TaskContext;
const TaskStatus_ABI = abi.TaskStatus_ABI;
const FLOWDATA_ABI_VERSION = abi.FLOWDATA_ABI_VERSION;

test "Loader: ModuleRegistry static module registration and task resolution" {
    const SamplePlugin = struct {
        fn noop(_: TaskContext) !TaskStatus_ABI {
            return .ok;
        }

        const tasks = [_]TaskDescriptor_ABI{
            defineTask(.{
                .name = "task_a",
                .description = "Test task A",
                .output_fields = &.{ "field1", "field2" },
                .run = &noop,
            }),
        };

        const manifest = defineManifest("plugin_a", .{ .major = 2, .minor = 0, .patch = 0 }, &tasks);
    };

    var registry = ModuleRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.registerStaticModule("plugin_a", &SamplePlugin.manifest);

    const task_desc = try registry.resolveTask("plugin_a", "task_a");
    try std.testing.expect(task_desc.declaresOutputField("field1"));
    try std.testing.expect(!task_desc.declaresOutputField("unknown_field"));
    try std.testing.expectError(error.UnknownModule, registry.resolveTask("unknown_module", "task_a"));
    try std.testing.expectError(error.UnknownTaskInModule, registry.resolveTask("plugin_a", "unknown_task"));
}

test "Loader: Manifest validation and .so permission security checks" {
    const Dummy = struct {
        fn noop(_: TaskContext) !TaskStatus_ABI {
            return .ok;
        }
        const task_a = defineTask(.{ .name = "task_a", .run = &noop });
        const dup_tasks = [_]TaskDescriptor_ABI{ task_a, task_a };
        const valid_tasks = [_]TaskDescriptor_ABI{task_a};
    };

    const bad_ver_manifest = ModuleManifest_ABI{
        .abi_version = 999,
        .module_name = "test_mod",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &Dummy.valid_tasks,
        .tasks_len = 1,
    };
    try std.testing.expectError(error.AbiVersionMismatch, validateManifest(&bad_ver_manifest));

    const dup_task_manifest = ModuleManifest_ABI{
        .abi_version = FLOWDATA_ABI_VERSION,
        .module_name = "dup_mod",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &Dummy.dup_tasks,
        .tasks_len = 2,
    };
    try std.testing.expectError(error.DuplicateTaskNameInModule, validateManifest(&dup_task_manifest));

    // Test permission check on non-existent file
    try std.testing.expectError(error.ModuleFileNotFound, verifySafeModulePermissions(std.testing.allocator, "/non_existent_file.so"));
}
