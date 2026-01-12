const btn = document.createElement("button");

const form = document.createElement("form");
form.appendChild(btn);
document.body.appendChild(form);

const mylist = document.createElement("ul");

for (let i = 1; i < 3; i++) {
  const item = document.createElement("li");
  item.setContentAsText("Item " + i * 10);
  item.setAttribute("id", i);
  mylist.appendChild(item);
}
document.body.appendChild(mylist);

console.log("[JS] Initial document", document.body.innerHTML);

// --------------------------------------------------------------------
// DOM Event Listener with Delayed action with Timer
// --------------------------------------------------------------------

form.addEventListener("submit", (e) => {
  e.preventDefault(); // Prevent actual form submission
  console.log("[JS] ⌛️ 📝 Form Submitted! Event Type:", e.type);
});

setTimeout(() => {
  console.log("[JS] Submit the form! ⏳");
  form.dispatchEvent("submit");
  console.log("[JS] Final HTML: ", document.body.innerHTML);
}, 1000);

// --------------------------------------------------------------------
// Simple reactive object
// --------------------------------------------------------------------

function createReactiveObject(target, callback) {
  return new Proxy(target, {
    set(obj, prop, value) {
      const oldValue = obj[prop];
      obj[prop] = value;

      // Trigger callback on change
      if (oldValue !== value) {
        const prop_id = prop === "name" ? "#1" : prop === "age" ? "#2" : null;
        document.querySelector(prop_id).setContentAsText(value); // Normal DOM update
        callback(prop, oldValue, value);
      }

      return true;
    },

    get(obj, prop) {
      return obj[prop];
    },
  });
}

// Instantiate the data and the DOM
const data = { name: "John", age: 30 };
document.querySelector("#1").setContentAsText(data.name);
document.querySelector("#2").setContentAsText(data.age);
console.log("[JS] Direct DOM injection: ", document.body.innerHTML);

// Reactive function
const reactiveData = createReactiveObject(data, (prop, oldVal, newVal) => {
  console.log(`[JS] Reaction: change '${prop}'`, document.body.innerHTML);
  // console.log(`[JS] Property ${prop} changed from ${oldVal} to ${newVal}`);
});

// 1. First reaction via property change
reactiveData.name = "Jane"; // Logs: Property name changed from John to Jane
// console.log("[JS]", document.body.innerHTML);

// Event Listener to change age
btn.addEventListener("click", (e) => {
  console.log("[JS] ⚡️ Button Clicked! Event Type:", e.type);
  reactiveData.age *= 2; // Triggers reactive log
});

// 2. Second reaction via event
console.log("[JS] Click the button! ✅");
btn.dispatchEvent("click");

// --------------------------------------------------------------------
// Reactive Array
// --------------------------------------------------------------------
function reactiveArray(arr, callback) {
  return new Proxy(arr, {
    set(target, key, value) {
      const oldValue = target[key];
      target[key] = value;

      if (oldValue !== value) {
        callback("set", key, value, target);
      }

      return true;
    },

    get(target, key) {
      // Intercept array methods
      if (typeof target[key] === "function") {
        return function (...args) {
          const method = key;
          const result = Array.prototype[method].apply(target, args);

          // Notify for mutating methods
          const mutatingMethods = [
            "push",
            "pop",
            "shift",
            "unshift",
            "splice",
            "sort",
            "reverse",
          ];
          if (mutatingMethods.includes(method)) {
            callback(method, args, target);
          }

          return result;
        };
      }

      return target[key];
    },
  });
}

// Usage
const list = reactiveArray([1, 2, 3], (method, args, arr) => {
  console.log(`Array ${method}:`, arr);
});

list.push(4); // Logs: Array push: [1, 2, 3, 4]
list[0] = 100; // Logs: Array set: [100, 2, 3, 4]

// --------------------------------------------------------------------
// Deep Reactive Object
// --------------------------------------------------------------------

function deepReactive(obj, callback) {
  // Handle nested objects
  for (let key in obj) {
    if (typeof obj[key] === "object" && obj[key] !== null) {
      obj[key] = deepReactive(obj[key], (propPath, oldVal, newVal) => {
        callback(`${key}.${propPath}`, oldVal, newVal);
      });
    }
  }

  return new Proxy(obj, {
    set(target, key, value) {
      const oldValue = target[key];

      // If new value is object, make it reactive
      if (typeof value === "object" && value !== null) {
        value = deepReactive(value, (propPath, oldVal, newVal) => {
          callback(`${key}.${propPath}`, oldVal, newVal);
        });
      }

      target[key] = value;

      if (oldValue !== value) {
        callback(key, oldValue, value);
      }

      return true;
    },
  });
}

// Usage
const state = deepReactive(
  {
    user: {
      name: "John",
      address: {
        city: "New York",
      },
    },
  },
  (path, oldVal, newVal) => {
    console.log(`${path} changed: ${oldVal} -> ${newVal}`);
  }
);

state.user.name = "Jane"; // user.name changed: John -> Jane
state.user.address.city = "Boston"; // user.address.city changed: New York -> Boston
