"use client";

import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { Coins, Landmark, RefreshCcw, ShieldCheck, UserX } from "lucide-react";
import type { ActionAvailabilityStage, Address, VaultComponentProps } from "@/src/sdk";
import { erc20Abi, formatTokenAmount, handleTxError, isActionAvailableForPhase, parseTokenAmount, readTaxVaultHostContext, useFlapSdk } from "@/src/sdk";
import { VAULT_ERROR_KEYS, vleiDividendVaultAbi } from "./VaultABI";
import { AddressLink, Alert, Button, Card, CardContent, CardHeader, CardTitle, Input, Metric, StatusBadge, TxButton, type TxButtonState } from "@/src/ui";

// ═══════════════════════════════════════════════════════════════════════════
// CONTRACT FACTS (ABI fragments live in ./VaultABI.ts).
// Target: VLEIDividendVaultV2 (contracts/src/v2/vault/VLEIDividendVaultV2.sol), one per launch, created by
// VLEIDividendVaultFactoryV2 0x3C90db983d2eE6D3aa8fD88d6CF5Ae8535d49c03 (BSC Testnet). Revenue is the launch
// quote: mock USDT (18 decimals), read from vault.quoteToken(). Only context.vaultAddress and
// context.tokenAddress are called; the viewer's vLEI status comes from the vault's own views
// (canClaim / evictable / isEarning), never from the registry.
// ═══════════════════════════════════════════════════════════════════════════
/** The tax token is Flap's 18-decimal FlapDirectTaxToken; the USDT quote also has 18 decimals. */
const TOKEN_DECIMALS = 18;
const QUOTE_DECIMALS = 18;
/** Fallbacks if the constants cannot be read (contract: MIN_STAKE 1e18, HELD_RELEASE_MIN_STAKE 10,000e18). */
const DEFAULT_MIN_STAKE = 10n ** 18n;
const DEFAULT_HELD_RELEASE = 10_000n * 10n ** 18n;
// ═══════════════════════════════════════════════════════════════════════════

type Mode = "stake" | "unstake";
type Busy = "claim" | "evict" | "sync" | null;
type ViewerStatus = "connect" | "verified" | "evictable" | "blocked" | "noPosition";

interface Pool {
  totalStaked: bigint;
  totalRevenue: bigint;
  totalClaimed: bigint;
  totalForfeited: bigint;
  undistributed: bigint;
  minStake: bigint;
  heldRelease: bigint;
  quoteToken: Address | null;
}

interface Position {
  staked: bigint;
  pending: bigint;
  claimable: bigint;
  canClaim: boolean;
  evictable: boolean;
  earning: boolean;
  balance: bigint;
  allowance: bigint;
}

interface Target {
  address: Address;
  staked: bigint;
  pending: bigint;
  evictable: boolean;
}

interface Gate {
  ok: boolean;
  reason: string | null;
}

const addressPattern = /^0x[0-9a-fA-F]{40}$/;
const OPEN: Gate = { ok: true, reason: null };

function sameAddress(a: string | null | undefined, b: string | null | undefined) {
  return !!a && !!b && a.toLowerCase() === b.toLowerCase();
}

function parseAmount(text: string) {
  try {
    return text.trim() ? parseTokenAmount(text.trim(), TOKEN_DECIMALS) : 0n;
  } catch {
    return null;
  }
}

/** Collects every message, short message and decoded custom-error name along an error's cause chain. */
function errorText(error: unknown) {
  const parts: string[] = [];
  let current: unknown = error;
  for (let depth = 0; current && depth < 8; depth += 1) {
    if (typeof current !== "object") {
      parts.push(String(current));
      break;
    }
    const record = current as { message?: unknown; shortMessage?: unknown; data?: { errorName?: unknown }; cause?: unknown };
    for (const value of [record.message, record.shortMessage, record.data?.errorName]) {
      if (typeof value === "string") parts.push(value);
    }
    current = record.cause;
  }
  return parts.join(" ");
}

