import { WorkerKernel, browserWorker } from './bundle/js/kernel/dist/index.js';
import * as data from './bundle/js/data/dist/index.js';
import { renderGuide } from './bundle/js/guide/dist/index.js';
import { exercise } from './consumer.mjs';

const check = (value, message) => { if (!value) throw new Error(message); };
const cohort = await (await fetch('./cohort.json')).json();
const fixtures = Object.fromEntries(await Promise.all(['scope', 'unsupported', 'duplicate', 'profile-probe-source', 'present-rule', 'directed-flow-rule'].map(async name =>
  [name, new Uint8Array(await (await fetch(`./fixtures/${name}.json`)).arrayBuffer())])));
const module = await WebAssembly.compile(await (await fetch('./bundle/wasm/conjunct_abi.wasm')).arrayBuffer());
const kernel = new WorkerKernel(browserWorker(new URL('./bundle/js/kernel/dist/worker-browser.js', import.meta.url)), module,
  { maxQueue: cohort.binding.max_queue });
check(typeof renderGuide === 'function', 'guide export');
await kernel.describe();
globalThis.conjunctReady = true;
globalThis.runConjunct = async () => {
  try {
    return await exercise(kernel, data, cohort, fixtures, check);
  } finally {
    kernel.close();
  }
};
