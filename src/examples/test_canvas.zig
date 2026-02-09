const std = @import("std");
const builtin = @import("builtin");
const z = @import("zexplorer");
const ScriptEngine = z.ScriptEngine;
const js_canvas = z.js_canvas;

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
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

    // try testJavaScriptAPI(gpa, sandbox_root);
    // try testAsyncJavaScriptAPI(gpa, sandbox_root);
    // try testAsyncBlob(gpa, sandbox_root);
    // try canvasToDataURL_PNG(gpa, sandbox_root);
    // try canvasToDataURL_JPEG(gpa, sandbox_root);
    // try canvasToBlob(gpa, sandbox_root);
    // try canvasToBlobJPEG(gpa, sandbox_root);
    // try createImageToBlob(gpa, sandbox_root);
    // try scenegraph(gpa, sandbox_root);
    // try salesGraph(gpa, sandbox_root);
    // try chart(gpa, sandbox_root);
    // try boldTriangle(gpa, sandbox_root);
    try chartJS2(gpa, sandbox_root);
}

fn testJavaScriptAPI(allocator: std.mem.Allocator, sandbox_root: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sandbox_root);
    defer engine.deinit();

    const SanitizationResult = struct {
        scriptRemoved: bool,
        onclickRemoved: bool,
        safePreserved: bool,
        // Optional because JS might return null or undefined
        resultPreview: ?[]const u8,
    };

    // Load a simple HTML to get the document object
    try engine.loadHTML("<html><body></body></html>");

    // Test document.parseHTMLSafe from JavaScript
    const js_code =
        \\(function() {
        \\  const dirtyHTML = '<div onclick="evil()"><script>alert(1)</script><p>Safe</p></div>';
        \\
        \\  // Parse with safe defaults
        \\  const doc = document.parseHTMLSafe(dirtyHTML);
        \\  const result = doc.body.innerHTML;
        \\
        \\  // Check sanitization worked
        \\  const hasScript = result.includes('<script>');
        \\  const hasOnclick = result.includes('onclick');
        \\  const hasSafe = result.includes('Safe');
        \\
        \\  return {
        \\    scriptRemoved: !hasScript,
        \\    onclickRemoved: !hasOnclick,
        \\    safePreserved: hasSafe,
        \\    resultPreview: result.substring(0, 100)
        \\  };
        \\})()
    ;

    const result_struct = try engine.evalAs(SanitizationResult, js_code, "<js>");

    z.print("\n➡ Example of Sanitization result marshalled as JSON object into a Zig struct---------\n\n", .{});
    std.debug.print("Sanitization Report:\n", .{});
    std.debug.print("  - Script Removed: {}\n", .{result_struct.scriptRemoved});
    std.debug.print("  - OnClick Removed: {}\n", .{result_struct.onclickRemoved});
    if (result_struct.resultPreview) |s| {
        std.debug.print("  - Preview: {s}\n", .{s});
        allocator.free(s); // jsToZig uses allocator.dupe for strings
    }
}

fn testAsyncJavaScriptAPI(allocator: std.mem.Allocator, sandbox_root: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sandbox_root);
    defer engine.deinit();

    // convinience arena to free allocations in one go
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const Headers = struct {
        accept: []const u8,
        @"user-agent": []const u8,
    };
    const AsyncResult = struct {
        headers: Headers,
        origin: []const u8,
        url: []const u8,
    };

    const js_code =
        \\(async () => {
        \\   const resp = await fetch("https://httpbin.org/get");
        \\   const json = await resp.json();
        \\   console.log(json.headers["User-Agent"]);
        \\   return {
        \\    "origin": json.origin,
        \\    "url": json.url,
        \\    "headers": {
        \\      "accept": json.headers["Accept"],
        \\      "user-agent": json.headers["User-Agent"],
        \\    }
        \\   };
        \\})()
    ;

    const result_struct = try engine.evalAsyncAs(arena_alloc, AsyncResult, js_code, "<js>");

    z.print("\n🌍 Example of ASYNC Fetch call returning a JSON object marshalled into a Zig object---\n\n", .{});
    std.debug.print("Fetch Result:\n", .{});
    std.debug.print("  - Origin: {s}\n", .{result_struct.origin});
    std.debug.print("  - URL: {s}\n", .{result_struct.url});
    std.debug.print("  - Headers:\n", .{});
    std.debug.print("    - User-Agent: {s}\n", .{result_struct.headers.@"user-agent"});
}

