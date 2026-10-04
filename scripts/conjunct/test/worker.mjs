import { parentPort } from 'node:worker_threads';
import { serve } from '@conjunct/kernel';
serve({ post: (message, transfer) => parentPort.postMessage(message, transfer),
  listen: callback => parentPort.on('message', callback) });
