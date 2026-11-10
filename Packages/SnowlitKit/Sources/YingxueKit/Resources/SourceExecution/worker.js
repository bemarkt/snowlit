// Trusted bootstrap. Author code receives ctx, never this private message port.
(() => {
  const listen = addEventListener.bind(globalThis);
  const unlisten = removeEventListener.bind(globalThis);
  const parse = JSON.parse.bind(JSON);
  const stringify = JSON.stringify.bind(JSON);
  const freeze = Object.freeze.bind(Object);
  const PromiseType = Promise;
  let initialized = false;
  async function initialize(event) {
    if (initialized) return;
    initialized = true;
    unlisten('message', initialize);
    const {port, moduleURL, requiredExports, methods} = event.data;
    const send = port.postMessage.bind(port);
    const pending = new Map();
    let module, active = null, sequence = 0;
    // These constructors must be sealed before author top-level code runs.
    for (const name of ['Worker', 'SharedWorker']) {
      Object.defineProperty(globalThis, name, {value: undefined, writable: false, configurable: false});
    }
    const unavailable = () => ({code: 'resourceFailure', stage: 'execute', retryable: true});
    port.onmessage = async ({data}) => {
      if (data.kind === 'hostReply') {
        const waiter = pending.get(data.id);
        if (!waiter) return;
        pending.delete(data.id);
        try {
          if (data.transportFailed) throw unavailable();
          const reply = parse(data.json);
          if (reply.kind === 'failure') waiter.reject(reply.error);
          else waiter.resolve(reply.value);
        } catch { waiter.reject(unavailable()); }
        return;
      }
      if (data.kind !== 'invoke' || active !== null || !module) {
        send({kind: 'failed'}); return;
      }
      active = data.id;
      const invocation = active;
      try {
        const call = parse(data.json);
        const context = freeze(call.context);
        const ctx = {identity: context};
        for (const method of methods) {
          ctx[method] = input => new PromiseType((resolve, reject) => {
            if (active !== invocation) { reject(unavailable()); return; }
            const id = (++sequence).toString(16).padStart(8, '0') + '-0000-0000-0000-000000000000';
            const json = stringify({id, context, request: {kind: method, input}});
            pending.set(id, {resolve, reject, invocation});
            send({kind: 'host', id, invocation, json});
          });
        }
        freeze(ctx);
        let reply;
        try {
          const configuration = await ctx.readConfiguration({});
          if (configuration.revision !== context.configurationRevision) {
            throw {code: 'stale', stage: 'execute', retryable: true};
          }
          const value = await module[call.request.kind](ctx, call.request.input);
          reply = {kind: call.request.kind, context, value};
        } catch (error) {
          // Raw errors may contain credentials or page text. Only contract
          // categories cross the bridge; native validation checks these too.
          reply = {kind: 'failure', context, operation: call.request.kind,
            error: {code: error?.code ?? 'invalidData', stage: error?.stage ?? 'execute',
              retryable: error?.retryable ?? false}};
        }
        // Returning while a host action is unowned is an invalid invocation.
        if (pending.size) throw unavailable();
        send({kind: 'result', id: invocation, json: stringify(reply)});
      } catch { send({kind: 'failed', id: invocation}); }
      finally {
        active = null;
        for (const [id, waiter] of pending) {
          if (waiter.invocation === invocation) { pending.delete(id); waiter.reject(unavailable()); }
        }
      }
    };
    port.start();
    try {
      module = await import(moduleURL);
      if (!requiredExports.every(name => typeof module[name] === 'function')) throw unavailable();
      send({kind: 'ready'});
    } catch { send({kind: 'failed'}); }
  }
  listen('message', initialize);
})();
