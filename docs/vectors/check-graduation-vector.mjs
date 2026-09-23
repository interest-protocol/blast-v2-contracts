import { readFileSync } from "node:fs";

const BASIS_POINTS_DENOMINATOR = 10_000n;
const MAX_MIGRATION_CHANNELS = 16;
const MAX_PROTOCOL_MEME_BPS = 9_998n;
const MAX_PROTOCOL_QUOTE_BPS = 9_999n;
const MAX_U64 = (1n << 64n) - 1n;
const vectorUrl = new URL("./graduation.json", import.meta.url);
const source = readFileSync(vectorUrl, "utf8");
const vectors = JSON.parse(source);

function fail(message) {
  throw new Error(message);
}

function assertEqual(name, actual, expected) {
  if (actual !== expected) {
    fail(`${name}: expected ${expected}, got ${actual}`);
  }
}

function asU64(name, value) {
  const parsed = BigInt(value);
  if (parsed < 0n || parsed > MAX_U64) {
    fail(`${name}: ${value} is outside u64`);
  }
  return parsed;
}

function canonicalByChannelId(entries) {
  return entries
    .map((entry) => ({ ...entry, channel_id: asU64("channel_id", entry.channel_id) }))
    .sort((a, b) => (a.channel_id < b.channel_id ? -1 : a.channel_id > b.channel_id ? 1 : 0));
}

function assertUnique(name, entries) {
  for (let index = 1; index < entries.length; index += 1) {
    if (entries[index - 1].channel_id === entries[index].channel_id) {
      fail(`${name}: duplicate channel ${entries[index].channel_id}`);
    }
  }
}

function canonicalPlan(name, given) {
  const channels = canonicalByChannelId(given.channels);
  const meme = canonicalByChannelId(given.meme_weights);
  const quote = canonicalByChannelId(given.quote_weights);

  if (channels.length > MAX_MIGRATION_CHANNELS) {
    fail(`${name}: too many migration channels`);
  }
  assertUnique(`${name}.channels`, channels);
  assertUnique(`${name}.meme_weights`, meme);
  assertUnique(`${name}.quote_weights`, quote);

  const knownIds = new Set(channels.map(({ channel_id }) => channel_id.toString()));
  let liquidityCount = 0;
  let protocolCount = 0;
  for (const channel of channels) {
    if (channel.channel_id === 0n || channel.destination === "0x0") {
      fail(`${name}: named channels require a nonzero ID and destination`);
    }
    if (!['Liquidity', 'Protocol', 'External'].includes(channel.role)) {
      fail(`${name}: unknown role ${channel.role}`);
    }
    liquidityCount += Number(channel.role === "Liquidity");
    protocolCount += Number(channel.role === "Protocol");
  }
  assertEqual(`${name}.liquidity_count`, liquidityCount, 1);
  if (protocolCount > 1) fail(`${name}: more than one protocol channel`);

  function validateTable(asset, table, allowCurve) {
    let sum = 0n;
    for (const entry of table) {
      const bps = asU64(`${name}.${asset}.bps`, entry.bps);
      if (bps === 0n) fail(`${name}.${asset}: zero-weight entries must be omitted`);
      if (entry.channel_id === 0n ? !allowCurve : !knownIds.has(entry.channel_id.toString())) {
        fail(`${name}.${asset}: unknown channel ${entry.channel_id}`);
      }
      sum += bps;
      entry.bps = bps;
    }
    assertEqual(`${name}.${asset}.sum`, sum, BASIS_POINTS_DENOMINATOR);
  }

  validateTable("meme", meme, true);
  validateTable("quote", quote, false);
  if (!meme.some(({ channel_id }) => channel_id === 0n)) {
    fail(`${name}: Meme table must allocate a positive curve share`);
  }

  for (const channel of channels) {
    const memeBps = meme.find(({ channel_id }) => channel_id === channel.channel_id)?.bps ?? 0n;
    const quoteBps = quote.find(({ channel_id }) => channel_id === channel.channel_id)?.bps ?? 0n;
    if (memeBps === 0n && quoteBps === 0n) fail(`${name}: unused named channel ${channel.channel_id}`);
    if (channel.role === "Liquidity" && (memeBps === 0n || quoteBps === 0n)) {
      fail(`${name}: liquidity channel must participate in both tables`);
    }
  }

  const policy = {
    ...given.protocol_policy,
    channel_id: asU64(`${name}.protocol_policy.channel_id`, given.protocol_policy.channel_id),
    meme_bps: asU64(`${name}.protocol_policy.meme_bps`, given.protocol_policy.meme_bps),
    quote_bps: asU64(`${name}.protocol_policy.quote_bps`, given.protocol_policy.quote_bps),
  };
  if (
    policy.channel_id === 0n ||
    policy.destination === "0x0" ||
    policy.meme_bps > MAX_PROTOCOL_MEME_BPS ||
    policy.quote_bps > MAX_PROTOCOL_QUOTE_BPS
  ) {
    fail(`${name}: invalid one-time protocol policy`);
  }
  const protocol = channels.find(({ role }) => role === "Protocol");
  const policyIsZero = policy.meme_bps === 0n && policy.quote_bps === 0n;
  if (policyIsZero !== !protocol) fail(`${name}: zero/zero policy must omit the protocol channel`);
  if (protocol) {
    assertEqual(`${name}.protocol.channel_id`, protocol.channel_id, policy.channel_id);
    assertEqual(`${name}.protocol.destination`, protocol.destination, policy.destination);
    assertEqual(
      `${name}.protocol.meme_bps`,
      meme.find(({ channel_id }) => channel_id === protocol.channel_id)?.bps ?? 0n,
      policy.meme_bps,
    );
    assertEqual(
      `${name}.protocol.quote_bps`,
      quote.find(({ channel_id }) => channel_id === protocol.channel_id)?.bps ?? 0n,
      policy.quote_bps,
    );
  }

  return { channels, meme, quote, protocol };
}

