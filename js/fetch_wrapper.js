// Thin wrapper around native fetch to provide cleaner API
// Avoids double JSON.parse in user code

const nativeFetch = globalThis.fetch;

globalThis.fetch = async function(url, options) {
    // Call native Zig fetch
    const jsonString = await nativeFetch(url);

    // Parse once to get {status, body}
    const raw = JSON.parse(jsonString);

    // Return a Response-like object
    return {
        status: raw.status,
        statusText: raw.status >= 200 && raw.status < 300 ? 'OK' : 'Error',
        ok: raw.status >= 200 && raw.status < 300,

        // Body methods
        text: () => raw.body,
        json: () => JSON.parse(raw.body),

        // For convenience
        body: raw.body
    };
};