fn testAsyncBlob(allocator: std.mem.Allocator, sbx: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    // no need arena, single field to free
    // var arena = std.heap.ArenaAllocator.init(allocator);
    // defer arena.deinit();
    // const arena_alloc = arena.allocator();

    const Data = struct {
        size: i64,
        data: []const u8,
    };

    const script =
        \\fetch('https://dummyjson.com/image/150')
        \\.then((response) => response.blob()) 
        \\.then(async (blob) => {
        \\  const blob_ab = await blob.arrayBuffer();
        \\  return {
        \\    size: blob.size,
        \\    data: blob_ab
        \\  };
        \\});
    ;
    const res = try engine.evalAsyncAs(allocator, Data, script, "<fetch>");
    defer allocator.free(res.data);

    z.print("\n🌍 Example ASYNC Fetchting a Blob as ArrayBuffer ----\n\n", .{});
    z.print("Fetchting a Blob:\n", .{});
    z.print("   size: {d} b\n", .{res.size});
    z.print("   data: {s}...\n", .{res.data[0..5]});
}

fn canvasToDataURL_PNG(allocator: std.mem.Allocator, sbc: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbc);
    defer engine.deinit();

    const script =
        \\const canvas = document.createElement('canvas');
        \\canvas.width = 100;
        \\canvas.height = 100;
        \\
        \\const ctx = canvas.getContext('2d');
        \\ctx.fillStyle = 'green';
        \\ctx.fillRect(10, 10, 50, 50);
        // received a PNG, so leave type empty
        \\canvas.toDataURL(); 
    ;

    const data_url = try engine.evalAs([]const u8, script, "<canvas>");
    defer allocator.free(data_url);
    z.print("\n🎆 Example ASYNC Building a simple dummy PNG as DataURL ----\n\n", .{});
    z.print("\n{s}...\n", .{data_url[0..80]});

    if (data_url.len < 22) return error.InvalidDataUrl;
    const comma_idx = std.mem.indexOf(u8, data_url, ",") orelse return error.InvalidDataUrl;
    const b64_part = data_url[comma_idx + 1 ..];
    if (b64_part.len % 4 != 0) return error.InvalidDataUrl;

    const Decoder = std.base64.standard.Decoder;
    const dest_len = try Decoder.calcSizeForSlice(b64_part);
    const png_bytes = try allocator.alloc(u8, dest_len);
    defer allocator.free(png_bytes);

    try Decoder.decode(png_bytes, b64_part);
    try js_canvas.verifyPngStructure(png_bytes);
    try std.fs.cwd().writeFile(.{ .sub_path = "canvas_from_data_url_png_test.png", .data = png_bytes });
    std.debug.print("\nSaved 'canvas_from_data_url_png_test.png' ({d} bytes)\n", .{png_bytes.len});
}

fn canvasToDataURL_JPEG(allocator: std.mem.Allocator, sbc: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbc);
    defer engine.deinit();

    const script =
        \\const canvas = document.createElement('canvas');
        \\canvas.width = 100;
        \\canvas.height = 100;
        \\
        \\const ctx = canvas.getContext('2d');
        \\ctx.fillStyle = 'green';
        \\ctx.fillRect(10, 10, 50, 50);
        \\canvas.toDataURL("image/jpeg", 1); 
    ;

    const data_url = try engine.evalAs([]const u8, script, "<canvas>");
    defer allocator.free(data_url);
    z.print("\n🎆 Example ASYNC Building a simple dummy JPEG as DataURL ----\n\n", .{});
    z.print("\n{s}...\n", .{data_url[0..80]});

    if (data_url.len < 22) return error.InvalidDataUrl;
    const comma_idx = std.mem.indexOf(u8, data_url, ",") orelse return error.InvalidDataUrl;
    const b64_part = data_url[comma_idx + 1 ..];
    if (b64_part.len % 4 != 0) return error.InvalidDataUrl;

    const Decoder = std.base64.standard.Decoder;
    const dest_len = try Decoder.calcSizeForSlice(b64_part);
    const png_bytes = try allocator.alloc(u8, dest_len);
    defer allocator.free(png_bytes);

    try Decoder.decode(png_bytes, b64_part);
    // try js_canvas.verifyPngStructure(png_bytes);
    try std.fs.cwd().writeFile(.{ .sub_path = "canvas_from_data_url_jpeg_test.jpeg", .data = png_bytes });
    std.debug.print("\nSaved 'canvas_from_data_url_jpeg_test.jpeg' ({d} bytes)\n", .{png_bytes.len});
}