function apportion(name, total, table, protectedId) {
  const amounts = table.map((entry) => {
    const product = total * entry.bps;
    const protectedEntry = entry.channel_id === protectedId;
    return {
      channel_id: entry.channel_id,
      amount: protectedEntry
        ? (product + BASIS_POINTS_DENOMINATOR - 1n) / BASIS_POINTS_DENOMINATOR
        : product / BASIS_POINTS_DENOMINATOR,
      remainder: product % BASIS_POINTS_DENOMINATOR,
      protected: protectedEntry,
    };
  });
  const allocated = amounts.reduce((sum, { amount }) => sum + amount, 0n);
  const residue = total - allocated;
  const ranked = amounts
    .filter(({ protected: protectedEntry }) => !protectedEntry)
    .sort((a, b) => {
      if (a.remainder !== b.remainder) return a.remainder > b.remainder ? -1 : 1;
      return a.channel_id < b.channel_id ? -1 : 1;
    });
  if (residue < 0n || residue > BigInt(ranked.length)) {
    fail(`${name}: residue ${residue} cannot be assigned once per unprotected entry`);
  }
  for (let index = 0; index < Number(residue); index += 1) ranked[index].amount += 1n;
  assertEqual(
    `${name}.conservation`,
    amounts.reduce((sum, { amount }) => sum + amount, 0n),
    total,
  );
  return amounts.sort((a, b) => (a.channel_id < b.channel_id ? -1 : 1));
}

function assertAllocation(name, actual, expected) {
  assertEqual(`${name}.length`, actual.length, expected.length);
  actual.forEach((entry, index) => {
    assertEqual(`${name}[${index}].channel_id`, entry.channel_id, BigInt(expected[index].channel_id));
    assertEqual(`${name}[${index}].amount`, entry.amount, BigInt(expected[index].amount));
  });
}

assertEqual("deterministic JSON formatting", source, `${JSON.stringify(vectors, null, 2)}\n`);
assertEqual("schema_version", vectors.schema_version, 4);
assertEqual(
  "top-level keys",
  Object.keys(vectors).join(","),
  "schema_version,description,source_decisions,units,parameters,policy,formulas,payout_semantics,cases,properties",
);
assertEqual(
  "payout_semantics keys",
  Object.keys(vectors.payout_semantics).join(","),
  "liquidity,non_liquidity,fees",
);
assertEqual("basis_points_denominator", BigInt(vectors.parameters.basis_points_denominator), 10_000n);
assertEqual("maximum_migration_channels", vectors.parameters.maximum_migration_channels, 16);
assertEqual(
  "maximum_protocol_meme_bps",
  BigInt(vectors.parameters.maximum_protocol_meme_bps),
  MAX_PROTOCOL_MEME_BPS,
);
assertEqual(
  "maximum_protocol_quote_bps",
  BigInt(vectors.parameters.maximum_protocol_quote_bps),
  MAX_PROTOCOL_QUOTE_BPS,
);
assertEqual(
  "source_decisions",
  vectors.source_decisions.join(","),
  [
    "docs/decisions/0039-deterministic-quote-valuations.md",
    "docs/decisions/0088-reusable-launch-accounting-and-atomic-migration.md",
  ].join(","),
);
assertEqual("policy.mutability", vectors.policy.mutability, "single-write");

