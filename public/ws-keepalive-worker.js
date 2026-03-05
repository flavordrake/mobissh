// Web Worker keepalive (#204)
// Opens a dedicated WebSocket from the Worker thread and sends periodic
// ping messages. Worker threads are not frozen when Chrome backgrounds a tab,
// so this keeps the server aware the client is alive even when the main thread
// is suspended.
let ws = null;
let timerId = null;

function cleanup() {
  if (timerId !== null) { clearInterval(timerId); timerId = null; }
  if (ws) { try { ws.close(); } catch {} ws = null; }
}

self.onmessage = (e) => {
  if (e.data.command === 'start') {
    cleanup();
    try {
      ws = new WebSocket(e.data.url);
      ws.onopen = () => {
        timerId = setInterval(() => {
          if (ws && ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({ type: 'ping' }));
          } else {
            cleanup();
            self.postMessage('disconnected');
          }
        }, e.data.interval);
      };
      ws.onclose = () => {
        cleanup();
        self.postMessage('disconnected');
      };
      ws.onerror = () => {
        cleanup();
        self.postMessage('disconnected');
      };
      // Ignore incoming messages -- this connection is ping-only
      ws.onmessage = () => {};
    } catch {
      self.postMessage('error');
    }
  } else if (e.data.command === 'stop') {
    cleanup();
  }
};
