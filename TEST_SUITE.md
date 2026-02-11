
# Test suite

## File System

Source: js_security.zig

File system restricted by policy, limited to current directory and beyond:

- Symlink blocking,
- traversal rejection, 
- TOCTOU-safe with no_follow,
- hardlink device-ID check,
- 16-level directory stack.

## Worker Mitigation

Source: js_workers.zig

- MAX_WORKERS=8,
- constrainted memory & stack linits: 64MB heap/2MB stack per worker,
- no DOM API,
- interrupt handler with termination flag.

## Main thread MEMORY

Main thread 256MB / 32MB GC threshold, stack limits enforced.

## Module loading

- HTTPS-only for remote,
- SRI hash verification,
- 5MB remote
- 10MB local limits.

## FETCH Mitigation

CA bunble validation
Stream unlimited data until OOM (response size limit)
Infinite redirect (redirect cap needed)
no timeout
internal services via SSRF

`isBlockedUrl()` if sanitization, SSRF pre-flight check

- FETCH_TIMEOUT_MS: 30,000, 30s total, prevents slow-loris
- FETCH_CONNECT_TIMEOUT_MS: 10,000, 10s connect, fails fast on unreachable hosts
- FETCH_MAX_REDIRECTS: 5 Standard browser limit
- FETCH_MAX_RESPONSE_SIZE: 50 MB, General fetch limit (modules already have 5MB)
- CURLOPT_PROTOCOLS_STR: "http,https", Blocks file://, ftp://, dict://, etc.

- compression bombs?
- timing side channels?
  
## DOM

### Sanitizer

- iframe sandboxing,
- SVG/MathML isolation,
- DOM clobbering prevention,
- URI scheme validation.
- XSS


### Deep nesting

<div>...</div> // depth N

Mode	Expected
Hostile	Fail at ~1k
Trusted	Allow up to ~10k
Both	No crash, clear error

### Wide tree

<span></span> x N

Mode	Expected
Hostile	Fail at ~100k
Trusted	Allow ~1M
Both	Linear scaling


## CSS COMPLEXITY TESTS

### Selector depth

div div div div span {}

Mode	Expected
Hostile	Reject
Trusted	Accept
Both	No superlinear CPU

### nth-child

div:nth-child(2n+1) {}

Mode	Expected
Hostile	Reject
Trusted	Accept
Both	CPU bounded


### url() in CSS
background: url(x);

Mode	Expected
Hostile	Reject
Trusted	Allow local only
Both	No network unless allowed

## JS COMPUTE TESTS

### Workers fan-out

`for (let i = 0; i < N; i++) new Worker("w.js");`

Atomic with hardcoded cap `MAX_WORKERS=8`

### Heap growth

`new ArrayBuffer(9^9^9^9)`;

Mode	Expected
Hostile	≤ 64MB
Trusted	≤ 512MB
Both	Clean failure

### Zombie thread  -Busy loop

`while (true) {}`

Mode	Expected
Both	VM killed by CPU quota

No exceptions here. Trusted code can still be buggy.

## IPC ROBUSTNESS TESTS

### Deep message graph

postMessage(deepObject(100k))

Mode	Expected
Hostile	Reject
Trusted	Allow ≤ 1k
Both	No recursion overflow

### Exotic objects

postMessage({ __proto__: null })

Mode	Expected
Both	Safe serialize or reject
E. SEMANTIC JS TESTS

### Prototype mutation

Object.prototype.x = 1;

Mode	Expected
Both	No host effect

### Getter side effects

Object.defineProperty(o, "x", { get() { sideEffect(); }});

Mode	Expected
Hostile	Reject
Trusted	Allow
Both	No sanitizer bypass

## FILESYSTEM TESTS

Same tests in both modes — never relax these.

### Test	Expected

../ traversal	Reject
Symlink	Reject
TOCTOU	Reject

## Policy

```json
{
  "mode": "hostile",
  "limits": {
    "dom_depth": 1024,
    "dom_nodes": 100000,
    "css_complexity": "low",
    "workers": 2,
    "heap_mb": 64,
    "ipc_depth": 64
  }
}
```