const expectedCases = [
  "recommended_sui_lane",
  "protected_first_and_remainder_order",
  "unprotected_channel_id_tie",
  "maximum_protocol_policy",
  "maximum_u64_width",
];
assertEqual("case names", vectors.cases.map(({ name }) => name).join(","), expectedCases.join(","));

for (const testCase of vectors.cases) {
  const plan = canonicalPlan(testCase.name, testCase.given);
  assertEqual(
    `${testCase.name}.canonical_channel_ids`,
    plan.channels.map(({ channel_id }) => channel_id.toString()).join(","),
    testCase.expect.canonical_channel_ids.join(","),
  );
  const protectedId = plan.protocol?.channel_id;
  const meme = apportion(
    `${testCase.name}.meme`,
    asU64(`${testCase.name}.total_meme`, testCase.given.total_meme),
    plan.meme,
    protectedId,
  );
  const quote = apportion(
    `${testCase.name}.quote`,
    asU64(`${testCase.name}.total_quote`, testCase.given.total_quote),
    plan.quote,
    protectedId,
  );
  assertAllocation(`${testCase.name}.meme_allocations`, meme, testCase.expect.meme_allocations);
  assertAllocation(`${testCase.name}.quote_allocations`, quote, testCase.expect.quote_allocations);

  const protocolMeme = meme.find(({ channel_id }) => channel_id === protectedId)?.amount ?? 0n;
  const protocolQuote = quote.find(({ channel_id }) => channel_id === protectedId)?.amount ?? 0n;
  assertEqual(
    `${testCase.name}.protocol_meme_paid`,
    protocolMeme,
    BigInt(testCase.expect.protocol_paid_at_migration.meme),
  );
  assertEqual(
    `${testCase.name}.protocol_quote_paid`,
    protocolQuote,
    BigInt(testCase.expect.protocol_paid_at_migration.quote),
  );
}

const recommended = vectors.cases[0];
assertEqual("recommended.total_meme", BigInt(recommended.given.total_meme), 1_000_000_000_000_000_000n);
assertEqual("recommended.total_quote", BigInt(recommended.given.total_quote), 8_000_000_000_000n);
assertEqual("recommended.curve_meme", BigInt(recommended.expect.meme_allocations[0].amount), 800_000_000_000_000_000n);
assertEqual("recommended.liquidity_meme", BigInt(recommended.expect.meme_allocations[1].amount), 200_000_000_000_000_000n);
assertEqual("recommended.liquidity_quote", BigInt(recommended.expect.quote_allocations[0].amount), 8_000_000_000_000n);
const recommendedCurveMeme = BigInt(recommended.expect.meme_allocations[0].amount);
const recommendedLiquidityMeme = BigInt(recommended.expect.meme_allocations[1].amount);
const recommendedVirtualQuote = BigInt(recommended.given.virtual_quote);
const recommendedTargetQuote = BigInt(recommended.given.graduation_target);
const terminalCurveMeme =
  (recommendedCurveMeme * recommendedVirtualQuote + recommendedVirtualQuote + recommendedTargetQuote - 1n) /
  (recommendedVirtualQuote + recommendedTargetQuote);
assertEqual("recommended.terminal_curve_meme", terminalCurveMeme, BigInt(recommended.expect.terminal_curve_meme));
assertEqual(
  "recommended.curve_meme_released",
  recommendedCurveMeme - terminalCurveMeme,
  BigInt(recommended.expect.curve_meme_released),
);
assertEqual(
  "recommended.opening_valuation",
  (BigInt(recommended.given.total_meme) * recommendedVirtualQuote) / recommendedCurveMeme,
  BigInt(recommended.expect.opening_valuation),
);
assertEqual(
  "recommended.curve_terminal_valuation",
  (BigInt(recommended.given.total_meme) * (recommendedVirtualQuote + recommendedTargetQuote)) /
    terminalCurveMeme,
  BigInt(recommended.expect.curve_terminal_valuation),
);
assertEqual(
  "recommended.dex_opening_valuation",
  (BigInt(recommended.given.total_meme) * BigInt(recommended.given.total_quote)) /
    recommendedLiquidityMeme,
  BigInt(recommended.expect.dex_opening_valuation),
);

console.log("canonical allocation vector check passed");
