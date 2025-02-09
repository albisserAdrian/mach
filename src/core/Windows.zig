const std = @import("std");
const w = @import("../win32.zig");
const mach = @import("../main.zig");
const Core = @import("../Core.zig");

const gpu = mach.gpu;
const Event = Core.Event;
const KeyEvent = Core.KeyEvent;
const MouseButtonEvent = Core.MouseButtonEvent;
const MouseButton = Core.MouseButton;
const Size = Core.Size;
const DisplayMode = Core.DisplayMode;
const CursorShape = Core.CursorShape;
const VSyncMode = Core.VSyncMode;
const CursorMode = Core.CursorMode;
const Position = Core.Position;
const Key = Core.Key;
const KeyMods = Core.KeyMods;

const EventQueue = std.fifo.LinearFifo(Event, .Dynamic);
const Win32 = @This();

pub const Native = struct {
    window: w.HWND = undefined,
    surrogate: u16 = 0,
    dinput: *w.IDirectInput8W = undefined,
    saved_window_rect: w.RECT = undefined,
    surface_descriptor_from_hwnd: gpu.Surface.DescriptorFromWindowsHWND = undefined,
};

pub const Context = struct {
    core: *Core,
    window_id: mach.ObjectID,
};

pub fn run(comptime on_each_update_fn: anytype, args_tuple: std.meta.ArgsTuple(@TypeOf(on_each_update_fn))) void {
    while (@call(.auto, on_each_update_fn, args_tuple) catch false) {}
}

pub fn tick(core: *Core) !void {
    var windows = core.windows.slice();
    while (windows.next()) |window_id| {
        const native_opt: ?Native = core.windows.get(window_id, .native);

        if (native_opt) |native| {
            _ = native; // autofix
            var msg: w.MSG = undefined;
            while (w.PeekMessageW(&msg, null, 0, 0, w.PM_REMOVE) != 0) {
                _ = w.TranslateMessage(&msg);
                _ = w.DispatchMessageW(&msg);
            }

            // Handle resizing the window when the user changes width or height
            if (core.windows.updated(window_id, .width) or core.windows.updated(window_id, .height)) {}
        } else {
            try initWindow(core, window_id);
        }
    }
}

fn initWindow(
    core: *Core,
    window_id: mach.ObjectID,
) !void {
    var core_window = core.windows.getValue(window_id);

    const hInstance = w.GetModuleHandleW(null);
    const class_name = w.L("mach");
    const class = std.mem.zeroInit(w.WNDCLASSW, .{
        .style = w.CS_OWNDC,
        .lpfnWndProc = wndProc,
        .hInstance = hInstance,
        .hIcon = w.LoadIconW(null, @as([*:0]align(1) const u16, @ptrFromInt(@as(u32, w.IDI_APPLICATION)))),
        .hCursor = w.LoadCursorW(null, @as([*:0]align(1) const u16, @ptrFromInt(@as(u32, w.IDC_ARROW)))),
        .lpszClassName = class_name,
    });
    if (w.RegisterClassW(&class) == 0) return error.Unexpected;

    const title = try std.unicode.utf8ToUtf16LeAllocZ(core.allocator, core_window.title);
    defer core.allocator.free(title);

    var request_window_width: i32 = @bitCast(core_window.width);
    var request_window_height: i32 = @bitCast(core_window.height);

    const window_ex_style: w.WINDOW_EX_STYLE = .{ .APPWINDOW = 1 };
    const window_style: w.WINDOW_STYLE = if (core_window.decorated) w.WS_OVERLAPPEDWINDOW else w.WS_POPUPWINDOW; // w.WINDOW_STYLE{.POPUP = 1};

    var rect: w.RECT = .{ .left = 0, .top = 0, .right = request_window_width, .bottom = request_window_height };

    if (w.TRUE == w.AdjustWindowRectEx(&rect, window_style, w.FALSE, window_ex_style)) {
        request_window_width = rect.right - rect.left;
        request_window_height = rect.bottom - rect.top;
    }

    const native_window = w.CreateWindowExW(
        window_ex_style,
        class_name,
        title,
        window_style,
        w.CW_USEDEFAULT,
        w.CW_USEDEFAULT,
        request_window_width,
        request_window_height,
        null,
        null,
        hInstance,
        null,
    ) orelse return error.Unexpected;

    var native: Native = .{};

    var dinput: ?*w.IDirectInput8W = undefined;
    const ptr: ?*?*anyopaque = @ptrCast(&dinput);
    if (w.DirectInput8Create(hInstance, w.DIRECTINPUT_VERSION, w.IID_IDirectInput8W, ptr, null) != w.DI_OK) {
        return error.Unexpected;
    }
    native.dinput = dinput.?;

    native.surface_descriptor_from_hwnd = .{
        .hinstance = std.os.windows.kernel32.GetModuleHandleW(null).?,
        .hwnd = native_window,
    };

    core_window.surface_descriptor = .{ .next_in_chain = .{
        .from_windows_hwnd = &native.surface_descriptor_from_hwnd,
    } };

    const context = try core.allocator.create(Context);
    context.* = .{ .core = core, .window_id = window_id };

    _ = w.SetWindowLongPtrW(native_window, w.GWLP_USERDATA, @bitCast(@intFromPtr(context)));

    restoreWindowPosition(core, window_id);

    const size = getClientRect(core, window_id);
    core_window.width = size.width;
    core_window.height = size.height;

    _ = w.GetWindowRect(native.window, &native.saved_window_rect);

    core_window.native = native;
    core.windows.setValueRaw(window_id, core_window);
    try core.initWindow(window_id);
    _ = w.ShowWindow(native_window, w.SW_SHOW);
}

