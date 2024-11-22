const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const linux = std.os.linux;
const posix = std.posix;
const common = @import("common.zig");

/// Process management, such as waiting for process exit.
pub fn Process(comptime xev: type) type {
    return switch (xev.backend) {
        // Supported, uses pidfd
        .io_uring,
        .epoll,
        => ProcessPidFd(xev),

        .kqueue => ProcessKqueue(xev),

        .iocp => ProcessIocp(xev),

        // Unsupported
        .wasi_poll => ProcessWasi(xev),
    };
}

/// Process implementation using pidfd (Linux).
fn ProcessPidFd(comptime xev: type) type {
    return struct {
        const Self = @This();

        /// The error that can come in the wait callback.
        pub const WaitError = xev.Sys.PollError || error{
            InvalidChild,
        };

        /// pidfd file descriptor
        fd: posix.fd_t,

        /// Create a new process watcher for the given pid.
        pub fn init(pid: posix.pid_t) !Self {
            // Note: SOCK_NONBLOCK == PIDFD_NONBLOCK but we should PR that
            // over to Zig.
            const res = linux.pidfd_open(pid, posix.SOCK.NONBLOCK);
            const fd = switch (posix.errno(res)) {
                .SUCCESS => @as(posix.fd_t, @intCast(res)),
                .INVAL => return error.InvalidArgument,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NODEV => return error.SystemResources,
                .NOMEM => return error.SystemResources,
                else => |err| return posix.unexpectedErrno(err),
            };

            return .{
                .fd = fd,
            };
        }

        /// Clean up the process watcher.
        pub fn deinit(self: *Self) void {
            std.posix.close(self.fd);
        }

        /// Wait for the process to exit. This will automatically call
        /// `waitpid` or equivalent and report the exit status.
        pub fn wait(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: WaitError!u32,
            ) xev.CallbackAction,
        ) void {
            const events: u32 = comptime switch (xev.backend) {
                .io_uring => posix.POLL.IN,
                .epoll => linux.EPOLL.IN,
                else => unreachable,
            };

            c.* = .{
                .op = .{
                    .poll = .{
                        .fd = self.fd,
                        .events = events,
                    },
                },

                .userdata = userdata,
                .callback = (struct {
                    fn callback(
                        ud: ?*anyopaque,
                        l_inner: *xev.Loop,
                        c_inner: *xev.Completion,
                        r: xev.Result,
                    ) xev.CallbackAction {
                        const arg: WaitError!u32 = arg: {
                            // If our poll failed, report that error.
                            _ = r.poll catch |err| break :arg err;

                            // We need to wait on the pidfd because it is noted as ready
                            const fd = c_inner.op.poll.fd;
                            var info: linux.siginfo_t = undefined;
                            const res = linux.waitid(.PIDFD, fd, &info, linux.W.EXITED);

                            break :arg switch (posix.errno(res)) {
                                .SUCCESS => @as(u32, @intCast(info.fields.common.second.sigchld.status)),
                                .CHILD => error.InvalidChild,

                                // The fd isn't ready to read, I guess?
                                .AGAIN => return .rearm,
                                else => |err| err: {
                                    std.log.warn("unexpected process wait errno={}", .{err});
                                    break :err error.Unexpected;
                                },
                            };
                        };

                        return @call(.always_inline, cb, .{
                            common.userdataValue(Userdata, ud),
                            l_inner,
                            c_inner,
                            arg,
                        });
                    }
                }).callback,
            };
            loop.add(c);
        }

        /// Common tests
        pub usingnamespace ProcessTests(xev, Self, &.{ "sh", "-c", "exit 0" }, &.{ "sh", "-c", "exit 42" });
    };
}

/// Process implementation using pidfd (Linux).
fn ProcessWasi(comptime xev: type) type {
    return struct {
        const Self = @This();
        /// Create a new process watcher for the given pid.
        pub fn init(pid: posix.pid_t) !Self {
            _ = pid; // autofix
            return .{};
        }

        /// Clean up the process watcher.
        pub fn deinit(self: *Self) void {
            _ = self; // autofix
        }

        pub const WaitError = error{};
        /// Wait for the process to exit. This will automatically call
        /// `waitpid` or equivalent and report the exit status.
        pub fn wait(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: WaitError!u32,
            ) xev.CallbackAction,
        ) void {
            _ = cb; // autofix
            _ = userdata; // autofix
            _ = c; // autofix
            _ = loop; // autofix
            _ = self; // autofix
        }
    };
}

