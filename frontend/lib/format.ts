import { formatUnits, keccak256, toBytes } from "viem";

export function short(s: string | undefined | null, n = 6): string {
  if (!s) return "";
  return s.length <= n * 2 + 3 ? s : `${s.slice(0, n + 2)}…${s.slice(-n)}`;
}

export function fmtUsd18(v: bigint, digits = 2): string {
  return "$" + Number(formatUnits(v, 18)).toLocaleString(undefined, { maximumFractionDigits: digits, minimumFractionDigits: digits });
}

export function fmtToken(v: bigint, digits = 4): string {
  return Number(formatUnits(v, 18)).toLocaleString(undefined, { maximumFractionDigits: digits });
}

export function fmtTime(sec: number | bigint): string {
  const n = Number(sec);
  if (!n) return "—";
  return new Date(n * 1000).toLocaleString();
}

/** 18-decimal amount for display: comma grouping, `digits` decimals (default 2), optional unit; tiny non-zero values show "<0.01". */
export function fmtAmount(v: bigint, unit = "", digits = 2): string {
  const n = Number(formatUnits(v, 18));
  const floor = 10 ** -digits;
  const s =
    n > 0 && n < floor
      ? `<${floor.toFixed(digits)}`
      : n.toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });
  return unit ? `${s} ${unit}` : s;
}

/** Compact duration: "3d 4h", "23h 10m", "45m", "<1m". */
export function fmtDuration(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m`;
  return "<1m";
}

/** Same as the backend: keccak256(utf8(lei.upper())). */
export const leiToHash = (lei: string) => keccak256(toBytes(lei.trim().toUpperCase()));