// -----------------------------
//  Internal functions
// -----------------------------
fn getClientRect(core: *Core, window_id: mach.ObjectID) Size {
    const window = core.windows.getValue(window_id);

    if (window.native) |native| {
        var rect: w.RECT = undefined;
        _ = w.GetClientRect(native.window, &rect);

        const width: u32 = @intCast(rect.right - rect.left);
        const height: u32 = @intCast(rect.bottom - rect.top);

        return .{ .width = width, .height = height };
    }

    return .{ .width = 0, .height = 0 };
}

fn restoreWindowPosition(core: *Core, window_id: mach.ObjectID) void {
    const window = core.windows.getValue(window_id);
    if (window.native) |native| {
        if (native.saved_window_rect.right - native.saved_window_rect.left == 0) {
            _ = w.ShowWindow(native.window, w.SW_RESTORE);
        } else {
            _ = w.SetWindowPos(native.window, null, native.saved_window_rect.left, native.saved_window_rect.top, native.saved_window_rect.right - native.saved_window_rect.left, native.saved_window_rect.bottom - native.saved_window_rect.top, w.SWP_SHOWWINDOW);
        }
    }
}

fn getKeyboardModifiers() mach.Core.KeyMods {
    return .{
        .shift = w.GetKeyState(@as(i32, @intFromEnum(w.VK_SHIFT))) < 0, //& 0x8000 == 0x8000,
        .control = w.GetKeyState(@as(i32, @intFromEnum(w.VK_CONTROL))) < 0, // & 0x8000 == 0x8000,
        .alt = w.GetKeyState(@as(i32, @intFromEnum(w.VK_MENU))) < 0, // & 0x8000 == 0x8000,
        .super = (w.GetKeyState(@as(i32, @intFromEnum(w.VK_LWIN)))) < 0 // & 0x8000 == 0x8000)
        or (w.GetKeyState(@as(i32, @intFromEnum(w.VK_RWIN)))) < 0, // & 0x8000 == 0x8000),
        .caps_lock = w.GetKeyState(@as(i32, @intFromEnum(w.VK_CAPITAL))) & 1 == 1,
        .num_lock = w.GetKeyState(@as(i32, @intFromEnum(w.VK_NUMLOCK))) & 1 == 1,
    };
}

