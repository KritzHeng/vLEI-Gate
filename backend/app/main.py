"""vLEI-Gate backend: verifier, Cournot risk oracle, CMC proxy, demo holder agent."""
from __future__ import annotations

import json
import warnings

warnings.filterwarnings("ignore", category=SyntaxWarning)

from eth_account import Account  # noqa: E402
from fastapi import FastAPI, HTTPException  # noqa: E402
from fastapi.middleware.cors import CORSMiddleware  # noqa: E402
from pydantic import BaseModel, Field  # noqa: E402

from .config import LOG_DIR, settings  # noqa: E402
from .market import cmc, price_check  # noqa: E402
from .oracle import cournot  # noqa: E402
from .vlei import agent  # noqa: E402
from .vlei.verifier import ChallengeStore, Verifier  # noqa: E402

app = FastAPI(title="vLEI-Gate backend", version="0.1.0")
app.add_middleware(
    CORSMiddleware, allow_origins=settings.cors_origins, allow_methods=["*"], allow_headers=["*"]
)

challenges = ChallengeStore(settings.challenge_ttl)
verifier = Verifier(settings, challenges)


@app.get("/api/health")
def health() -> dict:
    return {
        "ok": True,
        "chainId": settings.chain_id,
        "registry": settings.registry_address,
        "pinnedRootAid": settings.pinned_root_aid,
        "verifierSigner": Account.from_key(settings.verifier_private_key).address if settings.verifier_private_key else "",
        "cournotMode": "live (api key)" if settings.cournot_api_key else "live (free quota)",
        "cournotRefresh": settings.cournot_allow_refresh,
        "cmcConfigured": bool(settings.cmc_api_key),
        "demoAgent": settings.enable_demo_agent,
        "nonceSource": "chain" if settings.rpc_url else "client",
        "launchRoles": settings.launch_roles,
    }


# ---------------------------------------------------------------- verifier


class ChallengeReq(BaseModel):
    wallet: str
    holder: str = Field(description="Holder AID taken from the leaf credential (a.i)")


@app.post("/api/vlei/challenge")
def make_challenge(req: ChallengeReq) -> dict:
    if not settings.registry_address:
        raise HTTPException(503, "registry address not configured (deploy contracts or set REGISTRY_ADDRESS)")
    import re

    if not re.fullmatch(r"[A-Za-z0-9_-]{44}", req.holder):
        raise HTTPException(400, "holder must be a qb64 AID")
    try:
        ch = challenges.issue(wallet=req.wallet, holder=req.holder, chain_id=settings.chain_id,
                              registry=settings.registry_address)
    except ValueError as e:
        raise HTTPException(400, str(e))
    return {"id": ch.id, "message": ch.message, "expiresAt": ch.expires_at}


class VerifyReq(BaseModel):
    challengeId: str
    leafSaid: str
    credentials: list[dict]
    holderSignature: str
    walletSignature: str
    action: str = "invest"
    registryNonce: int = 0


@app.post("/api/vlei/verify")
def verify(req: VerifyReq) -> dict:
    return verifier.verify(req.model_dump()).to_dict()


# ---------------------------------------------------------------- oracle / market


class RiskReq(BaseModel):
    name: str = ""
    lei: str = ""
    refresh: bool = False  # True spends one Cournot call (free quota or key); False serves the latest live result


@app.post("/api/oracle/cournot-risk")
async def cournot_risk(req: RiskReq) -> dict:
    try:
        return await cournot.assessment(settings, refresh=req.refresh, name=req.name, lei=req.lei)
    except cournot.CournotError as e:  # upstream failure is reported, never mocked
        raise HTTPException(e.status if e.status in (402, 403, 404, 429) else 502, f"Cournot request failed: {e}")


@app.get("/api/oracle/cournot-latest")
def cournot_latest() -> dict:
    r = cournot.latest(settings)
    if r is None:
        raise HTTPException(404, "no live Cournot assessment yet")
    return r


@app.get("/api/oracle/cournot-log")
def cournot_log(limit: int = 20) -> list[dict]:
    return cournot.history(settings, limit)


@app.get("/api/market/cmc")
async def market_cmc(symbol: str = "BNB", convert: str = "USD") -> dict:
    try:
        return await cmc.quote(settings, symbol.upper(), convert.upper())
    except cmc.CMCUnavailable as e:
        raise HTTPException(503, str(e))


@app.get("/api/market/price-check")
async def market_price_check() -> dict:
    """Atlas (on-chain) vs CoinMarketCap BNB/USD. Always 200; `ok` false means: block BNB-priced actions."""
    return await price_check.check(settings)


# ---------------------------------------------------------------- demo holder agent


def _require_agent() -> None:
    if not settings.enable_demo_agent:
        raise HTTPException(404, "demo agent disabled")


@app.get("/api/demo/personas")
def personas() -> list[dict]:
    _require_agent()
    return agent.list_personas()


@app.get("/api/demo/personas/{pid}/presentation")
def presentation(pid: str) -> dict:
    _require_agent()
    try:
        w = agent.load_wallet(pid)
    except KeyError:
        raise HTTPException(404, "unknown persona")
    return {"leafSaid": w["leafSaid"], "holder": w["aid"], "credentials": w["credentials"]}


class AgentSignReq(BaseModel):
    persona: str
    message: str


@app.post("/api/demo/agent/sign")
def agent_sign(req: AgentSignReq) -> dict:
    _require_agent()
    try:
        return agent.sign_with_persona(req.persona, req.message)
    except KeyError:
        raise HTTPException(404, "unknown persona")
