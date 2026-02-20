// src/examples/test_scrape.js

async function fetchUsers() {
  console.log("[JS] Fetching users...");
  const res = await fetch("https://dummyjson.com/users?limit=3");
  const data = await res.json();

  // Transform the data however we want
  const results = data.users.map((u) => ({
    fullName: `${u.firstName} ${u.lastName}`,
    email: u.email,
    scrapedAt: Date.now(),
  }));

  // Return the object directly to Zig!
  return {
    success: true,
    count: results.length,
    users: results,
  };
}

fetchUsers();
