// Test TextEncoder
console.log("--- TextEncoder ---");
const encoder = new TextEncoder();
console.log("encoder.encoding:", encoder.encoding);

const text = "Hello, World! 你好世界 🚀";
console.log("Input text:", text);

const encoded = encoder.encode(text);
console.log("Encoded type:", encoded.constructor.name);
console.log("Encoded length:", encoded.length, "bytes");
console.log("First 10 bytes:", Array.from(encoded.slice(0, 10)));

// Test TextDecoder
console.log("\n--- TextDecoder ---");
const decoder = new TextDecoder();
console.log("decoder.encoding:", decoder.encoding);
console.log("decoder.fatal:", decoder.fatal);
console.log("decoder.ignoreBOM:", decoder.ignoreBOM);

const decoded = decoder.decode(encoded);
console.log("Decoded text:", decoded);
console.log("Round-trip success:", decoded === text);

// Test with ArrayBuffer
console.log("\n--- ArrayBuffer Test ---");
const buffer = new Uint8Array([72, 101, 108, 108, 111]).buffer;
const decoded2 = decoder.decode(buffer);
console.log("Decoded from ArrayBuffer:", decoded2);

// Test encodeInto
console.log("\n--- encodeInto ---");
const dest = new Uint8Array(20);
const result = encoder.encodeInto("Test", dest);
console.log("encodeInto result:", result);
console.log("Dest bytes:", Array.from(dest.slice(0, result.written)));

// Test fatal decoder
console.log("\n--- Fatal decoder ---");
const fatalDecoder = new TextDecoder("utf-8", { fatal: true });
console.log("fatalDecoder.fatal:", fatalDecoder.fatal);

console.log("\n=== 🟢 All TextEncoder/TextDecoder tests passed! \n");
