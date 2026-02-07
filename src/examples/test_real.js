const js = `
  <div>
    <div
    class="safe"
    style="background: expression(evil()); border: 1px solid blue"
    >
    Content with mixed inline style 
    </div>
    <p id="p1" style="font-size: 16px; behavior: url(evil.htc); margin: 5px;">
    P with mixed inline styles
    </p>
    <span id="span1" style="color: purple; padding: 10px;">SPAN with only safe styles
    </span>
  </div>
    `;

document.getElementById("main").innerHTML = js;
