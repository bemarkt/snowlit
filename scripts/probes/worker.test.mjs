import assert from 'node:assert/strict';
import {once} from 'node:events';
import {Worker} from 'node:worker_threads';
import test from 'node:test';
import {execute} from './worker-source.mjs';

test('shared ESM fixture returns the expected data and rejects unknown workloads', async () => {
  assert.deepEqual(await execute({mode: 'normal', text: '中文 🧪'}, () => {}), {echo: '中文 🧪', sum: 6});
  await assert.rejects(execute({mode: 'unknown'}, () => {}));
});

// This checks fixture entry/termination sequencing on Node only. Safari's Worker
// API, CSP and WebContent recovery are covered separately by the iOS App test.
for (const mode of ['spin', 'never']) {
  test(`shared ${mode} workload really enters and requires explicit termination`, {timeout: 5000}, async () => {
    const source = `
      import {parentPort} from 'node:worker_threads';
      import {execute} from ${JSON.stringify(new URL('./worker-source.mjs', import.meta.url).href)};
      parentPort.on('message', () => {});
      parentPort.postMessage({kind: 'entered'});
      const result = await execute({mode: ${JSON.stringify(mode)}, token: 'fixture'}, value => parentPort.postMessage(value));
      parentPort.postMessage({kind: 'result', result});
    `;
    const worker = new Worker(new URL('data:text/javascript,' + encodeURIComponent(source)));
    let exited = false;
    let completed = false;
    worker.on('exit', () => { exited = true; });
    worker.on('message', message => { if (message.kind === 'result') completed = true; });
    try {
      const [entered] = await once(worker, 'message');
      assert.equal(entered.kind, 'entered');
      await new Promise(resolve => setTimeout(resolve, 30));
      assert.equal(completed, false);
      assert.equal(exited, false);
      await worker.terminate();
      assert.equal(exited, true);
      assert.equal(completed, false);
    } finally { await worker.terminate(); }
  });
}
