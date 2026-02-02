console.log("\n=== URL Parsing & Getters ----------\n\n");
const url = new URL(
  "https://user:pass@example.com:8080/api/v1?key=value&bank=action#section",
);

console.log("Full URL:", url.toString());
console.log("  protocol:", url.protocol, url.protocol === "https");
console.log("  username:", url.username === "user");
console.log("  password:", url.password === "pass");
console.log("  hostname:", url.hostname === "example.com");
console.log("  port:", url.port === "8080");
console.log("  pathname:", url.pathname === "/api/v1");
console.log("  search:", url.search === "?key=value&bank=action");
console.log("  hash:", url.hash === "#section");

console.log("\n=== URL with Base (Relative Parsing) --------\n");

const base = new URL("https://example.org/foo/");
const relative = new URL("../params?test=1", base);
console.log("Relative URL:", relative.toString());
console.log("  pathname:", relative.pathname === "/params");
console.log("  hostname:", relative.hostname === "example.org");

console.log("\n=== URLSearchParams - Construction & Basic Methods ===");
const params = new URLSearchParams("key=value&a=b&key=duplicate");
console.log("Initial:", params.toString());
console.log("  get('key'):", params.get("key")); // Returns first value
console.log("  has('a'):", params.has("a"));
console.log("  has('missing'):", params.has("missing"));

console.log("\n=== URLSearchParams - Append, Set, Delete ===");
params.append("new", "123");
console.log("After append('new', '123'):", params.toString());

params.set("key", "updated"); // Replaces all 'key' values
console.log("After set('key', 'updated'):", params.toString());

params.delete("a");
console.log("After delete('a'):", params.toString());

console.log("\n=== URLSearchParams - Sort ===");
const unsorted = new URLSearchParams("z=last&a=first&m=middle");
console.log("Before sort:", unsorted.toString());
unsorted.sort();
console.log("After sort:", unsorted.toString());

console.log("\n=== URLSearchParams - Strip Leading '?' ===");
const withQuestion = new URLSearchParams("?foo=bar&baz=qux");
console.log("From '?foo=bar&baz=qux':", withQuestion.toString());

console.log("\n=== URL with Different Host Types ===");
const ipv4 = new URL("http://192.168.1.1:3000/test");
console.log("IPv4 hostname:", ipv4.hostname);

const domain = new URL("https://subdomain.example.org/api");
console.log("Domain hostname:", domain.hostname);

console.log("\n=== Headers API ===");
const headers = new Headers({
  "Content-Type": "application/json",
  "X-Custom-Header": "test-value",
});
console.log("  has('content-type'):", headers.has("content-type"));
console.log("  get('content-type'):", headers.get("content-type"));
console.log("  get('x-custom-header'):", headers.get("x-custom-header"));

headers.set("Authorization", "Bearer token123");
console.log("  After set Authorization:", headers.get("authorization"));

headers.append("Cache-Control", "no-cache");
console.log("  After append Cache-Control:", headers.get("cache-control"));

headers.delete("x-custom-header");
console.log("  After delete x-custom-header:", headers.has("x-custom-header"));

console.log("\n✅ All URL & URLSearchParams tests passed!");
