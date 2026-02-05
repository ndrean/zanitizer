
import React, { useState, useMemo, useEffect } from 'react';
import { createRoot } from 'react-dom/client';

const Item = ({ value }) => {
  return <li className="item">Value: <strong>{value}</strong></li>;
};

const List = ({ onlyEven }) => {
  const allNumbers = [1, 2, 3, 4, 5, 6, 7];

  // useMemo ensures we only filter when 'onlyEven' changes
  const displayedNumbers = useMemo(() => {
    console.log(`[React] Calculating filter (Even: ${onlyEven})`);
    if (onlyEven) {
      return allNumbers.filter(n => n % 2 === 0);
    }
    return allNumbers;
  }, [onlyEven]);

  return (
    <ul id="list-container">
      {displayedNumbers.map(n => <Item key={n} value={n} />)}
    </ul>
  );
};

const App = () => {
  const [onlyEven, setOnlyEven] = useState(false);
  const [renderCount, setRenderCount] = useState(1);

  useEffect(() => {
    console.log("[React] 👍 App Mounted");
  }, []);


  return (
    <div style={{ padding: 20, fontFamily: 'sans-serif' }}>
      <h1>Zexplorer Memo Test</h1>

      {/* Control Panel */}
      <div style={{ marginBottom: 15 }}>
        <button
          id="btn-toggle"
          onClick={() => setOnlyEven(prev => !prev)}
        >
          {onlyEven ? "Show All" : "Show Even Only"}
        </button>

        <button
          id="btn-force"
          onClick={() => setRenderCount(c => c + 1)}
          style={{ marginLeft: 10 }}
        >
          Force Re-render ({renderCount})
        </button>
      </div>

      <p>Status: {onlyEven ? "Filtering Active" : "Showing All"}</p>

      {/* Nested List */}
      <List onlyEven={onlyEven} />
    </div>
  );
};

const rootNode = document.getElementById('root');
if (rootNode) {
  const root = createRoot(rootNode);
  root.render(<App />);
}
