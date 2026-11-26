// On-chain reads for the Launches page (no React): factories (v1 BNB, v2 plain, v2 vault), launchers, vaults.
import { zeroAddress, type Address } from "viem";
import {
  erc20Abi,
  factoryAbi,
  launcherAbi,
  launcherFactoryV2Abi,
  portalAbi,
  vaultLauncherFactoryV2Abi,
  vaultLauncherV2Abi,
  vaultV2Abi,
} from "./abis";
import { publicClient } from "./clients";
import { FACTORY_ADDRESSES, PORTAL_ADDRESS, QUOTE_SYMBOL, QUOTE_TOKEN_ADDRESS } from "./config";

/** v1 = VLEILauncherFactory (BNB, Flap dividend tracker); v2 = VLEILauncherFactoryV2 (quote dividend via Flap tracker);
 *  vault-v2 = VLEIVaultLauncherFactoryV2 (tax yield to the gated VLEIDividendVaultV2). */
export type FactoryKind = "v1" | "v2" | "vault-v2";
export type Quote = { address: Address; symbol: string; native: boolean };

export type FactoryView = {
  address: Address;
  kind: FactoryKind;
  quote: Quote;
  portalEnabled: boolean | null;
  launchers: readonly Address[];
};

export type Mine = {
  contribution: bigint;
  claimable: bigint;
  remainingCapUsd: bigint;
  maxContribution: bigint;
  vleiStatus: number;
  tokenBalance: bigint;
  /** Quote balance / allowance to the launcher / what a no-arg contribute() pulls now (v2 only; v1: BNB balance, max, max). */
  quoteBalance: bigint;
  quoteAllowance: bigint;
  previewContribute: bigint | null;
};

export type VaultView = {
  address: Address;
  taxToken: Address;
  totalRevenue: bigint;
  totalClaimed: bigint;
  totalForfeited: bigint;
  totalStaked: bigint;
  undistributed: bigint;
  minStake: bigint;
  heldReleaseMinStake: bigint;
  mine: {
    stakedOf: bigint;
    claimable: bigint;
    canClaim: boolean;
    isEarning: boolean;
    evictable: boolean;
    tokenBalance: bigint;
    tokenAllowance: bigint;
  } | null;
};

export type LaunchView = {
  address: Address;
  factory: Address;
  kind: FactoryKind;
  quote: Quote;
  name: string;
  symbol: string;
  status: number;
  raised: bigint;
  target: bigint;
  deadline: bigint;
  capUsdPerEntity: bigint;
  token: Address;
  pool: Address;
  creator: Address;
  creatorActive: boolean;
  vault: VaultView | null;
  mine: Mine | null;
};

const NATIVE: Quote = { address: zeroAddress, symbol: "BNB", native: true };
const symbolCache = new Map<string, Promise<string>>();
function quoteOf(address: Address): Promise<Quote> {
  if (address === zeroAddress) return Promise.resolve(NATIVE);
  const key = address.toLowerCase();
  if (QUOTE_SYMBOL && key === QUOTE_TOKEN_ADDRESS.toLowerCase()) return Promise.resolve({ address, symbol: QUOTE_SYMBOL, native: false });
  if (!symbolCache.has(key)) {
    symbolCache.set(
      key,
      publicClient.readContract({ address, abi: erc20Abi, functionName: "symbol" }).catch(() => "QUOTE"),
    );
  }
  return symbolCache.get(key)!.then((symbol) => ({ address, symbol, native: false }));
}

/** Detects the factory kind on chain: v1 has no quoteToken(); only the vault factory has vaultFactory(). */
export async function loadFactory(address: Address): Promise<FactoryView> {
  let kind: FactoryKind = "v1";
  let quoteAddr: Address = zeroAddress;
  try {
    quoteAddr = await publicClient.readContract({ address, abi: launcherFactoryV2Abi, functionName: "quoteToken" });
    kind = "v2";
    try {
      await publicClient.readContract({ address, abi: vaultLauncherFactoryV2Abi, functionName: "vaultFactory" });
      kind = "vault-v2";
    } catch {
      /* plain v2 */
    }
  } catch {
    /* v1 */
  }
  const [quote, launchers, portalEnabled] = await Promise.all([
    quoteOf(quoteAddr),
    publicClient.readContract({ address, abi: factoryAbi, functionName: "getLaunchers" }),
    publicClient
      .readContract({ address: PORTAL_ADDRESS, abi: portalAbi, functionName: "launcherFactoryMultiplier", args: [address] })
      .then(([en]) => en)
      .catch(() => null),
  ]);
  return { address, kind, quote, portalEnabled, launchers };
}

