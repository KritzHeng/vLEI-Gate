"use client";

import { useCallback, useState } from "react";
import type { Abi, Address, Hash, TransactionReceipt } from "viem";
import { withAllErrors } from "./abis";
import { CHAIN } from "./config";
import { explainError } from "./errors";
import { publicClient } from "./clients";
import { useWallet } from "./wallet";

export type TxPhase = "idle" | "simulating" | "signing" | "pending" | "success" | "reverted" | "error";
export type TxState = { phase: TxPhase; message?: string; hash?: Hash };

export type TxRequest = {
  address: Address;
  abi: Abi;
  functionName: string;
  args?: readonly unknown[];
  value?: bigint;
  /** Explicit gas limit (e.g. the launching contribution needs gasleft >= MIN_LAUNCH_GAS). */
  gas?: bigint;
  /** Broadcast even if the simulation reverts (fixed gas), so the revert is recorded on-chain. */
  forceBroadcast?: boolean;
};

/** Simulate → sign → wait for receipt, with custom errors decoded into readable text. */
export function useTx() {
  const { walletClient, account, wrongChain, switchChain, bump } = useWallet();
  const [state, setState] = useState<TxState>({ phase: "idle" });

  const run = useCallback(
    async (req: TxRequest): Promise<TransactionReceipt | null> => {
      if (!walletClient || !account) {
        setState({ phase: "error", message: "Connect a wallet first." });
        return null;
      }
      if (wrongChain) {
        setState({ phase: "error", message: `Wallet is on the wrong network. Switch to ${CHAIN.name} (${CHAIN.id}).` });
        await switchChain();
        return null;
      }
      const abi = withAllErrors(req.abi);
      const base = { address: req.address, abi, functionName: req.functionName, args: req.args ?? [], value: req.value, account };
      let simError: string | null = null;
      setState({ phase: "simulating", message: "Simulating…" });
      try {
        await publicClient.simulateContract(base as never);
      } catch (e) {
        simError = explainError(e);
        if (!req.forceBroadcast) {
          setState({ phase: "error", message: `Would revert: ${simError}` });
          return null;
        }
      }
      try {
        setState({ phase: "signing", message: "Confirm in your wallet…" });
        const hash = await walletClient.writeContract({
          ...(base as object),
          chain: CHAIN,
          ...(req.gas ? { gas: req.gas } : simError ? { gas: 300_000n } : {}),
        } as never);
        setState({ phase: "pending", message: "Waiting for confirmation…", hash });
        const receipt = await publicClient.waitForTransactionReceipt({ hash });
        if (receipt.status === "success") {
          setState({ phase: "success", message: "Confirmed.", hash });
        } else {
          setState({
            phase: "reverted",
            message: `Reverted on-chain${simError ? `: ${simError}` : "."}`,
            hash,
          });
        }
        bump();
        return receipt;
      } catch (e) {
        setState({ phase: "error", message: explainError(e) });
        return null;
      }
    },
    [walletClient, account, wrongChain, switchChain, bump],
  );

  return { state, run, reset: () => setState({ phase: "idle" }) };
}
