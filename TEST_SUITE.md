
# Test suite

To add more and more...

## DOM 

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
