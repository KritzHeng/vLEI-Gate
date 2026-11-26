"use client";

import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { createWalletClient, custom, getAddress, numberToHex, type Address, type EIP1193Provider, type WalletClient } from "viem";
import { CHAIN, CHAIN_ID, RPC_URL } from "./config";

declare global {
  interface Window {
    ethereum?: EIP1193Provider;
  }
}

type WalletCtx = {
  hasProvider: boolean;
  account: Address | null;
  chainId: number | null;
  wrongChain: boolean;
  connect: () => Promise<void>;
  switchChain: () => Promise<void>;
  walletClient: WalletClient | null;
  /** Bumped after every confirmed transaction so views can refetch. */
  refreshKey: number;
  bump: () => void;
  error: string | null;
};

const Ctx = createContext<WalletCtx | null>(null);

export function WalletProvider({ children }: { children: ReactNode }) {
  const [hasProvider, setHasProvider] = useState(false);
  const [account, setAccount] = useState<Address | null>(null);
  const [chainId, setChainId] = useState<number | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const eth = window.ethereum;
    if (!eth) return;
    setHasProvider(true);
    eth.request({ method: "eth_accounts" }).then((a) => setAccount(a[0] ? getAddress(a[0]) : null)).catch(() => {});
    eth.request({ method: "eth_chainId" }).then((c) => setChainId(Number(c))).catch(() => {});
    const onAccounts = (a: string[]) => setAccount(a[0] ? getAddress(a[0]) : null);
    const onChain = (c: string) => setChainId(Number(c));
    eth.on("accountsChanged", onAccounts as never);
    eth.on("chainChanged", onChain as never);
    return () => {
      eth.removeListener("accountsChanged", onAccounts as never);
      eth.removeListener("chainChanged", onChain as never);
    };
  }, []);

  const connect = useCallback(async () => {
    setError(null);
    const eth = window.ethereum;
    if (!eth) {
      setError("No injected wallet found. Install MetaMask (or another EIP-1193 wallet).");
      return;
    }
    try {
      const a = await eth.request({ method: "eth_requestAccounts" });
      setAccount(a[0] ? getAddress(a[0]) : null);
      setChainId(Number(await eth.request({ method: "eth_chainId" })));
    } catch (e) {
      setError((e as Error).message);
    }
  }, []);

  const switchChain = useCallback(async () => {
    setError(null);
    const eth = window.ethereum;
    if (!eth) return;
    const hexId = numberToHex(CHAIN_ID);
    try {
      await eth.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hexId }] });
    } catch (e) {
      const code = (e as { code?: number }).code;
      if (code === 4902 || code === -32603) {
        try {
          await eth.request({
            method: "wallet_addEthereumChain",
            params: [
              {
                chainId: hexId,
                chainName: CHAIN.name,
                nativeCurrency: CHAIN.nativeCurrency,
                rpcUrls: [RPC_URL],
                blockExplorerUrls: CHAIN.blockExplorers ? [CHAIN.blockExplorers.default.url] : undefined,
              },
            ],
          });
        } catch (e2) {
          setError((e2 as Error).message);
        }
      } else {
        setError((e as Error).message);
      }
    }
  }, []);

  const walletClient = useMemo(() => {
    if (!account || typeof window === "undefined" || !window.ethereum) return null;
    return createWalletClient({ account, chain: CHAIN, transport: custom(window.ethereum) });
  }, [account]);

  const value: WalletCtx = {
    hasProvider,
    account,
    chainId,
    wrongChain: account !== null && chainId !== null && chainId !== CHAIN_ID,
    connect,
    switchChain,
    walletClient,
    refreshKey,
    bump: () => setRefreshKey((k) => k + 1),
    error,
  };
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useWallet(): WalletCtx {
  const c = useContext(Ctx);
  if (!c) throw new Error("useWallet outside WalletProvider");
  return c;
}

/** Asks the injected wallet to track an ERC20 (EIP-747 wallet_watchAsset). Returns true if the wallet accepted it. */
export async function watchAsset(address: Address, symbol: string, decimals = 18): Promise<boolean> {
  const eth = typeof window !== "undefined" ? window.ethereum : undefined;
  if (!eth) throw new Error("No injected wallet found.");
  // MetaMask limits the symbol to 11 characters.
  return eth.request({
    method: "wallet_watchAsset",
    params: { type: "ERC20", options: { address, symbol: symbol.slice(0, 11), decimals } },
  });
}