fn canvasToBlob(allocator: std.mem.Allocator, sbc: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbc);
    defer engine.deinit();

    const script =
        \\ async function testBlob() {
        \\  const canvas = document.createElement('canvas');
        \\  canvas.width = 100;
        \\  canvas.height = 100;
        \\  const ctx = canvas.getContext('2d');
        \\  for (var i = 0; i < 6; i++) {
        \\    for (var j = 0; j < 6; j++) {
        \\      ctx.fillStyle ="rgb(" + Math.floor(255 - 42.5 * i) + "," + Math.floor(255 - 42.5 * j) + ",0)";
        \\      ctx.fillRect(j * 25, i * 25, 25, 25);
        \\      }
        \\  }
        \\  ctx.fillStyle = 'green';
        \\  ctx.fillRect(10, 10, 50, 50);
        \\  const cb = blob => blob.arrayBuffer();
        // defaults to PNG
        \\  const blob = await canvas.toBlob();
        \\  return await blob.arrayBuffer();
        \\}
        \\testBlob();
    ;

    const png_bytes = try engine.evalAsyncAs(
        allocator,
        []const u8,
        script,
        "<canvas>",
    );

    defer allocator.free(png_bytes);

    z.print("\n🎆 Example ASYNC Building a simple dummy PNG ----\n\n", .{});
    // try js_canvas.verifyPngStructure(png_bytes);
    try std.fs.cwd().writeFile(.{ .sub_path = "canvas_from_blob_test.png", .data = png_bytes });
    std.debug.print("\nSaved 'canvas_from_blob_test.png' ({d} bytes)\n", .{png_bytes.len});
}

fn canvasToBlobJPEG(allocator: std.mem.Allocator, sbc: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbc);
    defer engine.deinit();

    const script =
        \\ async function testBlob() {
        \\  const canvas = document.createElement('canvas');
        \\  canvas.width = 100;
        \\  canvas.height = 100;
        \\  const ctx = canvas.getContext('2d');
        \\  for (var i = 0; i < 6; i++) {
        \\    for (var j = 0; j < 6; j++) {
        \\      ctx.fillStyle ="rgb(" + Math.floor(255 - 42.5 * i) + "," + Math.floor(255 - 42.5 * j) + ",0)";
        \\      ctx.fillRect(j * 25, i * 25, 25, 25);
        \\      }
        \\  }
        \\  ctx.fillStyle = 'green';
        \\  ctx.fillRect(10, 10, 50, 50);
        \\  const blob = new Promise((resolve, reject) => {
        \\    return canvas.toBlob(
        \\      (blob) => {
        \\        if (!blob) {
        \\          reject("Blob creation failed");
        \\          return;
        \\        };
        \\
        \\        blob.arrayBuffer().then(resolve)
        \\      },
        \\      "image/jpeg", 1)
        \\  });
        \\  return await blob;
        \\}
        \\testBlob();
    ;

    const png_bytes = try engine.evalAsyncAs(
        allocator,
        []const u8,
        script,
        "<canvas>",
    );

    defer allocator.free(png_bytes);

    z.print("\n🎆 Example ASYNC Building a simple dummy PNG ----\n\n", .{});
    // try js_canvas.verifyPngStructure(png_bytes);
    try std.fs.cwd().writeFile(.{ .sub_path = "canvas_from_blob_to_jepg_test.jpeg", .data = png_bytes });
    std.debug.print("\nSaved 'canvas_from_blob_to_jepg_test.jpeg' ({d} bytes)\n", .{png_bytes.len});
}