fn wndProc(wnd: w.HWND, msg: u32, wParam: w.WPARAM, lParam: w.LPARAM) callconv(w.WINAPI) w.LRESULT {
    const context = blk: {
        const userdata: usize = @bitCast(w.GetWindowLongPtrW(wnd, w.GWLP_USERDATA));
        const ptr: ?*Context = @ptrFromInt(userdata);
        break :blk ptr orelse return w.DefWindowProcW(wnd, msg, wParam, lParam);
    };

    const core = context.core;
    const window_id = context.window_id;

    var core_window = core.windows.getValue(window_id);

    switch (msg) {
        w.WM_CLOSE => {
            core.pushEvent(.{ .close = .{ .window_id = window_id } });
            return 0;
        },
        w.WM_SIZE => {
            const width: u32 = @as(u32, @intCast(lParam & 0xFFFF));
            const height: u32 = @as(u32, @intCast((lParam >> 16) & 0xFFFF));

            if (core_window.width != width or core_window.height != height) {
                // Recreate the swap_chain
                core_window.swap_chain.release();
                core_window.swap_chain_descriptor.width = width;
                core_window.swap_chain_descriptor.height = height;
                core_window.swap_chain = core_window.device.createSwapChain(core_window.surface, &core_window.swap_chain_descriptor);

                core_window.width = width;
                core_window.height = height;
                core_window.framebuffer_width = width;
                core_window.framebuffer_height = height;

                core.pushEvent(.{ .window_resize = .{ .window_id = window_id, .size = .{ .width = width, .height = height } } });

                core.windows.setValueRaw(window_id, core_window);
            }

            // TODO (win32): only send resize event when sizing is done.
            //               the main mach loops does not run while resizing.
            //               Which means if events are pushed here they will
            //               queue up until resize is done.

            return 0;
        },
        w.WM_KEYDOWN, w.WM_KEYUP, w.WM_SYSKEYDOWN, w.WM_SYSKEYUP => {
            const vkey: w.VIRTUAL_KEY = @enumFromInt(wParam);
            if (vkey == w.VK_PROCESSKEY) return 0;

            if (msg == w.WM_SYSKEYDOWN and vkey == w.VK_F4) {
                core.pushEvent(.{ .close = .{ .window_id = window_id } });

                return 0;
            }

            const flags = lParam >> 16;
            const scancode: u9 = @intCast(flags & 0x1FF);

            if (scancode == 0x1D) {
                // right alt sends left control first
                var next: w.MSG = undefined;
                const time = w.GetMessageTime();
                if (core_window.native) |native| {
                    if (w.PeekMessageW(&next, native.window, 0, 0, w.PM_NOREMOVE) != 0 and
                        next.time == time and
                        (next.message == msg or (msg == w.WM_SYSKEYDOWN and next.message == w.WM_KEYUP)) and
                        ((next.lParam >> 16) & 0x1FF) == 0x138)
                    {
                        return 0;
                    }
                }
            }

            const mods = getKeyboardModifiers();
            const key = keyFromScancode(scancode);
            if (msg == w.WM_KEYDOWN or msg == w.WM_SYSKEYDOWN) {
                if (flags & w.KF_REPEAT == 0)
                    core.pushEvent(.{
                        .key_press = .{
                            .window_id = window_id,
                            .key = key,
                            .mods = mods,
                        },
                    })
                else
                    core.pushEvent(.{
                        .key_repeat = .{
                            .window_id = window_id,
                            .key = key,
                            .mods = mods,
                        },
                    });
            } else core.pushEvent(.{
                .key_release = .{
                    .window_id = window_id,
                    .key = key,
                    .mods = mods,
                },
            });

            return 0;
        },
        w.WM_CHAR => {
            if (core_window.native) |*native| {
                const char: u16 = @truncate(wParam);
                var chars: []const u16 = undefined;
                if (native.surrogate != 0) {
                    chars = &.{ native.surrogate, char };
                    native.surrogate = 0;
                } else if (std.unicode.utf16IsHighSurrogate(char)) {
                    native.surrogate = char;
                    return 0;
                } else {
                    chars = &.{char};
                }
                var iter = std.unicode.Utf16LeIterator.init(chars);
                if (iter.nextCodepoint()) |codepoint| {
                    core.pushEvent(.{ .char_input = .{
                        .window_id = window_id,
                        .codepoint = codepoint.?,
                    } });
                } else |err| {
                    err catch {};
                }
                return 0;
            }
        },
        w.WM_LBUTTONDOWN,
        w.WM_LBUTTONUP,
        w.WM_RBUTTONDOWN,
        w.WM_RBUTTONUP,
        w.WM_MBUTTONDOWN,
        w.WM_MBUTTONUP,
        w.WM_XBUTTONDOWN,
        w.WM_XBUTTONUP,
        => {
            const mods = getKeyboardModifiers();
            const x: f64 = @floatFromInt(@as(i16, @truncate(lParam & 0xFFFF)));
            const y: f64 = @floatFromInt(@as(i16, @truncate((lParam >> 16) & 0xFFFF)));
            const xbutton: u32 = @truncate(wParam >> 16);
            const button: MouseButton = switch (msg) {
                w.WM_LBUTTONDOWN, w.WM_LBUTTONUP => .left,
                w.WM_RBUTTONDOWN, w.WM_RBUTTONUP => .right,
                w.WM_MBUTTONDOWN, w.WM_MBUTTONUP => .middle,
                else => if (xbutton == @as(u32, @bitCast(w.XBUTTON1))) .four else .five,
            };

            switch (msg) {
                w.WM_LBUTTONDOWN,
                w.WM_MBUTTONDOWN,
                w.WM_RBUTTONDOWN,
                w.WM_XBUTTONDOWN,
                => core.pushEvent(.{
                    .mouse_press = .{
                        .window_id = window_id,
                        .button = button,
                        .mods = mods,
                        .pos = .{ .x = x, .y = y },
                    },
                }),
                else => core.pushEvent(.{
                    .mouse_release = .{
                        .window_id = window_id,
                        .button = button,
                        .mods = mods,
                        .pos = .{ .x = x, .y = y },
                    },
                }),
            }

            return if (msg == w.WM_XBUTTONDOWN or msg == w.WM_XBUTTONUP) w.TRUE else 0;
        },
        w.WM_MOUSEMOVE => {
            const x: f64 = @floatFromInt(@as(i16, @truncate(lParam & 0xFFFF)));
            const y: f64 = @floatFromInt(@as(i16, @truncate((lParam >> 16) & 0xFFFF)));
            core.pushEvent(.{
                .mouse_motion = .{
                    .window_id = window_id,
                    .pos = .{
                        .x = x,
                        .y = y,
                    },
                },
            });
            return 0;
        },
        w.WM_MOUSEWHEEL => {
            const WHEEL_DELTA = 120.0;
            const wheel_high_word: u16 = @truncate((wParam >> 16) & 0xffff);
            const delta_y: f32 = @as(f32, @floatFromInt(@as(i16, @bitCast(wheel_high_word)))) / WHEEL_DELTA;

            core.pushEvent(.{
                .mouse_scroll = .{
                    .window_id = window_id,
                    .xoffset = 0,
                    .yoffset = delta_y,
                },
            });
            return 0;
        },
        w.WM_SETFOCUS => {
            core.pushEvent(.{ .focus_gained = .{ .window_id = window_id } });
            return 0;
        },
        w.WM_KILLFOCUS => {
            core.pushEvent(.{ .focus_lost = .{ .window_id = window_id } });
            return 0;
        },
        else => return w.DefWindowProcW(wnd, msg, wParam, lParam),
    }

    return w.DefWindowProcW(wnd, msg, wParam, lParam);
}

