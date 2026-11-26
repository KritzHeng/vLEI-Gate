import { createPublicClient, http } from "viem";
import { CHAIN, CHAIN_ID, RPC_URL } from "./config";

// BSC testnet has Multicall3: batch the many view reads of the Launches page into few RPC calls.
export const publicClient = createPublicClient({
  chain: CHAIN,
  transport: http(RPC_URL),
  ...(CHAIN_ID === 97 ? { batch: { multicall: true } } : {}),
});
