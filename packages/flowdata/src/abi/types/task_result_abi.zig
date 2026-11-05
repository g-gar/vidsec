const std = @import("std");
const TaskStatus_ABI = @import("task_status_abi.zig").TaskStatus_ABI;
const PayloadHandle_ABI = @import("payload_handle_abi.zig").PayloadHandle_ABI;

/// C-ABI compliant execution result returned by a blackbox task entrypoint.
pub const TaskResult_ABI = extern struct {
    status: TaskStatus_ABI = .ok,
    payload: PayloadHandle_ABI = .{},
    error_msg_ptr: ?[*]const u8 = null,
    error_msg_len: usize = 0,

    pub fn ok(payload: PayloadHandle_ABI) TaskResult_ABI {
        return .{
            .status = .ok,
            .payload = payload,
        };
    }

    pub fn fatal(msg: []const u8) TaskResult_ABI {
        return .{
            .status = .fatal_error,
            .payload = .{},
            .error_msg_ptr = msg.ptr,
            .error_msg_len = msg.len,
        };
    }

    pub fn warning(payload: PayloadHandle_ABI, msg: []const u8) TaskResult_ABI {
        return .{
            .status = .recoverable_warning,
            .payload = payload,
            .error_msg_ptr = msg.ptr,
            .error_msg_len = msg.len,
        };
    }

    pub fn halt(payload: PayloadHandle_ABI) TaskResult_ABI {
        return .{
            .status = .halt_pipeline,
            .payload = payload,
        };
    }

    pub fn errorMessage(self: TaskResult_ABI) ?[]const u8 {
        if (self.error_msg_len == 0 or self.error_msg_ptr == null) return null;
        return self.error_msg_ptr.?[0..self.error_msg_len];
    }
};
