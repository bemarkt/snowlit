// Executed only in an empty host-owned document. Author code runs in the worker.
const channel = new MessageChannel();
const moduleURL = URL.createObjectURL(new Blob([source], {type: 'text/javascript'}));
const workerURL = URL.createObjectURL(new Blob([bootstrap], {type: 'text/javascript'}));
let worker;
try { worker = new Worker(workerURL, {type: 'module'}); }
catch {
  channel.port1.close(); channel.port2.close();
  URL.revokeObjectURL(workerURL); URL.revokeObjectURL(moduleURL);
  throw new Error('Source worker unavailable');
}
const state = {stopped: false, waiting: null, readyResolve: null, readyReject: null};
const ready = new Promise((resolve, reject) => { state.readyResolve = resolve; state.readyReject = reject; });
const fail = () => {
  const error = new Error('Source execution failed');
  state.readyReject?.(error); state.readyResolve = null; state.readyReject = null;
  state.waiting?.reject(error); state.waiting = null;
};
channel.port1.onmessage = ({data}) => {
  if (state.stopped) return;
  if (data.kind === 'ready') {
    state.readyResolve?.('ready'); state.readyResolve = null; state.readyReject = null;
  } else if (data.kind === 'result' && data.id === state.waiting?.id) {
    const waiting = state.waiting; state.waiting = null; waiting.resolve(data.json);
  } else if (data.kind === 'host' && data.invocation === state.waiting?.id) {
    window.webkit.messageHandlers.sourceHost.postMessage(data.json).then(json => {
      if (!state.stopped && data.invocation === state.waiting?.id) {
        channel.port1.postMessage({kind: 'hostReply', id: data.id, json});
      }
    }, () => {
      if (!state.stopped && data.invocation === state.waiting?.id) {
        channel.port1.postMessage({kind: 'hostReply', id: data.id, transportFailed: true});
      }
    });
  } else { fail(); }
};
channel.port1.start();
worker.onerror = event => { event.preventDefault(); fail(); };
// Worker global postMessage is deliberately not connected to native handlers.
// Only the port transferred before importing the author module is trusted.
globalThis.snowlitSourceWorker = {
  ready,
  invoke(json) {
    if (state.stopped || state.waiting) return Promise.reject(new Error('Source unavailable'));
    const id = JSON.parse(json).context.requestID;
    return new Promise((resolve, reject) => {
      state.waiting = {id, resolve, reject};
      channel.port1.postMessage({kind: 'invoke', id, json});
    });
  },
  stop() {
    state.stopped = true;
    worker.terminate();
    channel.port1.close();
    URL.revokeObjectURL(workerURL); URL.revokeObjectURL(moduleURL);
    fail();
    return 'terminated';
  }
};
worker.postMessage({port: channel.port2, moduleURL, requiredExports, methods}, [channel.port2]);
return await ready;
