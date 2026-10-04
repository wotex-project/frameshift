import { WorkerKernel, type ContextRef, browserWorker } from '@conjunct/kernel';
import { decodeBytes, type DomainDocument } from '@conjunct/data';
import { renderGuide, type GuideInput } from '@conjunct/guide';

export function distributedDeclarations(module: WebAssembly.Module, bytes: Uint8Array, input: GuideInput) {
  const kernel = new WorkerKernel(browserWorker(new URL('./worker.js', import.meta.url)), module);
  const context: ContextRef = { id: 1, generation: 1 };
  const decoded = decodeBytes(bytes, 'urn:conjunct:schema:domain:0.1');
  const artifact: DomainDocument | null = decoded.ok ? decoded.value : null;
  return { kernel, context, artifact, guide: renderGuide(input) };
}