fn ProcessKqueue(comptime xev: type) type {
    return struct {
        const Self = @This();

        /// The error that can come in the wait callback.
        pub const WaitError = xev.Sys.ProcError;

        /// The pid to watch.
        pid: posix.pid_t,

        /// Create a new process watcher for the given pid.
        pub fn init(pid: posix.pid_t) !Self {
            return .{
                .pid = pid,
            };
        }

        /// Does nothing for Kqueue.
        pub fn deinit(self: *Self) void {
            _ = self;
        }

        /// Wait for the process to exit. This will automatically call
        /// `waitpid` or equivalent and report the exit status.
        pub fn wait(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: WaitError!u32,
            ) xev.CallbackAction,
        ) void {
            c.* = .{
                .op = .{
                    .proc = .{
                        .pid = self.pid,
                        .flags = posix.system.NOTE_EXIT | posix.system.NOTE_EXITSTATUS,
                    },
                },

                .userdata = userdata,
                .callback = (struct {
                    fn callback(
                        ud: ?*anyopaque,
                        l_inner: *xev.Loop,
                        c_inner: *xev.Completion,
                        r: xev.Result,
                    ) xev.CallbackAction {
                        return @call(.always_inline, cb, .{
                            common.userdataValue(Userdata, ud),
                            l_inner,
                            c_inner,
                            if (r.proc) |v| v else |err| err,
                        });
                    }
                }).callback,
            };
            loop.add(c);
        }

        /// Common tests
        pub usingnamespace ProcessTests(xev, Self, &.{ "sh", "-c", "exit 0" }, &.{ "sh", "-c", "exit 42" });
    };
}

const windows = @import("../windows.zig");
fn ProcessIocp(comptime xev: type) type {
    return struct {
        const Self = @This();

        pub const WaitError = xev.Sys.JobObjectError;

        job: windows.HANDLE,
        process: windows.HANDLE,

        pub fn init(process: posix.pid_t) !Self {
            const current_process = windows.kernel32.GetCurrentProcess();

            // Duplicate the process handle so we don't rely on the caller keeping it alive
            var dup_process: windows.HANDLE = undefined;
            const dup_result = windows.kernel32.DuplicateHandle(
                current_process,
                process,
                current_process,
                &dup_process,
                0,
                windows.FALSE,
                windows.DUPLICATE_SAME_ACCESS,
            );
            if (dup_result == 0) return windows.unexpectedError(windows.kernel32.GetLastError());

            const job = try windows.exp.CreateJobObject(null, null);
            errdefer _ = windows.kernel32.CloseHandle(job);

            try windows.exp.AssignProcessToJobObject(job, dup_process);

            return .{
                .job = job,
                .process = dup_process,
            };
        }

        pub fn deinit(self: *Self) void {
            _ = windows.kernel32.CloseHandle(self.job);
            _ = windows.kernel32.CloseHandle(self.process);
        }

        pub fn wait(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: WaitError!u32,
            ) xev.CallbackAction,
        ) void {
            c.* = .{
                .op = .{
                    .job_object = .{
                        .job = self.job,
                        .userdata = self.process,
                    },
                },
                .userdata = userdata,
                .callback = (struct {
                    fn callback(
                        ud: ?*anyopaque,
                        l_inner: *xev.Loop,
                        c_inner: *xev.Completion,
                        r: xev.Result,
                    ) xev.CallbackAction {
                        if (r.job_object) |result| {
                            switch (result) {
                                .associated => {
                                    // There was a period of time between when the job object was created
                                    // and when it was associated with the completion port. We may have
                                    // missed a notification, so check if it's still alive.

                                    var exit_code: windows.DWORD = undefined;
                                    const process: windows.HANDLE = @ptrCast(c_inner.op.job_object.userdata);
                                    const has_code = windows.kernel32.GetExitCodeProcess(process, &exit_code) != 0;
                                    if (!has_code) std.log.warn("unable to get exit code for process={}", .{windows.kernel32.GetLastError()});
                                    if (exit_code == windows.exp.STILL_ACTIVE) return .rearm;

                                    return @call(.always_inline, cb, .{
                                        common.userdataValue(Userdata, ud),
                                        l_inner,
                                        c_inner,
                                        exit_code,
                                    });
                                },
                                .message => |message| {
                                    const result_inner = switch (message.type) {
                                        .JOB_OBJECT_MSG_EXIT_PROCESS,
                                        .JOB_OBJECT_MSG_ABNORMAL_EXIT_PROCESS,
                                        => b: {
                                            const process: windows.HANDLE = @ptrCast(c_inner.op.job_object.userdata);
                                            const pid = windows.exp.kernel32.GetProcessId(process);
                                            if (pid == 0) break :b WaitError.Unexpected;
                                            if (message.value != pid) return .rearm;

                                            var exit_code: windows.DWORD = undefined;
                                            const has_code = windows.kernel32.GetExitCodeProcess(process, &exit_code) != 0;
                                            if (!has_code) std.log.warn("unable to get exit code for process={}", .{windows.kernel32.GetLastError()});
                                            break :b if (has_code) exit_code else WaitError.Unexpected;
                                        },
                                        else => return .rearm,
                                    };

                                    return @call(.always_inline, cb, .{ common.userdataValue(Userdata, ud), l_inner, c_inner, result_inner });
                                },
                            }
                        } else |err| {
                            return @call(.always_inline, cb, .{
                                common.userdataValue(Userdata, ud),
                                l_inner,
                                c_inner,
                                err,
                            });
                        }
                    }
                }).callback,
            };
            loop.add(c);
        }

        /// Common tests
        pub usingnamespace ProcessTests(xev, Self, &.{ "cmd.exe", "/C", "exit 0" }, &.{ "cmd.exe", "/C", "exit 42" });
    };
}