fn createImageToBlob(allocator: std.mem.Allocator, sbc: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbc);
    defer engine.deinit();

    const js =
        \\ async function test() {
        \\  const resp = await fetch("https://httpbin.org/image/png");
        // \\ const resp = await fetch("https://dummyjson.com/image/150");
        \\  const blob = await resp.blob();
        \\  const img = await createImageBitmap(blob);
        \\  const canvas = document.createElement('canvas');
        \\  canvas.width = img.width*2;
        \\  canvas.height = img.height*2;
        // \\  possible: const canvas = new Canvas(img.width*2, img.height*2);
        \\  const ctx = canvas.getContext('2d');
        // \\  ctx.scale(2,2);
        \\  ctx.drawImage(img, 0, 0);
        \\  ctx.fillStyle = "blue";
        \\  console.log("[JS] font-size: ", ctx.font);
        \\  ctx.font = "20px";
        \\  const txt = "Hello from Zig!"
        \\  const metrics = ctx.measureText(txt);
        \\  console.log("[JS] metrics: ", metrics);
        \\  const x = (canvas.width - metrics.width) / 2;
        \\  const y = (canvas.height ) / 2;
        \\  ctx.fillText(txt, x,y);
        \\  ctx.translate(0,100);
        \\  ctx.fillText("Moved!", 25, 25);
        // \\  confirm the image is what we expect
        \\  const result = await canvas.toBlob();
        \\  return await result.arrayBuffer();
        \\}
        \\test();
    ;
    const png_bytes = try engine.evalAsyncAs(allocator, []const u8, js, "<image>");
    defer allocator.free(png_bytes);
    z.print("{s}\n", .{png_bytes[0..15]});
    z.print("\n🎆 Example ASYNC Fetching a PNG, edit in Canvas and save ----\n\n", .{});
    try js_canvas.verifyPngStructure(png_bytes);
    try std.fs.cwd().writeFile(.{ .sub_path = "canvas_fetch_image_test.png", .data = png_bytes });
    std.debug.print("\nSaved 'fetch_image_blob_test.png' ({d} bytes)\n", .{png_bytes.len});
}

fn scenegraph(allocator: std.mem.Allocator, sbc: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbc);
    defer engine.deinit();

    const script =
        \\async function scenegraph() {
        \\  const canvas = document.createElement('canvas');
        \\  canvas.width = 200;
        \\  canvas.height = 200;
        \\  const ctx = canvas.getContext('2d');
        \\  ctx.fillStyle = "red";
        \\  ctx.fillRect(0, 0, 50, 50);
        \\  ctx.save();
        \\  ctx.translate(100, 100);
        \\  ctx.scale(2, 2);
        \\  ctx.fillStyle = "blue";
        \\  ctx.fillRect(0, 0, 50, 50);
        \\  ctx.restore();
        \\  ctx.fillRect(60, 0, 50, 50);
        \\  const blob = await canvas.toBlob();
        \\  return await blob.arrayBuffer();
        \\}
        \\scenegraph();
    ;

    const png_bytes = try engine.evalAsyncAs(allocator, []const u8, script, "<image>");
    defer allocator.free(png_bytes);
    z.print("{s}\n", .{png_bytes[0..15]});
    z.print("\n🎆 Example scenegraph in Canvas ----\n\n", .{});
    // try js_canvas.verifyPngStructure(png_bytes);
    try std.fs.cwd().writeFile(.{ .sub_path = "canvas_scenegraph_test.png", .data = png_bytes });
}

fn salesGraph(allocator: std.mem.Allocator, sbc: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbc);
    defer engine.deinit();

    const script =
        \\async function salesGraph() {
        \\  const canvas = document.createElement('canvas');
        \\  canvas.width = 200;
        \\  canvas.height = 200;
        \\  const ctx = canvas.getContext('2d');
        \\  ctx.fillStyle = "white";
        \\  ctx.fillRect(0, 0, 150, 150);

        // Draw Axis
        \\  ctx.fillStyle = "black"; // Used for stroke color in our MVP
        \\  ctx.beginPath();
        \\  ctx.moveTo(10, 10);
        \\  ctx.lineTo(10, 140); // Y Axis
        \\  ctx.lineTo(140, 140); // X Axis
        \\  ctx.stroke();
        // Draw Data
        \\  ctx.beginPath();
        \\  ctx.moveTo(10, 140);
        \\  ctx.lineTo(40, 100);
        \\  ctx.lineTo(80, 120);
        \\  ctx.lineTo(120, 20); // Spike!
        \\  ctx.stroke();
        // \\  ctx.closePath();
        \\  ctx.fillText("Sales", 70, 10);
        \\  const blob = await canvas.toBlob();
        \\  return await blob.arrayBuffer();
        \\}
        \\salesGraph();
    ;

    const png_bytes = try engine.evalAsyncAs(allocator, []const u8, script, "<image>");
    defer allocator.free(png_bytes);
    z.print("{s}\n", .{png_bytes[0..15]});
    z.print("\n🎆 Example Graphic in Canvas ----\n\n", .{});
    // try js_canvas.verifyPngStructure(png_bytes);
    try std.fs.cwd().writeFile(.{ .sub_path = "canvas_salesgraph_test.png", .data = png_bytes });
}

