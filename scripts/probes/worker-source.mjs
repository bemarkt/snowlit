// Synthetic ESM workload shared by the native Worker probe and local fixture tests.
export const constructorsAtLoad = typeof Worker + '/' + typeof SharedWorker;

export async function execute(input, notify) {
  if (input.mode === 'spin') {
    let count = 0;
    for (;;) {
      if (++count % 1_000_000 === 0) notify({kind: 'pulse', token: input.token});
    }
  }
  if (input.mode === 'never') return new Promise(() => {});
  if (input.mode === 'network') {
    try { await fetch(input.url); return {blocked: false}; }
    catch { return {blocked: true}; }
  }
  if (input.mode === 'normal') return {echo: input.text, sum: [1, 2, 3].reduce((a, b) => a + b, 0)};
  throw new Error('Unknown synthetic worker mode');
}
