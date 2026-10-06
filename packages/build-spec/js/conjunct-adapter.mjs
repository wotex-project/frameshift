import {
  lookup, Scope$Component, Scope$PowerPort, Scope$SignalPort, Scope$MechanicalPort,
  Property$isNumber, Property$Number$unit, Property$Number$minimum,
} from '../build/dev/javascript/frameshift_build/frameshift_build/compiler/properties.mjs';
import {Result$isOk, Result$Ok$0} from '../build/dev/javascript/prelude.mjs';

export {v1Inputs} from './v1-inputs.mjs';
export {v1Inventory} from './v1-inventory.mjs';

const scopes = new Map([
  ['component', Scope$Component()], ['power', Scope$PowerPort()],
  ['signal', Scope$SignalPort()], ['mechanical', Scope$MechanicalPort()],
]);
const conversions = new Map([
  ['um', ['length', 'm', 1000000, 0, 5000000]],
  ['mv', ['voltage', 'V', 1000, 0, 300000]],
  ['ma', ['current', 'A', 1000, 0, 100000]],
  ['mw', ['power', 'W', 1000, 0, 1000000]],
  ['g', ['mass', 'kg', 1000, 0, 100000]],
  ['ms', ['duration', 's', 1000, 0, 604800000]],
  ['count', ['count', '1', 1, 0, 1000000]],
  ['byte', ['count', '1', 1, 0, 1099511627776]],
]);
const rotations = new Map([
  [0, [1,0,0,0,1,0,0,0,1]], [90, [0,1,0,-1,0,0,0,0,1]],
  [180, [-1,0,0,0,-1,0,0,0,1]], [270, [0,-1,0,1,0,0,0,0,1]],
]);
const ok = value => ({ok: true, value});
const failed = error => ({ok: false, error});
const inRange = (lo, hi, min, max) => lo >= min && hi <= max && lo <= hi;

function rational(numerator, denominator) {
  let n = BigInt(numerator), d = BigInt(denominator);
  let a = n < 0n ? -n : n, b = d;
  while (b !== 0n) [a, b] = [b, a % b];
  n /= a; d /= a;
  return {n: String(n), d: String(d)};
}

/** Exact conversion only; the owning mapper retains the resolved source and evidence. */
export function quantity(scope, key, unit, lower, upper) {
  if (typeof scope !== 'string' || typeof key !== 'string' || typeof unit !== 'string' ||
      !Number.isInteger(lower) || !Number.isInteger(upper) || !scopes.has(scope)) {
    return failed('invalid_document');
  }
  const found = lookup(scopes.get(scope), key);
  if (!Result$isOk(found) || !Property$isNumber(Result$Ok$0(found))) return failed('unsupported_property');
  const property = Result$Ok$0(found);
  if (Property$Number$unit(property) !== unit) return failed('invalid_unit');
  const conversion = unit === 'mc'
    ? [key === 'temperature.ambient_rise' ? 'temperature-difference' : 'temperature', 'K', 1000,
      key === 'temperature.ambient_rise' ? 0 : 273150, 300000]
    : conversions.get(unit);
  if (!conversion) return failed('invalid_unit');
  const [kind, target, denominator, offset, maximum] = conversion;
  if (!inRange(lower, upper, Property$Number$minimum(property), maximum)) return failed('invalid_range');
  const value = bound => ({quantity_kind: kind, unit: target, value: rational(BigInt(bound) + BigInt(offset), denominator)});
  return ok({type: 'interval', lower: value(lower), upper: value(upper)});
}

function dimension(value) {
  if (value === null) return null;
  if (!Array.isArray(value) || value.length !== 2 || !value.every(Number.isInteger)) return 'invalid_document';
  return inRange(value[0], value[1], 1, 5000000) ? null : 'invalid_range';
}

/** Converts the rotated bare-outline origin; uncertain required dimensions remain unavailable. */
export function transform(rotation, position, width, height) {
  if (!Number.isInteger(rotation) || !Array.isArray(position) || position.length !== 3 ||
      !position.every(Number.isInteger)) return failed('invalid_document');
  if (!rotations.has(rotation) || !position.every(n => n >= 0 && n <= 5000000)) return failed('invalid_range');
  const invalid = dimension(width) ?? dimension(height);
  if (invalid) return failed(invalid);
  const needsHeight = rotation === 90 || rotation === 180;
  const needsWidth = rotation === 180 || rotation === 270;
  if ((needsHeight && (height === null || height[0] !== height[1])) ||
      (needsWidth && (width === null || width[0] !== width[1]))) return failed('unknown_geometry');
  const w = needsWidth ? width[0] : 0, h = needsHeight ? height[0] : 0;
  const offset = rotation === 90 ? [h,0,0] : rotation === 180 ? [w,h,0] : rotation === 270 ? [0,w,0] : [0,0,0];
  const [x,y,z] = position.map((value, i) => value + offset[i]);
  return ok({rotation: rotations.get(rotation).map(n => rational(n, 1)),
    translation: [x,-y,-z].map(n => rational(n, 1000000))});
}

const identifier = value => typeof value === 'string' &&
  /^[A-Za-z0-9][A-Za-z0-9._+\-]{0,95}$(?![\s\S])/.test(value);

/** Generates a successor local ID; it never changes the retained native identifier. */
export async function localId(kind, nativeId) {
  if (!identifier(kind) || !identifier(nativeId)) return failed('invalid_identifier');
  try {
    const bytes = new TextEncoder().encode(`frameshift.conjunct.local.v1\0${kind}\0${nativeId}`);
    const digest = await globalThis.crypto.subtle.digest('SHA-256', bytes);
    return ok(`v1-${Array.from(new Uint8Array(digest), n => n.toString(16).padStart(2, '0')).join('')}`);
  } catch {
    return failed('crypto_unavailable');
  }
}
