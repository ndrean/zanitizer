// Test fetch with structured return (status + body)
async function testFetch() {
    console.log("Testing fetch with structured result...");

    try {
        // Fetch from example.com
        // Note: bindAsyncJson returns a JSON string, not an object
        const jsonString = await fetch("https://example.com");

        console.log("Fetch succeeded!");
        console.log("Raw response type:", typeof jsonString);

        // Parse the JSON string to get the actual result object
        const result = JSON.parse(jsonString);

        console.log("Status code:", result.status);
        console.log("Body length:", result.body.length);
        console.log("First 200 chars:", result.body.substring(0, 200));

        // Verify it's an object with the expected fields
        if (typeof result === 'object' && result.status && result.body) {
            console.log("✓ Result has correct structure");
        } else {
            console.log("✗ Result structure is incorrect");
        }

    } catch (err) {
        console.error("Fetch failed:", err);
    }
}

testFetch();
