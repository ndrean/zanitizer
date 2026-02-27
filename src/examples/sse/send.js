async function testSSE() {
  for (let i = 0; i < 10; i++) {
    zxp.write("chunk " + i);
    await new Promise((r) => setTimeout(r, 200));
  }
}



testSSE();
