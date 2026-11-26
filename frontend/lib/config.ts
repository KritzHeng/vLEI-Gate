import { defineChain, type Address, type Chain } from "viem";
import { bscTestnet, foundry } from "viem/chains";

// NEXT_PUBLIC_* values must be referenced literally so Next.js can inline them.
export const CHAIN_ID = Number(process.env.NEXT_PUBLIC_CHAIN_ID || "97");
export const RPC_URL =
  process.env.NEXT_PUBLIC_RPC_URL ||
  (CHAIN_ID === 31337 ? "http://127.0.0.1:8545" : "https://data-seed-prebsc-1-s1.bnbchain.org:8545");
export const BACKEND_URL = (process.env.NEXT_PUBLIC_BACKEND_URL || "http://localhost:8000").replace(/\/$/, "");
/** false hides "Run a new live Cournot call" (each call spends Cournot quota); the page still shows the latest
 *  logged live result. Set NEXT_PUBLIC_COURNOT_REFRESH=false while recording or presenting. */
export const COURNOT_REFRESH_ENABLED = process.env.NEXT_PUBLIC_COURNOT_REFRESH !== "false";

const ZERO = "0x0000000000000000000000000000000000000000";
export const REGISTRY_ADDRESS = (process.env.NEXT_PUBLIC_REGISTRY_ADDRESS || ZERO) as Address;
/** v1 VLEILauncherFactory (BNB quote, contracts/deployments/<chainId>.json "factory"). Always listed on the Launches page;
 *  also the BNB/USD feed source of the KYB page when NEXT_PUBLIC_PRICE_FEED_FACTORY_ADDRESS is empty. */
export const FACTORY_ADDRESS = (process.env.NEXT_PUBLIC_FACTORY_ADDRESS || ZERO) as Address;
/** Factory whose priceFeed() the KYB page shows as the Atlas BNB/USD price (v1 or v2 BNB-quote; both expose
 *  priceFeed() and maxPriceAge()). Default FACTORY_ADDRESS. Set to the v2 BNB factory wired to AtlasSignedFeed
 *  (contracts/deployments/<chainId>-atlas.json "factory") to show the signed Atlas price. */
export const PRICE_FEED_FACTORY_ADDRESS = (process.env.NEXT_PUBLIC_PRICE_FEED_FACTORY_ADDRESS ||
  FACTORY_ADDRESS) as Address;
/** Every launcher factory the Launches page lists, primary first (comma list). The kind of each one (v1 BNB,
 *  v2 plain, v2 vault) and its quote token are read on chain. FACTORY_ADDRESS is appended if missing. */
export const FACTORY_ADDRESSES: Address[] = (() => {
  const list = (process.env.NEXT_PUBLIC_FACTORY_ADDRESSES || "")
    .split(",")
    .map((x) => x.trim())
    .filter((x) => /^0x[0-9a-fA-F]{40}$/.test(x) && x !== ZERO) as Address[];
  if (FACTORY_ADDRESS !== ZERO) list.push(FACTORY_ADDRESS);
  const seen = new Set<string>();
  return list.filter((a) => !seen.has(a.toLowerCase()) && seen.add(a.toLowerCase()));
})();
/** ERC20 quote token of the v2 factories (testnet: mock USDT with a public mint). Used to offer "Mint test USDT". */
export const QUOTE_TOKEN_ADDRESS = (process.env.NEXT_PUBLIC_QUOTE_TOKEN || ZERO) as Address;
/** Display symbol for QUOTE_TOKEN_ADDRESS (the testnet mock's on-chain symbol is "USD"); empty = read on chain. */
export const QUOTE_SYMBOL = process.env.NEXT_PUBLIC_QUOTE_SYMBOL || "";
/** Flap Portal; the same address on BNB Chain and BNB Testnet. */
export const PORTAL_ADDRESS = (process.env.NEXT_PUBLIC_PORTAL_ADDRESS ||
  "0x000042108465206185A077Edc3F3fd2b49060000") as Address;
export const ADDRESSES_CONFIGURED = REGISTRY_ADDRESS !== ZERO && FACTORY_ADDRESSES.length > 0;
/** Testnet / local chains: the mock quote token's mint(address,uint256) is offered as a faucet. */
export const IS_TESTNET = CHAIN_ID === 97 || CHAIN_ID === 31337;

function buildChain(): Chain {
  if (CHAIN_ID === 31337) {
    return defineChain({ ...foundry, name: "Anvil (local)", rpcUrls: { default: { http: [RPC_URL] } } });
  }
  if (CHAIN_ID === 97) {
    return defineChain({ ...bscTestnet, rpcUrls: { default: { http: [RPC_URL] } } });
  }
  throw new Error(`Unsupported NEXT_PUBLIC_CHAIN_ID ${CHAIN_ID} (use 97 or 31337)`);
}

export const CHAIN = buildChain();

export function txUrl(hash: string): string | null {
  return CHAIN_ID === 97 ? `https://testnet.bscscan.com/tx/${hash}` : null;
}
export function addressUrl(addr: string): string | null {
  return CHAIN_ID === 97 ? `https://testnet.bscscan.com/address/${addr}` : null;
}

export const ROLE_NAMES: Record<number, string> = {
  0: "NONE",
  1: "ECR",
  2: "OOR",
  3: "OOR_OFFICER",
};