fn keyFromScancode(scancode: u9) Key {
    comptime var table: [0x15D]Key = undefined;
    comptime for (&table, 1..) |*ptr, i| {
        ptr.* = switch (i) {
            0x1 => .escape,
            0x2 => .one,
            0x3 => .two,
            0x4 => .three,
            0x5 => .four,
            0x6 => .five,
            0x7 => .six,
            0x8 => .seven,
            0x9 => .eight,
            0xA => .nine,
            0xB => .zero,
            0xC => .minus,
            0xD => .equal,
            0xE => .backspace,
            0xF => .tab,
            0x10 => .q,
            0x11 => .w,
            0x12 => .e,
            0x13 => .r,
            0x14 => .t,
            0x15 => .y,
            0x16 => .u,
            0x17 => .i,
            0x18 => .o,
            0x19 => .p,
            0x1A => .left_bracket,
            0x1B => .right_bracket,
            0x1C => .enter,
            0x1D => .left_control,
            0x1E => .a,
            0x1F => .s,
            0x20 => .d,
            0x21 => .f,
            0x22 => .g,
            0x23 => .h,
            0x24 => .j,
            0x25 => .k,
            0x26 => .l,
            0x27 => .semicolon,
            0x28 => .apostrophe,
            0x29 => .grave,
            0x2A => .left_shift,
            0x2B => .backslash,
            0x2C => .z,
            0x2D => .x,
            0x2E => .c,
            0x2F => .v,
            0x30 => .b,
            0x31 => .n,
            0x32 => .m,
            0x33 => .comma,
            0x34 => .period,
            0x35 => .slash,
            0x36 => .right_shift,
            0x37 => .kp_multiply,
            0x38 => .left_alt,
            0x39 => .space,
            0x3A => .caps_lock,
            0x3B => .f1,
            0x3C => .f2,
            0x3D => .f3,
            0x3E => .f4,
            0x3F => .f5,
            0x40 => .f6,
            0x41 => .f7,
            0x42 => .f8,
            0x43 => .f9,
            0x44 => .f10,
            0x45 => .pause,
            0x46 => .scroll_lock,
            0x47 => .kp_7,
            0x48 => .kp_8,
            0x49 => .kp_9,
            0x4A => .kp_subtract,
            0x4B => .kp_4,
            0x4C => .kp_5,
            0x4D => .kp_6,
            0x4E => .kp_add,
            0x4F => .kp_1,
            0x50 => .kp_2,
            0x51 => .kp_3,
            0x52 => .kp_0,
            0x53 => .kp_decimal,
            0x54 => .print, // sysrq
            0x56 => .iso_backslash,
            //0x56 => .europe2,
            0x57 => .f11,
            0x58 => .f12,
            0x59 => .kp_equal,
            0x5B => .left_super, // sent by touchpad gestures
            //0x5C => .international6,
            0x64 => .f13,
            0x65 => .f14,
            0x66 => .f15,
            0x67 => .f16,
            0x68 => .f17,
            0x69 => .f18,
            0x6A => .f19,
            0x6B => .f20,
            0x6C => .f21,
            0x6D => .f22,
            0x6E => .f23,
            0x70 => .international2,
            0x73 => .international1,
            0x76 => .f24,
            //0x77 => .lang4,
            //0x78 => .lang3,
            0x79 => .international4,
            0x7B => .international5,
            0x7D => .international3,
            0x7E => .kp_comma,
            0x11C => .kp_enter,
            0x11D => .right_control,
            0x135 => .kp_divide,
            0x136 => .right_shift, // sent by IME
            0x137 => .print,
            0x138 => .right_alt,
            0x145 => .num_lock,
            0x146 => .pause,
            0x147 => .home,
            0x148 => .up,
            0x149 => .page_up,
            0x14B => .left,
            0x14D => .right,
            0x14F => .end,
            0x150 => .down,
            0x151 => .page_down,
            0x152 => .insert,
            0x153 => .delete,
            0x15B => .left_super,
            0x15C => .right_super,
            0x15D => .menu,
            else => .unknown,
        };
    };
    return if (scancode > 0 and scancode <= table.len) table[scancode - 1] else .unknown;
}

// TODO (win32) Implement consistent error handling when interfacing with the Windows API.
// TODO (win32) Support High DPI awareness
// TODO (win32) Consider to add support for mouse capture
// TODO (win32) Change to using WM_INPUT for mouse movement.
