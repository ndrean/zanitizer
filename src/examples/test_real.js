console.log("Script is running");
const html = `
  <div>
    <div
    class="safe"
    style="border: 1px solid blue"
    >
    Content with mixed inline style 
    </div>
    <p id="p1" style="font-size: 16px; color: blue;">
    P with mixed inline styles
    <p class="safe">Safe CSS</p>
    </p>
    <span id="span1" style="color: purple; padding: 10px;">SPAN with only safe styles
    </span>
  </div>
    `;

document.getElementById("main").innerHTML = html;
