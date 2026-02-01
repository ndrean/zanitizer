async function testFormDataUpload() {
  console.log("--- Creating FormData ---");

  const formData = new FormData();

  // Add a simple text field
  formData.append("username", "testuser");
  formData.append("email", "test@example.com");

  // Add a Blob as a file
  const fileContent = "Hello, this is file content!\nLine 2 of the file.";
  const blob = new Blob([fileContent], { type: "text/plain" });
  formData.append("document", blob, "test.txt");

  // Add another Blob (binary-ish data)
  const jsonData = JSON.stringify({
    key: "value",
    nested: { first: "second" },
  });
  const jsonBlob = new Blob([jsonData], { type: "application/json" });
  formData.append("config", jsonBlob, "config.json");

  console.log("FormData created with:");
  console.log("  - username: testuser");
  console.log("  - email: test@example.com");
  console.log("  - document: test.txt (text/plain)");
  console.log("  - config: config.json (application/json)");

  console.log("\n--- Uploading to httpbin.org/post ---");

  const response = await fetch("https://httpbin.org/post", {
    method: "POST",
    body: formData,
  });

  console.log("Status:", response.status);
  console.log("OK:", response.ok);

  const data = await response.json();

  console.log("\n--- Server Response ---");
  console.log("Form fields received:");
  if (data.form) {
    for (const [key, value] of Object.entries(data.form)) {
      console.log("  " + key + ":", value);
    }
  }

  console.log("\nFiles received:");
  if (data.files) {
    for (const [key, value] of Object.entries(data.files)) {
      const preview =
        typeof value === "string"
          ? value.substring(0, 50)
          : JSON.stringify(value).substring(0, 50);
      console.log("  " + key + ":", preview + (value.length > 50 ? "..." : ""));
    }
  }
}

testFormDataUpload().catch((e) => console.log("Error:", e.message || e));