export async function loadVault(vault: Address, account: Address | null): Promise<VaultView> {
  const V = { address: vault, abi: vaultV2Abi } as const;
  const [taxToken, totalRevenue, totalClaimed, totalForfeited, totalStaked, undistributed, minStake, heldReleaseMinStake] =
    await Promise.all([
      publicClient.readContract({ ...V, functionName: "taxToken" }),
      publicClient.readContract({ ...V, functionName: "totalRevenue" }),
      publicClient.readContract({ ...V, functionName: "totalClaimed" }),
      publicClient.readContract({ ...V, functionName: "totalForfeited" }),
      publicClient.readContract({ ...V, functionName: "totalStaked" }),
      publicClient.readContract({ ...V, functionName: "undistributed" }),
      publicClient.readContract({ ...V, functionName: "MIN_STAKE" }),
      publicClient.readContract({ ...V, functionName: "HELD_RELEASE_MIN_STAKE" }),
    ]);
  let mine: VaultView["mine"] = null;
  if (account) {
    const [stakedOf, claimable, canClaim, isEarning, evictable, tokenBalance, tokenAllowance] = await Promise.all([
      publicClient.readContract({ ...V, functionName: "stakedOf", args: [account] }),
      publicClient.readContract({ ...V, functionName: "claimable", args: [account] }),
      publicClient.readContract({ ...V, functionName: "canClaim", args: [account] }),
      publicClient.readContract({ ...V, functionName: "isEarning", args: [account] }),
      publicClient.readContract({ ...V, functionName: "evictable", args: [account] }),
      publicClient.readContract({ address: taxToken, abi: erc20Abi, functionName: "balanceOf", args: [account] }),
      publicClient.readContract({ address: taxToken, abi: erc20Abi, functionName: "allowance", args: [account, vault] }),
    ]);
    mine = { stakedOf, claimable, canClaim, isEarning, evictable, tokenBalance, tokenAllowance };
  }
  return {
    address: vault,
    taxToken,
    totalRevenue,
    totalClaimed,
    totalForfeited,
    totalStaked,
    undistributed,
    minStake,
    heldReleaseMinStake,
    mine,
  };
}

export async function loadLaunch(address: Address, f: FactoryView, account: Address | null): Promise<LaunchView> {
  const v2 = f.kind !== "v1";
  // v2 launchers share one base; the vault launcher ABI is a superset of the plain one (vault() only on vault-v2).
  const L = { address, abi: v2 ? vaultLauncherV2Abi : launcherAbi } as const;
  const [info, name, symbol, creatorActive, vaultAddr] = await Promise.all([
    publicClient.readContract({ ...L, functionName: "saleInfo" }),
    publicClient.readContract({ ...L, functionName: "name" }),
    publicClient.readContract({ ...L, functionName: "symbol" }),
    publicClient.readContract({ ...L, functionName: "creatorActive" }),
    f.kind === "vault-v2"
      ? publicClient.readContract({ address, abi: vaultLauncherV2Abi, functionName: "vault" })
      : Promise.resolve(zeroAddress as Address),
  ]);
  const [status, raised, target, deadline, capUsdPerEntity, token, pool, creator] = info;
  let mine: Mine | null = null;
  if (account) {
    const [contribution, claimable, remainingCapUsd, maxContribution, vleiStatus, tokenBalance] = await Promise.all([
      publicClient.readContract({ ...L, functionName: "contributionOf", args: [account] }),
      publicClient.readContract({ ...L, functionName: "claimableOf", args: [account] }),
      publicClient.readContract({ ...L, functionName: "remainingCapUsd", args: [account] }),
      publicClient.readContract({ ...L, functionName: "maxContribution", args: [account] }),
      publicClient.readContract({ ...L, functionName: "vleiStatusOf", args: [account] }),
      token === zeroAddress
        ? Promise.resolve(0n)
        : publicClient.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [account] }),
    ]);
    let quoteBalance: bigint;
    let quoteAllowance: bigint;
    let previewContribute: bigint | null = null;
    if (v2) {
      const V2 = { address, abi: vaultLauncherV2Abi } as const;
      [quoteBalance, quoteAllowance, previewContribute] = await Promise.all([
        publicClient.readContract({ ...V2, functionName: "quoteBalanceOf", args: [account] }),
        publicClient.readContract({ ...V2, functionName: "allowanceOf", args: [account] }),
        publicClient.readContract({ ...V2, functionName: "previewContribute", args: [account] }),
      ]);
    } else {
      quoteBalance = await publicClient.getBalance({ address: account });
      quoteAllowance = 2n ** 256n - 1n;
    }
    mine = {
      contribution,
      claimable,
      remainingCapUsd,
      maxContribution,
      vleiStatus,
      tokenBalance,
      quoteBalance,
      quoteAllowance,
      previewContribute,
    };
  }
  const vault = vaultAddr === zeroAddress ? null : await loadVault(vaultAddr, account);
  return {
    address,
    factory: f.address,
    kind: f.kind,
    quote: f.quote,
    name,
    symbol,
    status,
    raised,
    target,
    deadline,
    capUsdPerEntity,
    token,
    pool,
    creator,
    creatorActive,
    vault,
    mine,
  };
}

