import { stageDependencyMaterial } from '../material-handoff.mjs';

export async function stageLinuxMaterial(args, { tool } = {}) {
  return stageDependencyMaterial(args, { platform: 'ubuntu', tool });
}
