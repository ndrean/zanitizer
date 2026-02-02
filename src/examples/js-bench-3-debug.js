// Debug: trace what's failing in js-bench-3

console.log("=== Debug js-bench-3 ===\n");

// 0. Test HTMLElement global
console.log("0. HTMLElement global:");
console.log("   typeof HTMLElement:", typeof HTMLElement);
console.log("   HTMLElement:", HTMLElement);
if (typeof HTMLElement !== "undefined") {
  console.log("   HTMLElement.prototype:", HTMLElement.prototype);
}

// 1. Test getElementsByTagName
console.log("1. getElementsByTagName('tbody'):");
const tbodies = document.getElementsByTagName("tbody");
console.log("   Type:", typeof tbodies);
console.log("   Result:", tbodies);
console.log("   Length:", tbodies?.length);
console.log("   First:", tbodies?.[0]);

// 2. Test getElementById for template
console.log("\n2. getElementById('itemTemplate'):");
const template = document.getElementById("itemTemplate");
console.log("   Template:", template);
console.log("   TagName:", template?.tagName);

// 3. Test template.content
console.log("\n3. template.content:");
if (template) {
  console.log("   content:", template.content);
  console.log("   content type:", typeof template.content);
  console.log("   content.nodeName:", template.content?.nodeName);
  if (template.content) {
    console.log("   content.children:", template.content.children);
    console.log("   content.childNodes:", template.content.childNodes);
    console.log("   content.firstChild:", template.content.firstChild);
    console.log("   content.firstElementChild:", template.content.firstElementChild);
  }
}

// 4. Test onclick polyfill
console.log("\n4. onclick polyfill test:");
const btn = document.getElementById("run");
console.log("   #run button:", btn);
console.log("   btn.onclick (before):", btn?.onclick);
if (btn) {
  let clicked = false;
  btn.onclick = function() {
    clicked = true;
    console.log("   >>> onclick fired!");
  };
  console.log("   btn.onclick (after set):", btn.onclick);
  console.log("   Dispatching click...");
  btn.dispatchEvent("click");
  console.log("   Clicked?:", clicked);
}

// 5. Test cloneNode
console.log("\n5. cloneNode test:");
if (template && template.content) {
  const clone = template.content.cloneNode(true);
  console.log("   clone:", clone);
  console.log("   clone.nodeName:", clone?.nodeName);
  console.log("   clone.children:", clone?.children);
  console.log("   clone.firstChild:", clone?.firstChild);
  console.log("   clone.innerHTML:", clone?.innerHTML?.substring(0, 100));
}

console.log("\n=== Debug complete ===");