/** Every configured factory (primary first) and its launchers (newest first). A failing factory is reported, not fatal. */
export async function loadAll(account: Address | null, factories: readonly Address[] = FACTORY_ADDRESSES) {
  const results = await Promise.all(
    factories.map(async (addr) => {
      try {
        const f = await loadFactory(addr);
        const launches = await Promise.all([...f.launchers].reverse().map((a) => loadLaunch(a, f, account)));
        return { factory: f, launches, error: null as unknown };
      } catch (e) {
        return { factory: null, launches: [] as LaunchView[], error: e, address: addr };
      }
    }),
  );
  return results;
}

/** Vaults of every vault-v2 factory, with the given account's position (for the admin evict shortcut). */
export async function loadVaultsFor(account: Address) {
  const out: { launcher: Address; symbol: string; vault: Address; stakedOf: bigint; evictable: boolean }[] = [];
  for (const addr of FACTORY_ADDRESSES) {
    const f = await loadFactory(addr).catch(() => null);
    if (!f || f.kind !== "vault-v2") continue;
    const rows = await Promise.all(
      f.launchers.map(async (launcher) => {
        const vault = await publicClient.readContract({ address: launcher, abi: vaultLauncherV2Abi, functionName: "vault" });
        if (vault === zeroAddress) return null;
        const [symbol, stakedOf, evictable] = await Promise.all([
          publicClient.readContract({ address: launcher, abi: vaultLauncherV2Abi, functionName: "symbol" }),
          publicClient.readContract({ address: vault, abi: vaultV2Abi, functionName: "stakedOf", args: [account] }),
          publicClient.readContract({ address: vault, abi: vaultV2Abi, functionName: "evictable", args: [account] }),
        ]);
        return { launcher, symbol, vault, stakedOf, evictable };
      }),
    );
    for (const r of rows) if (r) out.push(r);
  }
  return out;
}

export const KIND_LABEL: Record<FactoryKind, string> = {
  v1: "v1 · BNB",
  v2: "v2",
  "vault-v2": "v2 · gated vault",
};

/** Where the 75% tax share goes, worded per launcher type. */
export function taxDestination(kind: FactoryKind, quote: Quote): string {
  if (kind === "vault-v2")
    return `75% of the trading tax goes to this launch's gated vault and is paid in ${quote.symbol} only to stakers with an active vLEI registration (stake the token, claim while verified).`;
  if (kind === "v2")
    return `75% of the trading tax goes to Flap's dividend tracker as ${quote.symbol}, for all holders (not gated).`;
  return "75% of the trading tax goes to Flap's dividend tracker as BNB, for all holders (not gated).";
}
