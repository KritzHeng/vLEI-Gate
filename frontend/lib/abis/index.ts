import type { Abi } from "viem";
import { registryAbi } from "./VLEIRegistry";
import { factoryAbi } from "./VLEILauncherFactory";
import { launcherAbi } from "./VLEIMintLauncher";
import { vaultLauncherV2Abi } from "./VLEIMintVaultLauncherV2";
import { vaultLauncherFactoryV2Abi } from "./VLEIVaultLauncherFactoryV2";
import { launcherFactoryV2Abi } from "./VLEILauncherFactoryV2";
import { vaultV2Abi } from "./VLEIDividendVaultV2";
import { erc20Abi } from "./ERC20";

export { registryAbi, factoryAbi, launcherAbi, vaultLauncherV2Abi, vaultLauncherFactoryV2Abi, launcherFactoryV2Abi, vaultV2Abi, erc20Abi };

/** Aggregator-style BNB/USD feed (Atlas, or MockPriceFeed on a fork / testnet). */
export const priceFeedAbi = [
  { type: "function", name: "description", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "string" }] },
  { type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "uint8" }] },
  {
    type: "function",
    name: "latestRoundData",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "roundId", type: "uint80" },
      { name: "answer", type: "int256" },
      { name: "startedAt", type: "uint256" },
      { name: "updatedAt", type: "uint256" },
      { name: "answeredInRound", type: "uint80" },
    ],
  },
] as const;

/** The few Flap Portal functions this app reads (subset of flap/IPortal.sol). */
export const portalAbi = [
  { type: "function", name: "SALT_LOCK_FEE", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "uint256" }] },
  { type: "function", name: "version", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "string" }] },
  {
    type: "function",
    name: "launcherFactoryMultiplier",
    stateMutability: "view",
    inputs: [{ name: "factory", type: "address" }],
    outputs: [
      { name: "enabled", type: "bool" },
      { name: "multiplierBps", type: "uint16" },
    ],
  },
] as const;


/** Every custom error of the registry, factories, launchers and vault (deduplicated by name), used to decode
 *  reverts that bubble up through nested calls, e.g. CreatorNotAuthorized inside Portal.newLauncher(). */
const seen = new Set<string>();
export const allErrorsAbi = ([
  ...launcherAbi,
  ...factoryAbi,
  ...registryAbi,
  ...vaultLauncherV2Abi,
  ...vaultLauncherFactoryV2Abi,
  ...launcherFactoryV2Abi,
  ...vaultV2Abi,
] as Abi).filter((item) => {
  if (item.type !== "error") return false;
  if (seen.has(item.name)) return false;
  seen.add(item.name);
  return true;
}) as Abi;

/** Contract ABI plus the custom errors of the other contracts. */
export function withAllErrors(abi: Abi): Abi {
  const names = new Set(abi.filter((i) => i.type === "error").map((i) => (i as { name: string }).name));
  return [...abi, ...allErrorsAbi.filter((e) => !names.has((e as { name: string }).name))];
}