export default function VleiGatedYieldVault(_props: VaultComponentProps) {
  const sdk = useFlapSdk();
  const { context, i18n } = sdk;
  const t = i18n.t;
  const user = context.userAddress ?? null;
  const previewFixture = context.extraConfig?.previewFixture === true;

  const [pool, setPool] = useState<Pool | null>(null);
  const [position, setPosition] = useState<Position | null>(null);
  const [usingPreviewData, setUsingPreviewData] = useState(false);
  const [readError, setReadError] = useState<string | null>(null);

  const [mode, setMode] = useState<Mode>("stake");
  const [amount, setAmount] = useState("");
  const [amountTxState, setAmountTxState] = useState<TxButtonState>("idle");
  const [busy, setBusy] = useState<Busy>(null);
  const [actionError, setActionError] = useState<string | null>(null);

  const [targetInput, setTargetInput] = useState("");
  const [target, setTarget] = useState<Target | null>(null);
  const [targetError, setTargetError] = useState<string | null>(null);

  const txErrorMessages = useMemo(
    () => ({
      userRejected: t("errors.userRejected"),
      walletDisconnected: t("errors.walletDisconnected"),
      wrongNetwork: t("errors.wrongNetwork"),
      insufficientFunds: t("errors.insufficientFunds"),
      simulationFailed: t("errors.simulationFailed"),
      reverted: t("errors.txReverted"),
      unknown: t("errors.txFailed"),
    }),
    [t],
  );
  const readErrorMessages = useMemo(
    () => ({ ...txErrorMessages, simulationFailed: t("errors.readFailed"), reverted: t("errors.readFailed"), unknown: t("errors.readFailed") }),
    [t, txErrorMessages],
  );

  // ─── Host context: risk status, market phase, network ─────────────────────
  const host = readTaxVaultHostContext(context.host);
  const actionStage: ActionAvailabilityStage = "both";
  const marketPhase = host.marketPhase;
  const actionsAvailable = isActionAvailableForPhase(actionStage, marketPhase);
  const marketPhaseLabel =
    marketPhase === "internal-market" ? t("states.marketPhaseInternal") : marketPhase === "dex-listed" ? t("states.marketPhaseDexListed") : t("states.marketPhaseUnknown");
  const riskLevel = host.vaultInfo?.riskLevel ?? host.taxInfo?.vaultInfo?.riskLevel ?? null;
  const riskLabel =
    riskLevel === 1
      ? t("states.riskLow")
      : riskLevel === 2
        ? t("states.riskLowMedium")
        : riskLevel === 3
          ? t("states.riskMedium")
          : riskLevel === 4
            ? t("states.riskHigh")
            : riskLevel === 0
              ? t("states.riskUnverified")
              : t("states.riskMissing");
  const riskTone = riskLevel === null || riskLevel === 0 || riskLevel >= 4 ? "danger" : riskLevel >= 3 ? "warning" : "success";
  const quoteUnit = t("units.usdt");
  const tokenUnit = context.tokenSymbol || t("units.token");
  const writesBlockedReason = !user
    ? t("states.connectWallet")
    : sdk.wallet.isWrongNetwork
      ? t("states.wrongNetwork", undefined, { chain: sdk.wallet.requiredChainLabel })
      : !actionsAvailable
        ? t("states.actionsUnavailable")
        : null;

  // ─── Reads ─────────────────────────────────────────────────────────────────
  const applyPreviewData = useCallback(() => {
    setPool({
      totalStaked: parseTokenAmount("42000", TOKEN_DECIMALS),
      totalRevenue: parseTokenAmount("325.5", QUOTE_DECIMALS),
      totalClaimed: parseTokenAmount("190", QUOTE_DECIMALS),
      totalForfeited: parseTokenAmount("12", QUOTE_DECIMALS),
      undistributed: 0n,
      minStake: DEFAULT_MIN_STAKE,
      heldRelease: DEFAULT_HELD_RELEASE,
      quoteToken: null,
    });
    setPosition({
      staked: parseTokenAmount("1500", TOKEN_DECIMALS),
      pending: parseTokenAmount("8.4", QUOTE_DECIMALS),
      claimable: parseTokenAmount("8.4", QUOTE_DECIMALS),
      canClaim: true,
      evictable: false,
      earning: true,
      balance: parseTokenAmount("2500", TOKEN_DECIMALS),
      allowance: 0n,
    });
    setUsingPreviewData(true);
  }, []);

  const loadData = useCallback(async () => {
    if (previewFixture) {
      applyPreviewData();
      setReadError(null);
      return;
    }
    const [totalStaked, totalRevenue, totalClaimed, totalForfeited, undistributed, minStake, heldRelease, quoteToken] = await Promise.all([
      sdk.readContract<bigint>({ contract: "vault", address: context.vaultAddress, abi: vleiDividendVaultAbi, functionName: "totalStaked" }),
      sdk.readContract<bigint>({ contract: "vault", address: context.vaultAddress, abi: vleiDividendVaultAbi, functionName: "totalRevenue" }),
      sdk.readContract<bigint>({ contract: "vault", address: context.vaultAddress, abi: vleiDividendVaultAbi, functionName: "totalClaimed" }),
      sdk.readContract<bigint>({ contract: "vault", address: context.vaultAddress, abi: vleiDividendVaultAbi, functionName: "totalForfeited" }),
      sdk.readContract<bigint>({ contract: "vault", address: context.vaultAddress, abi: vleiDividendVaultAbi, functionName: "undistributed" }),
      sdk.readContract<bigint>({ contract: "vault", address: context.vaultAddress, abi: vleiDividendVaultAbi, functionName: "MIN_STAKE" }).catch(() => DEFAULT_MIN_STAKE),
      sdk.readContract<bigint>({ contract: "vault", address: context.vaultAddress, abi: vleiDividendVaultAbi, functionName: "HELD_RELEASE_MIN_STAKE" }).catch(() => DEFAULT_HELD_RELEASE),
      sdk.readContract<Address>({ contract: "vault", address: context.vaultAddress, abi: vleiDividendVaultAbi, functionName: "quoteToken" }).catch(() => null),
    ]);
    setPool({ totalStaked, totalRevenue, totalClaimed, totalForfeited, undistributed, minStake, heldRelease, quoteToken });
    setUsingPreviewData(false);

    if (!user) {
      setPosition(null);
      return;
    }
    const [staked, pending, claimable, canClaim, evictable, earning, balance, allowance] = await Promise.all([
      sdk.readContract<bigint>({ contract: "vault", address: context.vaultAddress, abi: vleiDividendVaultAbi, functionName: "stakedOf", args: [user] }),
      sdk.readContract<bigint>({ contract: "vault", address: context.vaultAddress, abi: vleiDividendVaultAbi, functionName: "pendingRewards", args: [user] }),
      sdk.readContract<bigint>({ contract: "vault", address: context.vaultAddress, abi: vleiDividendVaultAbi, functionName: "claimable", args: [user] }),
      sdk.readContract<boolean>({ contract: "vault", address: context.vaultAddress, abi: vleiDividendVaultAbi, functionName: "canClaim", args: [user] }),
      sdk.readContract<boolean>({ contract: "vault", address: context.vaultAddress, abi: vleiDividendVaultAbi, functionName: "evictable", args: [user] }),
      sdk.readContract<boolean>({ contract: "vault", address: context.vaultAddress, abi: vleiDividendVaultAbi, functionName: "isEarning", args: [user] }),
      sdk.readContract<bigint>({ contract: "token", address: context.tokenAddress, abi: erc20Abi, functionName: "balanceOf", args: [user] }),
      sdk.readContract<bigint>({ contract: "token", address: context.tokenAddress, abi: erc20Abi, functionName: "allowance", args: [user, context.vaultAddress] }),
    ]);
    setPosition({ staked, pending, claimable, canClaim, evictable, earning, balance, allowance });
  }, [applyPreviewData, context.tokenAddress, context.vaultAddress, previewFixture, sdk, user]);

  const refresh = useCallback(() => {
    setReadError(null);
    return loadData().catch((nextError) => setReadError(handleTxError(nextError, readErrorMessages)));
  }, [loadData, readErrorMessages]);

  useEffect(() => {
    void refresh();
    const timer = setInterval(() => {
      void loadData().catch(() => undefined);
    }, 15_000);
    return () => clearInterval(timer);
  }, [loadData, refresh, sdk.refetchNonce]);

  // Evict target: read its position whenever a well-formed address is entered.
  const targetAddress = addressPattern.test(targetInput.trim()) ? (targetInput.trim() as Address) : null;
  const loadTarget = useCallback(async () => {
    if (!targetAddress || previewFixture) {
      setTarget(null);
      return;
    }
    const [staked, pending, evictable] = await Promise.all([
      sdk.readContract<bigint>({ contract: "vault", address: context.vaultAddress, abi: vleiDividendVaultAbi, functionName: "stakedOf", args: [targetAddress] }),
      sdk.readContract<bigint>({ contract: "vault", address: context.vaultAddress, abi: vleiDividendVaultAbi, functionName: "pendingRewards", args: [targetAddress] }),
      sdk.readContract<boolean>({ contract: "vault", address: context.vaultAddress, abi: vleiDividendVaultAbi, functionName: "evictable", args: [targetAddress] }),
    ]);
    setTarget({ address: targetAddress, staked, pending, evictable });
  }, [context.vaultAddress, previewFixture, sdk, targetAddress]);

  useEffect(() => {
    setTargetError(null);
    void loadTarget().catch((nextError) => setTargetError(handleTxError(nextError, readErrorMessages)));
  }, [loadTarget, readErrorMessages]);

  // ─── Derived status (vault views only) ─────────────────────────────────────
  const minStake = pool?.minStake ?? DEFAULT_MIN_STAKE;
  const staked = position?.staked ?? 0n;
  const hasPosition = staked > 0n || (position?.pending ?? 0n) > 0n;
  // canClaim = registry.isActive(viewer) && same LEI as the stake. For a viewer with no position the vault
  // cannot tell us whether the wallet is verified (canClaim compares against an empty LEI), see CONTRACT NOTE.
  const viewerStatus: ViewerStatus = !user || !position
    ? "connect"
    : position.evictable
      ? "evictable"
      : position.canClaim
        ? "verified"
        : hasPosition
          ? "blocked"
          : "noPosition";
  const statusLabel: Record<ViewerStatus, string> = {
    connect: t("vlei.connect"),
    verified: t("vlei.active"),
    evictable: t("vlei.evictable"),
    blocked: t("vlei.blocked"),
    noPosition: t("vlei.noPosition"),
  };
  const statusTone = viewerStatus === "verified" ? "success" : viewerStatus === "evictable" ? "danger" : viewerStatus === "blocked" ? "warning" : "neutral";
  const earningLabel = !user
    ? t("earning.connect")
    : position?.earning
      ? t("earning.yes")
      : staked > 0n
        ? t("earning.evictable")
        : t("earning.notStaked");
  const heldBack = !!pool && pool.undistributed > 0n && pool.totalStaked < pool.heldRelease;

  // ─── Predicted reverts (custom errors) from reads ──────────────────────────
  const parsed = parseAmount(amount);
  const needsApproval = mode === "stake" && parsed !== null && parsed > 0n && (position?.allowance ?? 0n) < parsed;

  function stakeGate(): Gate {
    if (writesBlockedReason) return { ok: false, reason: writesBlockedReason };
    if (!position) return { ok: false, reason: null };
    if (parsed === null) return { ok: false, reason: t("errors.amountInvalid") };
    if (parsed === 0n) return { ok: false, reason: amount.trim() ? t("errors.zeroAmount") : null };
    // evictable => revoked / LEI moved / expired past grace: stake reverts NotVerified or EntityMismatch.
    if (position.evictable) return { ok: false, reason: t("errors.notVerifiedRevoked") };
    // An existing position that cannot claim: the wallet is inactive (NotVerified) or on another LEI (EntityMismatch).
    if (hasPosition && !position.canClaim) return { ok: false, reason: t("errors.notVerifiedOrMoved") };
    if (staked + parsed < minStake) return { ok: false, reason: t("errors.belowMinStake", undefined, { min: formatTokenAmount(minStake, TOKEN_DECIMALS) }) };
    if (position.balance < parsed) return { ok: false, reason: t("errors.insufficientBalance") };
    return OPEN;
  }

  function unstakeGate(): Gate {
    if (writesBlockedReason) return { ok: false, reason: writesBlockedReason };
    if (!position) return { ok: false, reason: null };
    // An evictable caller exits fully regardless of amount (and forfeits its rewards).
    if (position.evictable) return OPEN;
    if (staked === 0n) return { ok: false, reason: t("errors.nothingStaked") };
    if (parsed === null) return { ok: false, reason: t("errors.amountInvalid") };
    if (parsed === 0n) return { ok: false, reason: amount.trim() ? t("errors.zeroAmount") : null };
    if (parsed > staked) return { ok: false, reason: t("errors.insufficientStake") };
    const remaining = staked - parsed;
    if (remaining !== 0n && remaining < minStake) return { ok: false, reason: t("errors.belowMinRemaining", undefined, { min: formatTokenAmount(minStake, TOKEN_DECIMALS) }) };
    return OPEN;
  }

  function claimGate(): Gate {
    if (writesBlockedReason) return { ok: false, reason: writesBlockedReason };
    if (!position) return { ok: false, reason: null };
    if (!position.canClaim) return { ok: false, reason: hasPosition ? t("errors.notVerifiedOrMoved") : t("errors.nothingToClaim") };
    if (position.claimable === 0n) return { ok: false, reason: t("errors.nothingToClaim") };
    return OPEN;
  }

  function evictGate(): Gate {
    if (writesBlockedReason) return { ok: false, reason: writesBlockedReason };
    if (!targetInput.trim()) return { ok: false, reason: null };
    if (!targetAddress) return { ok: false, reason: t("errors.addressInvalid") };
    if (!target || !sameAddress(target.address, targetAddress)) return { ok: false, reason: null };
    if (!target.evictable) return { ok: false, reason: t("errors.notEvictable") };
    return OPEN;
  }

  const amountGate = mode === "stake" ? stakeGate() : unstakeGate();
  const claim = claimGate();
  const evictCheck = evictGate();

  /** Prefer the decoded custom error, then the predicted reason, then the generic wallet/RPC category. */
  function explain(error: unknown, predicted: string | null) {
    const text = errorText(error);
    const known = VAULT_ERROR_KEYS.find(([name]) => text.includes(name));
    if (known) {
      if (known[0] === "BelowMinStake") return t("errors.belowMinStake", undefined, { min: formatTokenAmount(minStake, TOKEN_DECIMALS) });
      return t(known[1]);
    }
    const kind = handleTxError(error, txErrorMessages);
    return kind === txErrorMessages.simulationFailed && predicted ? predicted : kind;
  }

  // ─── Writes ────────────────────────────────────────────────────────────────
  async function approveStake(value: bigint) {
    setAmountTxState("approving");
    const hash = await sdk.writeContract({
      contract: "token",
      address: context.tokenAddress,
      abi: erc20Abi,
      functionName: "approve",
      args: [context.vaultAddress, value],
    });
    setAmountTxState("approval_confirming");
    await sdk.waitForTx(hash);
    sdk.notify.success(t("messages.approveSuccess"));
    await loadData();
  }

  async function submitAmount() {
    setActionError(null);
    const gate = mode === "stake" ? stakeGate() : unstakeGate();
    if (!gate.ok || parsed === null) {
      setActionError(gate.reason);
      return;
    }
    try {
      if (mode === "stake") {
        if (needsApproval) {
          await approveStake(parsed);
          setAmountTxState("idle");
          return;
        }
        setAmountTxState("simulating");
        const simulation = await sdk.simulateContract({
          contract: "vault",
          address: context.vaultAddress,
          abi: vleiDividendVaultAbi,
          functionName: "stake",
          args: [parsed],
        });
        setAmountTxState("writing");
        const hash = await sdk.writeContract(simulation.request);
        setAmountTxState("confirming");
        await sdk.waitForTx(hash);
        sdk.notify.success(t("messages.stakeSuccess"));
      } else {
        setAmountTxState("simulating");
        const simulation = await sdk.simulateContract({
          contract: "vault",
          address: context.vaultAddress,
          abi: vleiDividendVaultAbi,
          functionName: "unstake",
          args: [position?.evictable ? staked : parsed],
        });
        setAmountTxState("writing");
        const hash = await sdk.writeContract(simulation.request);
        setAmountTxState("confirming");
        await sdk.waitForTx(hash);
        sdk.notify.success(t("messages.unstakeSuccess"));
      }
      setAmount("");
      await loadData();
      setAmountTxState("idle");
    } catch (nextError) {
      // A fresh staker's verification is not readable from the vault, so a failed stake simulation most
      // likely means NotVerified.
      const predicted = mode === "stake" && !hasPosition ? t("errors.notVerified") : gate.reason;
      setActionError(explain(nextError, predicted));
      setAmountTxState("failed");
    }
  }

  async function runSimple(kind: "claim" | "sync", predicted: string | null) {
    setActionError(null);
    if (kind === "claim" && !claim.ok) {
      setActionError(claim.reason);
      return;
    }
    if (kind === "sync" && writesBlockedReason) {
      setActionError(writesBlockedReason);
      return;
    }
    setBusy(kind);
    try {
      const simulation = await sdk.simulateContract({
        contract: "vault",
        address: context.vaultAddress,
        abi: vleiDividendVaultAbi,
        functionName: kind,
        args: [],
      });
      const hash = await sdk.writeContract(simulation.request);
      await sdk.waitForTx(hash);
      sdk.notify.success(t(kind === "claim" ? "messages.claimSuccess" : "messages.syncSuccess"));
      await loadData();
    } catch (nextError) {
      setActionError(explain(nextError, predicted));
    } finally {
      setBusy(null);
    }
  }

  async function evictTarget() {
    setTargetError(null);
    const gate = evictGate();
    if (!gate.ok || !targetAddress) {
      setTargetError(gate.reason);
      return;
    }
    setBusy("evict");
    try {
      const simulation = await sdk.simulateContract({
        contract: "vault",
        address: context.vaultAddress,
        abi: vleiDividendVaultAbi,
        functionName: "evict",
        args: [targetAddress],
      });
      const hash = await sdk.writeContract(simulation.request);
      await sdk.waitForTx(hash);
      sdk.notify.success(t("messages.evictSuccess"));
      await loadData();
      await loadTarget();
    } catch (nextError) {
      setTargetError(explain(nextError, t("errors.notEvictable")));
    } finally {
      setBusy(null);
    }
  }

  function selectMode(next: Mode) {
    setMode(next);
    setAmount("");
    setActionError(null);
    setAmountTxState("idle");
  }

  function fillMax() {
    const max = mode === "stake" ? position?.balance ?? 0n : staked;
    setAmount(formatTokenAmount(max, TOKEN_DECIMALS, TOKEN_DECIMALS));
    setActionError(null);
  }

  const amountIdleLabel = mode === "stake" ? (needsApproval ? t("actions.approve") : t("actions.stake")) : position?.evictable ? t("actions.exitAll") : t("actions.unstake");
  const writing = amountTxState !== "idle" && amountTxState !== "failed" && amountTxState !== "success";

  return (
    <div className="w-full space-y-3 sm:space-y-4">
      <Card className="overflow-hidden rounded-[18px] border-white/10 bg-gradient-to-b from-[#0e141d] to-[#070b11]">
        <CardHeader className="p-4 pb-3 sm:p-5 sm:pb-4">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div className="min-w-0 space-y-2">
              <div className="flex flex-wrap items-center gap-2">
                <StatusBadge tone={riskTone}>{riskLabel}</StatusBadge>
                <StatusBadge tone={actionsAvailable ? "success" : "warning"}>{marketPhaseLabel}</StatusBadge>
              </div>
              <CardTitle className="text-base sm:text-lg">{t("title")}</CardTitle>
              <p className="text-sm font-semibold text-[#f0b90b]">{t("tagline")}</p>
              <p className="max-w-2xl text-xs font-medium leading-5 text-[#7c8899] sm:text-sm sm:leading-6">{t("description")}</p>
            </div>
            <Button variant="secondary" size="sm" onClick={() => void refresh()}>
              <RefreshCcw className="h-4 w-4" />
              {t("actions.refresh")}
            </Button>
          </div>
        </CardHeader>

        <CardContent className="space-y-3 p-4 pt-0 sm:space-y-4 sm:p-5 sm:pt-0">
          {riskLevel === null ? <Alert tone="danger">{t("notices.riskMissing")}</Alert> : null}
          {usingPreviewData ? <Alert tone="info">{t("notices.previewData")}</Alert> : null}
          {readError ? <Alert tone="danger">{readError}</Alert> : null}

          <div className="grid grid-cols-2 gap-2 lg:grid-cols-4 lg:gap-3">
            <Metric label={t("labels.myStake")} value={user ? formatTokenAmount(position?.staked, TOKEN_DECIMALS) : "-"} hint={tokenUnit} tone="primary" />
            <Metric label={t("labels.claimable")} value={user ? formatTokenAmount(position?.claimable, QUOTE_DECIMALS, 4) : "-"} hint={quoteUnit} tone="success" />
            <Metric label={t("labels.totalRevenue")} value={formatTokenAmount(pool?.totalRevenue, QUOTE_DECIMALS, 4)} hint={quoteUnit} />
            <Metric label={t("labels.totalStaked")} value={formatTokenAmount(pool?.totalStaked, TOKEN_DECIMALS)} hint={tokenUnit} />
          </div>

          {/* Viewer status: from the vault's own views (canClaim / evictable / isEarning) */}
          <section className="rounded-[14px] border border-white/10 bg-black/25 p-3 sm:p-4" aria-label={t("sections.status")}>
            <div className="flex flex-wrap items-center justify-between gap-2">
              <div className="flex items-center gap-2 text-sm font-semibold text-[#eaf1f8]">
                <ShieldCheck className="h-4 w-4" />
                {t("sections.status")}
              </div>
              <div className="flex flex-wrap gap-2">
                <StatusBadge tone={statusTone}>{statusLabel[viewerStatus]}</StatusBadge>
                <StatusBadge tone={position?.earning ? "success" : staked > 0n ? "danger" : "neutral"}>{earningLabel}</StatusBadge>
              </div>
            </div>
            {user ? (
              <div className="mt-3 grid grid-cols-2 gap-x-4 gap-y-2 lg:grid-cols-5">
                <Fact label={t("labels.canClaim")} value={position ? (position.canClaim ? t("labels.yes") : t("labels.no")) : "-"} />
                <Fact label={t("labels.isEarning")} value={position ? (position.earning ? t("labels.yes") : t("labels.no")) : "-"} />
                <Fact label={t("labels.evictable")} value={position ? (position.evictable ? t("labels.yes") : t("labels.no")) : "-"} />
                <Fact label={t("labels.pending")} value={`${formatTokenAmount(position?.pending, QUOTE_DECIMALS, 4)} ${quoteUnit}`} />
                <Fact label={t("labels.walletBalance")} value={`${formatTokenAmount(position?.balance, TOKEN_DECIMALS)} ${tokenUnit}`} />
              </div>
            ) : null}
            <div className="mt-3 space-y-2">
              {user && position?.evictable ? <Alert tone="danger">{t("notices.selfEvictable")}</Alert> : null}
              {user && viewerStatus === "blocked" ? <Alert tone="warning">{t("notices.pendingNotClaimable")}</Alert> : null}
              {user && viewerStatus === "noPosition" ? <Alert>{t("notices.howToVerify")}</Alert> : null}
            </div>
          </section>

          {/* Primary action panel: stake / unstake / claim */}
          <section className="rounded-[14px] border border-white/10 bg-black/30 p-3 sm:p-4" aria-label={t("sections.actions")}>
            <div className="flex flex-wrap items-center justify-between gap-2">
              <div className="flex items-center gap-2 text-sm font-semibold text-[#eaf1f8]">
                <Coins className="h-4 w-4" />
                {t("sections.actions")}
              </div>
              <div className="flex gap-2" role="tablist">
                <Button size="sm" variant={mode === "stake" ? "default" : "ghost"} onClick={() => selectMode("stake")} disabled={writing}>
                  {t("actions.stakeTab")}
                </Button>
                <Button size="sm" variant={mode === "unstake" ? "default" : "ghost"} onClick={() => selectMode("unstake")} disabled={writing}>
                  {t("actions.unstakeTab")}
                </Button>
              </div>
            </div>
            <p className="mt-2 text-xs font-medium leading-5 text-[#7c8899]">{mode === "stake" ? t("help.stake") : t("help.unstake")}</p>

            <div className="mt-3 grid gap-3 lg:grid-cols-[1.1fr_0.9fr]">
              <div className="rounded-[12px] border border-white/10 bg-white/[0.03] p-3">
                <label className="block space-y-2">
                  <span className="text-sm font-semibold text-[#d8e2ef]">{mode === "stake" ? t("labels.stakeAmount") : t("labels.unstakeAmount")}</span>
                  <div className="flex gap-2">
                    <Input
                      value={position?.evictable && mode === "unstake" ? formatTokenAmount(staked, TOKEN_DECIMALS, TOKEN_DECIMALS) : amount}
                      inputMode="decimal"
                      disabled={writing || (mode === "unstake" && !!position?.evictable)}
                      onChange={(event) => {
                        setAmount(event.target.value);
                        setActionError(null);
                        setAmountTxState("idle");
                      }}
                    />
                    <Button variant="ghost" size="sm" onClick={fillMax} disabled={!user || writing}>
                      {t("actions.max")}
                    </Button>
                  </div>
                </label>
                <p className="mt-2 text-xs text-[#7c8899]">
                  {mode === "stake"
                    ? t("labels.stakeFacts", undefined, {
                        balance: formatTokenAmount(position?.balance, TOKEN_DECIMALS),
                        allowance: formatTokenAmount(position?.allowance, TOKEN_DECIMALS),
                        min: formatTokenAmount(minStake, TOKEN_DECIMALS),
                        symbol: tokenUnit,
                      })
                    : t("labels.unstakeFacts", undefined, { staked: formatTokenAmount(staked, TOKEN_DECIMALS), symbol: tokenUnit })}
                </p>
                <div className="mt-3 space-y-2">
                  {mode === "unstake" && position?.evictable ? (
                    <Alert tone="danger">{t("notices.exitForfeits", undefined, { amount: formatTokenAmount(position.pending, QUOTE_DECIMALS, 4), unit: quoteUnit })}</Alert>
                  ) : null}
                  {needsApproval && amountGate.ok ? <Alert tone="warning">{t("states.approvalNeeded")}</Alert> : null}
                  {!amountGate.ok && amountGate.reason ? <Alert tone="warning">{amountGate.reason}</Alert> : null}
                </div>
                <div className="mt-3 grid gap-2">
                  {sdk.wallet.isWrongNetwork ? (
                    <Button variant="outline" loading={sdk.wallet.isSwitchingChain} onClick={() => void sdk.wallet.switchChain().catch((nextError) => setActionError(handleTxError(nextError, txErrorMessages)))}>
                      {t("actions.switchNetwork")}
                    </Button>
                  ) : null}
                  <TxButton className="w-full" idleLabel={amountIdleLabel} state={amountTxState} onClick={() => void submitAmount()} disabled={!amountGate.ok || busy !== null} />
                </div>
              </div>

              <div className="flex flex-col justify-between gap-3 rounded-[12px] border border-white/10 bg-white/[0.03] p-3">
                <div className="space-y-1">
                  <div className="text-sm font-semibold text-[#d8e2ef]">{t("actions.claim")}</div>
                  <div className="font-mono text-xl font-semibold text-[#2EDEDB]">
                    {user ? formatTokenAmount(position?.claimable, QUOTE_DECIMALS, 6) : "-"} <span className="text-xs text-[#7c8899]">{quoteUnit}</span>
                  </div>
                  <p className="text-xs leading-5 text-[#7c8899]">{t("help.claim")}</p>
                </div>
                {!claim.ok && claim.reason ? <Alert tone="warning">{claim.reason}</Alert> : null}
                <Button className="w-full" variant="outline" loading={busy === "claim"} onClick={() => void runSimple("claim", null)} disabled={!claim.ok || busy !== null || writing}>
                  {t("actions.claim")}
                </Button>
              </div>
            </div>
            {actionError ? (
              <div className="mt-3">
                <Alert tone="danger">{actionError}</Alert>
              </div>
            ) : null}
          </section>

          {/* Evict a revoked staker (address parameter) */}
          <section className="rounded-[14px] border border-white/10 bg-black/25 p-3 sm:p-4" aria-label={t("sections.evict")}>
            <div className="flex items-center gap-2 text-sm font-semibold text-[#eaf1f8]">
              <UserX className="h-4 w-4" />
              {t("sections.evict")}
            </div>
            <p className="mt-2 text-xs font-medium leading-5 text-[#7c8899]">{t("help.evict")}</p>
            <div className="mt-3 grid gap-2 sm:grid-cols-[1fr_auto]">
              <Input
                value={targetInput}
                placeholder={t("labels.evictPlaceholder")}
                spellCheck={false}
                autoComplete="off"
                onChange={(event) => {
                  setTargetInput(event.target.value);
                  setTargetError(null);
                }}
              />
              <Button variant="destructive" loading={busy === "evict"} onClick={() => void evictTarget()} disabled={!evictCheck.ok || busy !== null || writing}>
                {t("actions.evict")}
              </Button>
            </div>
            {target && targetAddress && sameAddress(target.address, targetAddress) ? (
              <div className="mt-3 grid grid-cols-2 gap-x-4 gap-y-2 lg:grid-cols-3">
                <Fact label={t("labels.targetStaked")} value={`${formatTokenAmount(target.staked, TOKEN_DECIMALS)} ${tokenUnit}`} />
                <Fact label={t("labels.targetForfeit")} value={`${formatTokenAmount(target.pending, QUOTE_DECIMALS, 4)} ${quoteUnit}`} />
                <Fact label={t("labels.targetEvictable")} value={target.evictable ? t("labels.yes") : t("labels.no")} />
              </div>
            ) : null}
            <div className="mt-3 space-y-2">
              {target && sameAddress(target.address, user) && target.evictable ? <Alert>{t("notices.evictSelf")}</Alert> : null}
              {!evictCheck.ok && evictCheck.reason ? <Alert tone="warning">{evictCheck.reason}</Alert> : null}
              {targetError ? <Alert tone="danger">{targetError}</Alert> : null}
            </div>
          </section>

          {/* Pool totals, sync and runtime facts */}
          <section className="rounded-[14px] border border-white/10 bg-[#0e141d] p-3 sm:p-4" aria-label={t("sections.pool")}>
            <div className="flex flex-wrap items-center justify-between gap-2">
              <div className="flex items-center gap-2 text-sm font-semibold text-[#eaf1f8]">
                <Landmark className="h-4 w-4" />
                {t("sections.pool")}
              </div>
              <Button size="sm" variant="outline" loading={busy === "sync"} onClick={() => void runSimple("sync", null)} disabled={!!writesBlockedReason || busy !== null || writing}>
                {t("actions.sync")}
              </Button>
            </div>
            <div className="mt-3 grid grid-cols-2 gap-x-4 gap-y-2 lg:grid-cols-3">
              <Fact label={t("labels.totalRevenue")} value={`${formatTokenAmount(pool?.totalRevenue, QUOTE_DECIMALS, 4)} ${quoteUnit}`} />
              <Fact label={t("labels.totalClaimed")} value={`${formatTokenAmount(pool?.totalClaimed, QUOTE_DECIMALS, 4)} ${quoteUnit}`} />
              <Fact label={t("labels.totalForfeited")} value={`${formatTokenAmount(pool?.totalForfeited, QUOTE_DECIMALS, 4)} ${quoteUnit}`} />
              <Fact label={t("labels.undistributed")} value={`${formatTokenAmount(pool?.undistributed, QUOTE_DECIMALS, 4)} ${quoteUnit}`} />
              <Fact label={t("labels.totalStaked")} value={`${formatTokenAmount(pool?.totalStaked, TOKEN_DECIMALS)} ${tokenUnit}`} />
              <Fact label={t("labels.minStake")} value={`${formatTokenAmount(minStake, TOKEN_DECIMALS)} ${tokenUnit}`} />
            </div>
            {heldBack ? (
              <div className="mt-3">
                <Alert tone="warning">{t("notices.heldBack", undefined, { min: formatTokenAmount(pool?.heldRelease, TOKEN_DECIMALS), symbol: tokenUnit })}</Alert>
              </div>
            ) : null}
            <p className="mt-3 text-xs leading-5 text-[#7c8899]">{t("help.pool")}</p>
            <div className="mt-3 grid gap-2 border-t border-white/10 pt-3 sm:grid-cols-3">
              <Fact label={t("labels.vault")} value={<AddressLink address={context.vaultAddress} explorerBaseUrl={context.explorerBaseUrl} />} />
              <Fact label={t("labels.token")} value={<AddressLink address={context.tokenAddress} explorerBaseUrl={context.explorerBaseUrl} label={context.tokenSymbol} />} />
              <Fact label={t("labels.quoteToken")} value={pool?.quoteToken ? <AddressLink address={pool.quoteToken} explorerBaseUrl={context.explorerBaseUrl} label={quoteUnit} /> : "-"} />
            </div>
          </section>

          {writesBlockedReason ? <Alert tone="warning">{writesBlockedReason}</Alert> : null}
          <Alert>{t("notices.safety")}</Alert>
        </CardContent>
      </Card>
    </div>
  );
}

function Fact({ label, value }: { label: string; value: ReactNode }) {
  return (
    <div className="min-w-0">
      <div className="truncate text-xs font-medium text-[#7c8899]">{label}</div>
      <div className="mt-1 min-w-0 break-words font-mono text-sm font-semibold text-[#eaf1f8]">{value}</div>
    </div>
  );
}
