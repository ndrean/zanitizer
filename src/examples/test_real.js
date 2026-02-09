console.log("Script is running");
const html = `
  <div>
    <!-- Safe content -->
    <div class="safe" style="border: 1px solid blue">
      Content with safe inline style
    </div>
    <p id="p1" style="font-size: 16px; color: blue;">P with safe styles</p>
    <p class="safe">Safe CSS class</p>
    <span id="span1" style="color: purple; padding: 10px;">SPAN with safe styles</span>

    <!-- UNTRUSTED: Event handlers (should be removed) -->
    <button onclick="alert('XSS via onclick!')">Click me (onclick)</button>
    <img src="x" onerror="alert('XSS via onerror!')">
    <div onmouseover="alert('XSS via mouseover')">Hover me</div>

    <!-- UNTRUSTED: javascript: URLs (should be removed/sanitized) -->
    <a href="javascript:alert('XSS via href!')">Evil link</a>
    <a href="javascript:void(0)">Another evil link</a>

    <!-- UNTRUSTED: Dangerous CSS (should be sanitized) -->
    <div style="background: url(javascript:alert('CSS XSS'))">JS in CSS url()</div>
    <div style="behavior: url(evil.htc); padding: 5px;">IE behavior hack</div>
    <div style="-moz-binding: url(xss.xml); margin: 10px;">Firefox binding</div>
    <div style="width: expression(alert('XSS')); height: 50px;">IE expression()</div>

    <!-- UNTRUSTED: Script injection attempts -->
    <script>alert('Inline script XSS!')</script>
    <img src="valid.jpg" onload="alert('onload XSS')">

    <!-- UNTRUSTED: data: URLs -->
    <a href="data:text/html,<script>alert('data URL XSS')</script>">Data URL attack</a>
    <iframe src="data:text/html,<script>alert('iframe XSS')</script>"></iframe>

    <!-- Safe content after attacks -->
    <p id="after-attacks" style="color: green; font-weight: bold;">This should survive sanitization</p>
  </div>
`;

document.getElementById("main").innerHTML = html;
console.log("HTML injected - check if attacks were sanitized!");
