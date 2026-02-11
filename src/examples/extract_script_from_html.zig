const std = @import("std");
const builtin = @import("builtin");
const z = @import("zexplorer");
const zqjs = z.wrapper;
const ScriptEngine = z.ScriptEngine;
const NativeBridge = z.native_bridge;

pub var app_should_quit = std.atomic.Value(bool).init(false);

fn handleSigInt(_: c_int) callconv(.c) void {
    app_should_quit.store(true, .seq_cst);
}

// Setup function to call at start of main()
pub fn setupSignalHandler() void {
    if (builtin.os.tag == .windows) {
        // !! Windows needs a different approach (SetConsoleCtrlHandler),
        // but we focus on POSIX (Linux/macOS)
        return;
    }

    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleSigInt },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };

    // Catch Ctrl+C (SIGINT)
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    // Optional: Catch Termination request (SIGTERM)
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const gpa, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.c_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const sandbox_root = try std.fs.cwd().realpathAlloc(gpa, ".");
    defer gpa.free(sandbox_root);
    setupSignalHandler();

    try extractScript(gpa, sandbox_root);
}

fn extractScript(allocator: std.mem.Allocator, sandbox_root: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sandbox_root);
    defer engine.deinit();

    z.print("\n=== Extract Script from HTML -------------------------\n\n", .{});

    const html =
        \\<body>
        \\  <h1>Test</h1>
        \\
        \\  <script>
        \\    function greet(name) {
        \\      return `Hello, ${name}!`;
        \\    }
        \\  </script>
        \\
        \\  <script>var a = 10;</script>
        \\
        \\  <div id="ignore"></div>
        \\
        \\  <script>
        \\      var b = a + 20; 
        \\      console.log("[JS] Result: ", b);
        \\      console.log("[JS] Evaluate function 'greet('Zig')' : ", greet('Zig'));
        \\      document.querySelector('#ignore').innerHTML = greet('Zig from JS');
        \\      b;
        \\  </script>
        \\</body>
    ;
    try engine.loadHTML(html);
    const doc = engine.dom.doc;
    const div_elt = try z.querySelector(allocator, doc, "div#ignore");
    try z.printDoc(allocator, doc, "Before execution");

    try engine.executeScripts(allocator, sandbox_root);

    // const div_elt = try z.querySelector(allocator, doc, "div#ignore");
    const content = z.textContent_zc(z.elementToNode(div_elt.?));
    z.print("[Zig] DIV content has been changed to: {s}\n", .{content});

    try z.printDoc(allocator, doc, "After execution");
}
