import { BACKEND_URL } from "./config";

export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

async function api<T>(path: string, init?: RequestInit): Promise<T> {
  let r: Response;
  try {
    r = await fetch(`${BACKEND_URL}${path}`, {
      ...init,
      headers: { "Content-Type": "application/json", ...(init?.headers || {}) },
    });
  } catch (e) {
    throw new ApiError(0, `Backend unreachable at ${BACKEND_URL} (${(e as Error).message})`);
  }
  if (!r.ok) {
    let detail = `HTTP ${r.status}`;
    try {
      const j = await r.json();
      if (j?.detail) detail = typeof j.detail === "string" ? j.detail : JSON.stringify(j.detail);
    } catch {
      /* ignore */
    }
    throw new ApiError(r.status, detail);
  }
  return (await r.json()) as T;
}

const post = <T>(path: string, body: unknown) => api<T>(path, { method: "POST", body: JSON.stringify(body) });

export type Health = {
  ok: boolean;
  chainId: number;
  registry: string;
  pinnedRootAid: string;
  verifierSigner: string;
  cournotMode: string;
  cmcConfigured: boolean;
  demoAgent: boolean;
  nonceSource?: "chain" | "client";
  launchRoles: string[];
};

export type Persona = {
  id: string;
  aid: string;
  personLegalName: string;
  entity: string;
  lei: string;
  credentialType: string;
  role: string;
  description: string;
  scenario: string;
  leafSaid: string;
};

export type Presentation = { leafSaid: string; holder: string; credentials: Record<string, unknown>[] };
export type Challenge = { id: string; message: string; expiresAt: number };
export type Check = { id: string; label: string; ok: boolean | null; detail: string };

export type Attestation = {
  domain: { name: string; version: string; chainId: number; verifyingContract: string };
  types: Record<string, { name: string; type: string }[]>;
  message: { wallet: string; leiHash: string; role: number; nonce: number | string; expiresAt: number | string };
  signature: string;
  signer?: string;
  nonceSource?: "chain" | "client";
};

export type VerifyResult = {
  ok: boolean;
  checks: Check[];
  holder: string;
  lei: string;
  lei_hash: string;
  entity_name: string;
  person_name: string;
  credential_type: string;
  official_role: string;
  role: number;
  role_name: string;
  chain: { said: string; type: string; issuer: string; holder: string }[];
  attestation: Attestation | null;
  error: string;
};

export type Evidence = { title?: string; url?: string; [k: string]: unknown } | string;

/** A live Cournot Intelligence Oracle assessment (rate risk of the tokenized-Treasury offering). */
export type RiskResult = {
  source: "cournot";
  question: string;
  /** The exact claim Cournot evaluated: the matched market's title. */
  claim: string;
  /** The market's resolution rules (from Cournot). */
  claimDetail?: string;
  marketId?: string;
  marketEnd?: string;
  matchingConfidence?: number | null;
  probability: number;
  /** Cournot's `basis` entries. */
  evidence: Evidence[];
  /** Cournot returns none for probability calls; `logFile` is the proof. */
  requestId: string;
  logFile?: string;
  billing?: string | null;
  charged?: boolean | null;
  entity: string;
  lei: string;
  askedAt: string;
  latencyMs: number;
  /** true = served from the latest logged live call (no new quota spent). */
  cached?: boolean;
  refreshError?: string;
  highRisk: boolean;
  threshold: number;
  /** Explanation added by vLEI-Gate, not returned by Cournot. */
  appNote?: string;
};

export type CmcQuote = {
  source: string;
  symbol: string;
  convert: string;
  price: number;
  percentChange24h?: number;
  lastUpdated?: string;
  endpoint: string;
  cached: boolean;
};

/** Atlas (on-chain, signed) vs CoinMarketCap BNB/USD; `ok` false blocks BNB contributions on Atlas-priced launches. */
export type PriceCheck = {
  status: "ok" | "deviation" | "stale" | "unavailable";
  ok: boolean;
  reason: string;
  deviationBps: number | null;
  maxDeviationBps: number;
  maxAgeSeconds: number;
  checkedAt: number;
  atlas: { price: number; updatedAt: number; ageSeconds: number; feed: string } | null;
  cmc: { price: number; lastUpdated?: string } | null;
};

export const backend = {
  health: () => api<Health>("/api/health"),
  personas: () => api<Persona[]>("/api/demo/personas"),
  presentation: (id: string) => api<Presentation>(`/api/demo/personas/${encodeURIComponent(id)}/presentation`),
  agentSign: (persona: string, message: string) =>
    post<{ aid: string; signature: string; keySn?: number }>("/api/demo/agent/sign", { persona, message }),
  challenge: (wallet: string, holder: string) => post<Challenge>("/api/vlei/challenge", { wallet, holder }),
  verify: (body: {
    challengeId: string;
    leafSaid: string;
    credentials: Record<string, unknown>[];
    holderSignature: string;
    walletSignature: string;
    action: "launch" | "invest";
    registryNonce: number;
  }) => post<VerifyResult>("/api/vlei/verify", body),
  /** refresh=true spends one Cournot call; false returns the latest logged live assessment. */
  cournotRisk: (refresh = false, name = "", lei = "") => post<RiskResult>("/api/oracle/cournot-risk", { name, lei, refresh }),
  cournotLatest: () => api<RiskResult>("/api/oracle/cournot-latest"),
  cournotLog: () => api<RiskResult[]>("/api/oracle/cournot-log"),
  cmc: (symbol = "BNB") => api<CmcQuote>(`/api/market/cmc?symbol=${encodeURIComponent(symbol)}`),
  priceCheck: () => api<PriceCheck>("/api/market/price-check"),
};
