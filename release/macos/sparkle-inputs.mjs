import { isDeepStrictEqual as same } from 'node:util';
import { isSparkleInput, sparkleArchive, sparkleInputArchive, sparkleInputFramework } from '../macos-framework.mjs';

// Source receipt assertions are independently pinned by the caller. This join
// does not attest compiler execution or equate original SDK bytes with slices
// produced by thinning and signing in the final app.
export function joinSparkleInputs(material, receipt) {
  const captured = material.filter(file => isSparkleInput(file.path));
  if (!receipt) {
    if (captured.length) throw new Error('updater receipt required for captured inputs');
    return { material, updaterInputs: 0 };
  }
  const expected = [...receipt.framework.files.map(file => ({ ...file, path: sparkleInputFramework + file.path })),
    { path: sparkleInputArchive, mode: 0o600, bytes: sparkleArchive.bytes, sha256: sparkleArchive.sha256 }];
  const ordered = files => [...files].sort((a, b) => a.path.localeCompare(b.path));
  if (!same(ordered(captured), ordered(expected))) throw new Error('captured updater inputs differ from source receipt');
  return { material: material.filter(file => !isSparkleInput(file.path)), updaterInputs: captured.length };
}
