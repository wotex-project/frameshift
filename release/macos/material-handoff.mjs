import { stageDependencyMaterial } from '../material-handoff.mjs';
import { macImageTool } from './dmg.mjs';

export async function stageMacMaterial(args, { tool = macImageTool } = {}) {
  return stageDependencyMaterial(args, { platform: 'macos', tool });
}
