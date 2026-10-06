import {resolveBuild, buildIdentity} from './build.mjs';
import {resolveContext} from './context.mjs';
import {profileIdentity} from './profile.mjs';
import {mappingIdentity} from './mapping.mjs';
import {layoutIdentity} from './layout.mjs';

const failed = error => ({ok:false,error});

function snapshot(values) {
  if (!Array.isArray(values)) return failed('invalid_document');
  if (values.length > 64) return failed('invalid_count');
  const copy = [];
  for (const bytes of values) {
    if (typeof bytes !== 'string') return failed('invalid_document');
    copy.push(bytes);
  }
  return {ok:true,value:copy};
}

async function records(kind, originals, identity) {
  const output = [];
  for (const bytes of originals) {
    const result = await identity(bytes);
    if (!result.ok) return result;
    output.push(Object.freeze({kind,identity:result.identity,bytes}));
  }
  return {ok:true,value:output};
}

/** Retains exact verified v1 bytes; no successor artifact or physical acceptance is created. */
export async function v1Inputs(assembly, profiles, mappings, layouts, context) {
  if (typeof assembly !== 'string' || typeof context !== 'string') return failed('invalid_document');
  const p = snapshot(profiles), m = snapshot(mappings), l = snapshot(layouts);
  for (const result of [p,m,l]) if (!result.ok) return result;
  const documents = [assembly,context,...p.value,...m.value,...l.value];
  const lengths = documents.map(bytes => new TextEncoder().encode(bytes).length);
  if (lengths.some(length => length > 262144) || lengths.reduce((sum,length) => sum+length,0) > 4194304) {
    return failed('too_large');
  }
  const resolution = await resolveBuild(assembly,p.value);
  if (!resolution.ok) return resolution;
  if (resolution.resolution.missing.toArray().length !== 0) return failed('missing_profile');
  const resolved = await resolveContext(assembly,p.value,m.value,l.value);
  if (!resolved.ok) return resolved;
  if (resolved.canonical !== context) return failed('context_mismatch');
  const retained = [{kind:'compilation-context',identity:resolved.identity,bytes:context}];
  for (const [kind,bytes,identity] of [
    ['assembly',[assembly],buildIdentity],['component-profile',p.value,profileIdentity],
    ['signal-mapping',m.value,mappingIdentity],['artifact-layout',l.value,layoutIdentity],
  ]) {
    const result = await records(kind,bytes,identity);
    if (!result.ok) return result;
    retained.push(...result.value);
  }
  retained.sort((a,b) => a.kind < b.kind ? -1 : a.kind > b.kind ? 1 : a.identity < b.identity ? -1 : a.identity > b.identity ? 1 : 0);
  for (const record of retained) Object.freeze(record);
  return {ok:true,value:Object.freeze({format:'frameshift.conjunct.v1-inputs/1',
    assembly_identity:resolved.assembly_identity,context_identity:resolved.identity,documents:Object.freeze(retained)})};
}
