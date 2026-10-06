import {v1Inputs} from './v1-inputs.mjs';

function freeze(value) {
  if (value !== null && typeof value === 'object') {
    for (const child of Object.values(value)) freeze(child);
    Object.freeze(value);
  }
  return value;
}

function describe(value) {
  if (Array.isArray(value)) return [{type:'array',length:value.length},value.map((child,index) => [String(index),child])];
  if (value !== null && typeof value === 'object') {
    const keys = Object.keys(value).sort();
    return [{type:'object',keys},keys.map(key => [key,value[key]])];
  }
  return [value === null ? {type:'null'} : {type:typeof value === 'number' ? 'integer' : typeof value,value},[]];
}

function enumerate(documents) {
  const nodes = [];
  function visit(value, pointer, document) {
    if (nodes.length === 10000) return false;
    const [descriptor,children] = describe(value);
    const id = document.kind+'@'+document.identity+'#'+pointer;
    nodes.push({id,document_kind:document.kind,document_identity:document.identity,pointer,value:descriptor});
    for (const [key,child] of children) {
      const token = key.replace(/~/g,'~0').replace(/\//g,'~1');
      if (!visit(child,pointer+'/'+token,document)) return false;
    }
    return true;
  }
  for (const document of documents) if (!visit(JSON.parse(document.bytes),'',document)) return null;
  nodes.sort((a,b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
  return nodes;
}

/** Inventories original syntax only; no physical successor or permission is created. */
export async function v1Inventory(assembly, profiles, mappings, layouts, context) {
  const retained = await v1Inputs(assembly,profiles,mappings,layouts,context);
  if (!retained.ok) return retained;
  const inputs = retained.value,nodes = enumerate(inputs.documents);
  if (nodes === null) return {ok:false,error:'too_many_concepts'};
  const inventory = {
    artifact:{reference:inputs.context_identity,format:'frameshift.compilation',version:'1'},
    coverage_scope:'frameshift/v1-closure-json-nodes/1',complete:true,
    concepts:nodes.map(node => ({id:node.id,locator:node.id,requirements:['CJ1-07','CJ3-11']})),
  };
  return {ok:true,value:freeze({format:'frameshift.conjunct.v1-inventory/1',inputs,inventory,nodes})};
}
