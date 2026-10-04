// Shared Node/browser acceptance through distributed public APIs. Fixtures are
// synthetic transport/data inputs; no result is a physical qualification.
export async function exercise(kernel, data, cohort, fixtures, check) {
  const encode = value => new TextEncoder().encode(JSON.stringify(value));
  const decode = bytes => JSON.parse(new TextDecoder().decode(bytes));
  const codes = response => decode(response).diagnostics.map(item => item.code);
  const discovery = decode(await kernel.describe());
  check(discovery.protocol === cohort.protocol, 'protocol');
  check(discovery.implementation.source_revision === cohort.revision, 'source revision');
  check(discovery.contracts[0].contract.id === cohort.contract.id &&
    discovery.contracts[0].contract.digest === cohort.contract.digest, 'contract');
  check(JSON.stringify(discovery.contracts[0].profiles) === JSON.stringify(cohort.profiles), 'profiles');
  check(JSON.stringify(discovery.contracts[0].operations) === JSON.stringify(cohort.operations), 'operations');
  check(discovery.contracts[0].readable_schemas.length === cohort.readable_schemas.length &&
    cohort.readable_schemas.every((schema, index) => discovery.contracts[0].readable_schemas[index].id === schema.id &&
      discovery.contracts[0].readable_schemas[index].digest === schema.digest), 'schemas');
  const schema = 'urn:conjunct:schema:domain:0.1';
  const contracts = data.supportedContracts();
  check(contracts.operations.length === 0, 'data package adds no executable operation');
  check(cohort.readable_schemas.every(expected => contracts.schemas.some(schema =>
    schema.id === expected.id && schema.digest === expected.digest)), 'data schema digests');
  const good = data.decodeBytes(fixtures.scope, schema);
  check(good.ok, 'data reader accepts exact scope');
  const canonical = data.encodeCanonical(good.value, schema);
  check(canonical.ok, 'data writer accepts exact scope');
  const id = await data.artifactId(good.value, schema);
  check(id.ok, 'data artifact identity');
  const unsupported = data.decodeBytes(fixtures.unsupported, schema);
  check(!unsupported.ok && unsupported.errors[0].code === 'unsupported_profile', 'data refuses unsupported profile');
  const duplicate = data.decodeBytes(fixtures.duplicate, schema);
  check(!duplicate.ok && duplicate.errors[0].code === 'duplicate_key', 'escaped duplicate keys');
  const overflow = data.readRational({ n: '9223372036854775808', d: '1' });
  check(!overflow.ok && overflow.errors[0].code === 'arithmetic_overflow', 'rational overflow');
  const configuration = encode({ protocol: cohort.protocol, contract: cohort.contract, limits: cohort.limits });
  const created = await kernel.create(configuration);
  check(created.context !== null, 'context created');
  check(Object.entries(cohort.limits).every(([name, maximum]) => decode(created.response).result.limits[name] === maximum), 'effective limits');
  const loaded = await kernel.load(created.context, fixtures.scope);
  check(decode(loaded).outcome === 'completed', 'scope load');
  const refused = await kernel.load(created.context, fixtures.unsupported);
  check(codes(refused).includes('unsupported_profile'), 'kernel refuses unsupported profile');
  const malformed = await kernel.load(created.context, fixtures.duplicate);
  check(codes(malformed).includes('duplicate_key'), 'kernel refuses duplicate keys');
  const oversized = await kernel.load(created.context, new Uint8Array(cohort.limits.document_bytes + 1));
  check(decode(oversized).outcome === 'incomplete' && codes(oversized).includes('limit_exceeded'), 'document bound');
  const wrongContract = await kernel.create(encode({ protocol: cohort.protocol,
    contract: { ...cohort.contract, digest: 'sha256:' + '0'.repeat(64) }, limits: cohort.limits }));
  check(wrongContract.context === null && codes(wrongContract.response).includes('unsupported_contract'), 'unknown contract');
  await kernel.destroy(created.context);
  return { artifact_id: id.value, canonical: new TextDecoder().decode(canonical.value),
    responses: [created.response, loaded, refused, malformed, oversized, wrongContract.response]
      .map(bytes => new TextDecoder().decode(bytes)) };
}
