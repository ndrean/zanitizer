console.time("Total");
const jsdom = require("jsdom");
const { JSDOM } = jsdom;
const fs = require("fs");

const html = fs.readFileSync("bench.html", "utf8");
const dom = new JSDOM(html, { runScripts: "dangerously" });
console.timeEnd("Total");