fn ProcessTests(
    comptime xev: type,
    comptime Impl: type,
    comptime argv_0: []const []const u8,
    comptime argv_42: []const []const u8,
) type {
    return struct {
        test "process wait" {
            const testing = std.testing;
            const alloc = testing.allocator;

            var child = std.process.Child.init(argv_0, alloc);
            try child.spawn();

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var p = try Impl.init(child.id);
            defer p.deinit();

            // Wait
            var code: ?u32 = null;
            var c_wait: xev.Completion = undefined;
            p.wait(&loop, &c_wait, ?u32, &code, (struct {
                fn callback(
                    ud: ?*?u32,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.WaitError!u32,
                ) xev.CallbackAction {
                    ud.?.* = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            // Wait for wake
            try loop.run(.until_done);
            try testing.expectEqual(@as(u32, 0), code.?);
        }

        test "process wait with non-zero exit code" {
            const testing = std.testing;
            const alloc = testing.allocator;

            var child = std.process.Child.init(argv_42, alloc);
            try child.spawn();

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var p = try Impl.init(child.id);
            defer p.deinit();

            // Wait
            var code: ?u32 = null;
            var c_wait: xev.Completion = undefined;
            p.wait(&loop, &c_wait, ?u32, &code, (struct {
                fn callback(
                    ud: ?*?u32,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.WaitError!u32,
                ) xev.CallbackAction {
                    ud.?.* = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            // Wait for wake
            try loop.run(.until_done);
            try testing.expectEqual(@as(u32, 42), code.?);
        }

        test "process wait on a process that already exited" {
            const testing = std.testing;
            const alloc = testing.allocator;

            var child = std.process.Child.init(argv_0, alloc);
            try child.spawn();

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var p = try Impl.init(child.id);
            defer p.deinit();

            _ = try child.wait();

            // Wait
            var code: ?u32 = null;
            var c_wait: xev.Completion = undefined;
            p.wait(&loop, &c_wait, ?u32, &code, (struct {
                fn callback(
                    ud: ?*?u32,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.WaitError!u32,
                ) xev.CallbackAction {
                    ud.?.* = r catch 0;
                    return .disarm;
                }
            }).callback);

            // Wait for wake
            try loop.run(.until_done);
            try testing.expectEqual(@as(u32, 0), code.?);
        }
    };
}
