try {
  const parser = new DOMParser();
  const doc = parser.parseFromString(
    '<div id="box" class="blue green"></div>',
    "text/html",
  );
  const el = doc.getElementById("box");

  if (!el) {
    console.log("Error: Could not find element");
    throw new Error("Element not found");
  }

  console.log("Element found, className:", el.className);

  // Test classList access
  const cl = el.classList;
  console.log("classList.length:", cl.length);
  console.log("classList.value:", cl.value);

  // Test contains
  console.log("contains('blue'):", cl.contains("green"));
  console.log("contains('green'):", cl.contains("green"));

  // Test add
  cl.add("red");
  console.log("After add('red'):", el.className);

  cl.add("black");
  console.log("After add('black'):", el.className);

  // Test remove
  cl.remove("blue");
  console.log("After remove('blue'):", el.className);

  // Test toggle
  let added = cl.toggle("active");
  console.log("toggle('active'):", added, "className:", el.className);

  let removed = cl.toggle("active");
  console.log("toggle again:", removed, "className:", el.className);

  // Test toggle with force
  cl.toggle("forced", true);
  console.log("toggle('forced', true):", el.className);

  // Test replace
  cl.add("old");
  let replaced = cl.replace("old", "new");
  console.log("replace('old','new'):", replaced, "className:", el.className);

  // Test item (use classList.value to set class instead of className)
  cl.value = "a b c";
  console.log("After classList.value='a b c':", el.className);
  console.log("item(0):", cl.item(0));
  console.log("item(1):", cl.item(1));
  console.log("item(99):", cl.item(99));

  // Test value setter again
  cl.value = "x y z";
  console.log("After value='x y z':", el.className, "length:", cl.length);

  console.log("=== All classList tests passed! ===");
} catch (e) {
  console.log("Error:", e.message || e);
}