fn chart(allocator: std.mem.Allocator, sbc: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbc);
    defer engine.deinit();

    const script =
        \\async function salesGraph() {
        \\  const canvas = document.createElement('canvas');
        \\  canvas.width = 200;
        \\  canvas.height = 200;
        \\  const ctx = canvas.getContext('2d');
        \\
        \\  ctx.fillStyle = "white";
        \\  ctx.fillRect(0, 0, 200, 200);
        //  AXES (Gray)
        \\  ctx.strokeStyle = "#888888";
        \\  ctx.beginPath();
        \\  ctx.moveTo(20, 20);
        \\  ctx.lineTo(20, 180);
        \\  ctx.lineTo(180, 180);
        \\  ctx.stroke();
        // DATA LINE (Blue)
        \\  ctx.strokeStyle = "blue";
        \\  ctx.beginPath();
        \\  ctx.moveTo(20, 180);
        \\  ctx.lineTo(100, 100);
        \\  ctx.lineTo(180, 40);
        \\  ctx.stroke();
        //  DATA POINTS (Red Circles)
        \\  ctx.strokeStyle = "red";
        \\  const points = [[20, 180], [100, 100], [180, 40]];
        \\  for (const p of points) {
        \\    ctx.beginPath();
        \\    ctx.arc(p[0], p[1], 5, 0, 6.28); 
        \\    ctx.stroke();
        \\  }
        \\  ctx.fillText("Sales", 70, 10);
        \\  const blob = await canvas.toBlob();
        \\  return await blob.arrayBuffer();
        \\  }
        \\salesGraph();
    ;

    const png_bytes = try engine.evalAsyncAs(allocator, []const u8, script, "<image>");
    defer allocator.free(png_bytes);
    z.print("{s}\n", .{png_bytes[0..15]});
    z.print("\n🎆 Example Graph in Canvas ----\n\n", .{});
    // try js_canvas.verifyPngStructure(png_bytes);
    try std.fs.cwd().writeFile(.{ .sub_path = "canvas_graph_test.png", .data = png_bytes });
}

fn boldTriangle(allocator: std.mem.Allocator, sbc: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbc);
    defer engine.deinit();

    const script =
        \\async function salesGraph() {
        \\  const canvas = document.createElement('canvas');
        \\  canvas.width = 200;
        \\  canvas.height = 200;
        \\  const ctx = canvas.getContext('2d');
        \\
        \\  ctx.fillStyle = "white";
        \\  ctx.fillRect(0, 0, 200, 200);
        \\  ctx.beginPath();
        \\  ctx.lineWidth = 10;          // NEW! Bold lines
        \\  ctx.strokeStyle = "red";
        \\  ctx.moveTo(100, 20);         // Top
        \\  ctx.lineTo(180, 180);        // Bottom Right
        \\  ctx.lineTo(20, 180);         // Bottom Left
        \\  ctx.closePath();             // NEW! Auto-connects back to Top
        \\  ctx.stroke();
        \\  const blob = await canvas.toBlob(blob => blob.arrayBuffer(), "image.jpeg", 1);
        // \\  return await blob.arrayBuffer();
        \\  return blob;
        \\  }
        \\salesGraph();
    ;

    const png_bytes = try engine.evalAsyncAs(allocator, []const u8, script, "<image>");
    defer allocator.free(png_bytes);
    z.print("{s}\n", .{png_bytes[0..15]});
    z.print("\n🎆 Example Bold Triangle in Canvas ----\n\n", .{});
    // try js_canvas.verifyPngStructure(png_bytes);
    try std.fs.cwd().writeFile(.{ .sub_path = "canvas_bold_triangle.png", .data = png_bytes });
}

fn chartJS2(allocator: std.mem.Allocator, sbx: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    const chartjs = @embedFile("vendor/chart.js");
    std.debug.print("Chart.js bundle size: {d}\n", .{chartjs.len});
    const chartjs_val = try engine.eval(chartjs, "<chartjs>", .global);
    engine.ctx.freeValue(chartjs_val);

    const html = @embedFile("test_canvas.html");
    try engine.loadHTML(html);

    const body = z.bodyNode(engine.dom.doc);
    const maybe_script = z.getElementByTag(body.?, .script);
    if (maybe_script) |script_elt| {
        const script = z.textContent_zc(z.elementToNode(script_elt));

        const png_bytes = try engine.evalAsyncAs(allocator, []const u8, script, "<image>");
        defer allocator.free(png_bytes);
        z.print("{s}\n", .{png_bytes[0..15]});
        z.print("\n🎆 Example GraphJS in Canvas ----\n\n", .{});
        // try js_canvas.verifyPngStructure(png_bytes);
        try std.fs.cwd().writeFile(.{ .sub_path = "canvas_graphJS_test.png", .data = png_bytes });
    }
}
