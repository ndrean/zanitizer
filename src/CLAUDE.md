# CLAUDE.md

This file provides guidance to CLAUDE.md when working woth code in this repository named zexplorer.

## What is it?

A project written with Zig v0.15.2. The README.md introduction gives an overview of the tooling used:

- quickjs-ng and the wrapper library src/wrapper.zig, 
- lexbor whose wrappers are under src/modules (with c-shims in src/css_shim.c and src/minimal.c), 
- thorvg is built,
- stb_image, stb_image_writer, stb_truetype are vendored and built,
- libharu is build,
- mimiz is used to fake zlib and is built,
- yoga is built,
- multi-curl via zig-curl is a libary;
- httpz-zig is a library
- Lexbor is used as a static .a object due to build complexity.

The README.md is still under construction.

We are developping a CLI and also a daemon version.
The CLI is used for composing/piping and more for debugging.
For the daemon, the idea is to code the pipeline in Javascript and POST it to the :9984/run endpoint.
Some custom functions are proposed in src/zexplorer.js and in src/dom_bridge.zig

## Lexbor/Quickjs bindings

The lexbor/zig wrappers are exposed in src/root.zig.
Quite a few are binded inot Quickjs. The process, whenever possible, is to add an entry in tools/bindings.zig and run `zig run tools/template_gen.zg -- src/bindings_generated.zig` to generate bindings.
If the template format is too complicated to design, the binding is done manually in src/dom_bridge.zig.

## Shared Processes

Everytime we run zeplorer (the executable is named `zxp`), we start a new quickjs runtime.
The `serve` mode is for serving over HTTP to run more efficiently.

## Zig v0.15.2 specifics

The ArrayList in this version is always unmanaged.
This means:

```zig
const list: std.ArrayList(u8) = .empty;
...
try list.append(allocator, new_item);
try list.toOwnedSlice(allocator);
```

### Usage

Using `zig build example -Dname=xxx` or the CLI with pipes or Daemon `serve`. Defined in src/main.zig

```sh
# CLI: run a script and sest the base_url for the images
./zig-out/bin/zxp run  src/examples/vercel-demo/inline-select.js --base https://demo.vercel.store

./zig-out/bin/zxp run src/examples/chunk_post.js | ./zig-out/bin/zxp stream - 

./zig-out/bin/zxp convert src/examples/test_grid_1d.html -w 595 -o grid.jpeg
zig build example -Dname=test_grid_1d  

 
cat -- src/examples/test_stream_pipeline.html \                                                                        53s   system
  | ./zig-out/bin/zxp stream - \
  | ./zig-out/bin/zxp sanitize - > pipeline.html

cat -- src/examples/test_stream_pipeline.html \                                                                                                                   53s   system
  | ./zig-out/bin/zxp stream - \
  | ./zig-out/bin/zxp sanitize - | ./zig-out/bin/zxp convert - -o pipeline.png

./zig-out/bin/zxp run src/examples/test_cli_invoice.js -o invoice.pdf file://src/examples/test_cli_invoice_data.json 

./zig-out/bin/zxp render pipeline_demo.html -o pipeline.png

echo '<!DOCTYPE html><html><head><style>h1{color:blue;font-size:40px}body{background:#fff;}</style></head><body><h1>CSS Test</h1><p style="color:red">inline style test</p></body></html>' | \
./zig-out/bin/zxp convert - -o full_css_rendering.png

./zig-out/bin/zxp scrape https://cnn.com > cnn.html

./zig-out/bin/zxp scrape https://news.ycombinator.com \                                                                                                           53s   system
  -e "Array.from(document.querySelectorAll('.titleline a')).map(a=>[a.textContent,a.href])" \
  --pretty


./zig-out/bin/zxp scrape https://demo.vercel.Store --selector "a[href^='/product/']" -f json


zig build example -Dname=test_og_generator -o pg.pdf
zig build example -Dname=test_custom-lit-element
