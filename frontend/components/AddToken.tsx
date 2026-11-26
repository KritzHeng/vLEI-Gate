"use client";

import { useState } from "react";
import { zeroAddress, type Address } from "viem";
import { watchAsset } from "@/lib/wallet";
import { short } from "@/lib/format";

/** "Add XYZ to MetaMask" (wallet_watchAsset), so the token shows up in the wallet's asset list. */
export default function AddToken({ address, symbol, decimals = 18 }: { address: Address; symbol: string; decimals?: number }) {
  const [state, setState] = useState<"idle" | "added" | "error">("idle");
  const [msg, setMsg] = useState<string | null>(null);
  if (!address || address === zeroAddress) return null;
  const add = async () => {
    setMsg(null);
    try {
      const ok = await watchAsset(address, symbol, decimals);
      setState(ok ? "added" : "idle");
    } catch (e) {
      setState("error");
      setMsg((e as Error).message);
    }
  };
  return (
    <span className="addtoken">
      <button
        type="button"
        className="ghost small-btn"
        onClick={add}
        title={`Add ${symbol} (${short(address, 4)}, ${decimals} decimals) to your wallet's token list`}
      >
        {state === "added" ? `✓ ${symbol} added` : `+ Add ${symbol} to wallet`}
      </button>
      {state === "error" && msg && <span className="small text-bad"> {msg}</span>}
    </span>
  );
}
