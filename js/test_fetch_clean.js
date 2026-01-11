// Import fetch wrapper for cleaner API
importScripts("js/fetch_wrapper.js");

// Test fetch with Response-like object
async function testFetch() {
    console.log("Testing fetch with Response wrapper...");

    try {
        // Now fetch returns a proper Response object!
        const response = await fetch("https://example.com");

        console.log("Fetch succeeded!");
        console.log("Status:", response.status);
        console.log("OK:", response.ok);
        console.log("Status Text:", response.statusText);

        // Get body as text
        const text = response.text();
        console.log("Body length:", text.length);
        console.log("First 200 chars:", text.substring(0, 200));

        // Or parse as JSON (for API endpoints)
        // const data = response.json();

        console.log("✓ Response API works correctly!");

    } catch (err) {
        console.error("Fetch failed:", err);
    }
}

testFetch();
