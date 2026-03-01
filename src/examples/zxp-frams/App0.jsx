
import React, { useState, useMemo, useEffect } from 'react';
import { createRoot } from 'react-dom/client';

console.log(typeof createRoot);

const App = () => {
  console.log("[React] In App()");


  useEffect(() => {
    console.log("[React] 👍 App Mounted");
  }, []);

  return (
    <div>Hi</div>
  );
};

const rootNode = document.getElementById('root');
if (rootNode) {
  console.log("[React] About to mount");
  const root = createRoot(rootNode);
  root.render(<App />);
  console.log("[React] Mounted");
}
