import { readFileSync } from "node:fs";

const BASIS_POINTS_DENOMINATOR = 10_000n;

const vector = JSON.parse(
  readFileSync(new URL("./graduation.json", import.meta.url), "utf8"),
).cases.find(({ name }) => name === "recommended_sui_lane");

if (!vector) {
  throw new Error("recommended_sui_lane is missing");
}

const given = Object.fromEntries(
  Object.entries(vector.given).map(([key, value]) => [key, BigInt(value)]),
);
const expected = Object.fromEntries(
  Object.entries(vector.expect).map(([key, value]) => [key, BigInt(value)]),
);

function assertEqual(name, actual, expectedValue) {
  if (actual !== expectedValue) {
    throw new Error(`${name}: expected ${expectedValue}, got ${actual}`);
  }
}

function ceilDiv(numerator, denominator) {
  return (numerator + denominator - 1n) / denominator;
}

assertEqual("initial_meme_supply", given.initial_meme_supply, 1_000_000_000_000_000_000n);
assertEqual("virtual_quote", given.virtual_quote, 8_000_000_000_000n);
assertEqual("migration_quote_target", given.migration_quote_target, 8_000_000_000_000n);
assertEqual("protocol_meme_graduation_fee_bps", given.protocol_meme_graduation_fee_bps, 0n);
assertEqual("meme_liquidity_provision_bps", given.meme_liquidity_provision_bps, 2_000n);
assertEqual("quote_migration_fee_bps", given.quote_migration_fee_bps, 0n);

const protocolMemeGraduationFee = ceilDiv(
  given.initial_meme_supply * given.protocol_meme_graduation_fee_bps,
  BASIS_POINTS_DENOMINATOR,
);
const memeLiquidityProvision =
  (given.initial_meme_supply * given.meme_liquidity_provision_bps) /
  BASIS_POINTS_DENOMINATOR;
const curveInventory =
  given.initial_meme_supply - protocolMemeGraduationFee - memeLiquidityProvision;
const quoteMigrationFee = ceilDiv(
  given.migration_quote_target * given.quote_migration_fee_bps,
  BASIS_POINTS_DENOMINATOR,
);
const netQuote = given.migration_quote_target - quoteMigrationFee;
const terminalCurveMeme = ceilDiv(
  curveInventory * given.virtual_quote,
  given.virtual_quote + given.migration_quote_target,
);

assertEqual("curve_inventory", given.curve_inventory, curveInventory);
assertEqual("meme_liquidity_provision", given.meme_liquidity_provision, memeLiquidityProvision);
assertEqual("terminal_curve_meme", terminalCurveMeme, expected.terminal_curve_meme);
assertEqual("curve_meme_released", curveInventory - terminalCurveMeme, expected.curve_meme_released);
assertEqual("quote_migration_fee", quoteMigrationFee, expected.quote_migration_fee);
assertEqual("net_quote", netQuote, expected.net_quote);
assertEqual(
  "opening_valuation",
  (given.initial_meme_supply * given.virtual_quote) / curveInventory,
  expected.opening_valuation,
);
assertEqual(
  "curve_terminal_valuation",
  (given.initial_meme_supply * (given.virtual_quote + given.migration_quote_target)) /
    terminalCurveMeme,
  expected.curve_terminal_valuation,
);
assertEqual(
  "dex_opening_valuation",
  (given.initial_meme_supply * netQuote) / memeLiquidityProvision,
  expected.dex_opening_valuation,
);

console.log("recommended_sui_lane vector check passed");
