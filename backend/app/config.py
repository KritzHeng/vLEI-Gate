"""Runtime configuration, loaded from the repo-root .env (if present) and the environment."""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path

from dotenv import load_dotenv

BACKEND_DIR = Path(__file__).resolve().parent.parent
REPO_DIR = BACKEND_DIR.parent
DATA_DIR = Path(os.getenv("VLEI_DATA_DIR", BACKEND_DIR / "data"))
LOG_DIR = REPO_DIR / "logs"

load_dotenv(REPO_DIR / ".env")


def _csv(name: str, default: str) -> list[str]:
    return [s.strip() for s in os.getenv(name, default).split(",") if s.strip()]


def _deployment(chain_id: int) -> dict:
    p = REPO_DIR / "contracts" / "deployments" / f"{chain_id}.json"
    return json.loads(p.read_text()) if p.exists() else {}


def _pinned_root() -> str:
    env = os.getenv("PINNED_ROOT_AID", "").strip()
    if env:
        return env
    p = DATA_DIR / "root.json"
    return json.loads(p.read_text())["aid"] if p.exists() else ""


@dataclass
class Settings:
    chain_id: int = int(os.getenv("CHAIN_ID", "97"))
    verifier_private_key: str = os.getenv("VERIFIER_PRIVATE_KEY", "")
    registry_address: str = ""
    pinned_root_aid: str = field(default_factory=_pinned_root)
    attestation_ttl: int = int(os.getenv("ATTESTATION_TTL_SECONDS", str(24 * 3600)))
    challenge_ttl: int = int(os.getenv("CHALLENGE_TTL_SECONDS", "300"))
    # Official roles (OOR officialRole values) allowed to create pools.
    launch_roles: list[str] = field(
        default_factory=lambda: _csv(
            "LAUNCH_OFFICIAL_ROLES",
            "Chief Executive Officer,Chief Financial Officer,Chief Operating Officer,Managing Director,CEO,CFO,COO",
        )
    )
    # Local watcher store. WATCHER_URLS may list HTTP watchers in a later build.
    watcher_dir: Path = DATA_DIR / "watcher"
    watcher_urls: list[str] = field(default_factory=lambda: _csv("WATCHER_URLS", ""))
    cmc_api_key: str = os.getenv("CMC_API_KEY", "")
    cmc_base_url: str = os.getenv("CMC_BASE_URL", "https://pro-api.coinmarketcap.com")
    cournot_api_key: str = os.getenv("COURNOT_API_KEY", "")
    cournot_api_base: str = os.getenv("COURNOT_API_BASE", "https://interface.cournot.ai").rstrip("/")
    # Rate-risk question for the tokenized-Treasury offering and the Cournot market(s) it maps to (from /resolve).
    cournot_question: str = os.getenv(
        "COURNOT_QUESTION", "Will the 10-year US Treasury yield be above 4.74% on December 31, 2026?"
    )
    cournot_market_ids: list[str] = field(default_factory=lambda: _csv("COURNOT_MARKET_IDS", "2878523"))
    # Server-side throttle on live (quota-spending) calls.
    cournot_min_refresh_seconds: int = int(os.getenv("COURNOT_MIN_REFRESH_SECONDS", "300"))
    cournot_risk_threshold: float = float(os.getenv("COURNOT_RISK_THRESHOLD", "0.5"))
    cors_origins: list[str] = field(default_factory=lambda: _csv("CORS_ORIGINS", "http://localhost:3000"))
    # Demo-only: exposes signing with every persona's KERI keys. Never enable next to a real verifier key.
    enable_demo_agent: bool = os.getenv("ENABLE_DEMO_AGENT", "false").lower() == "true"
    rpc_url: str = os.getenv("RPC_URL", "")
    # Atlas BNB/USD signed feed (on-chain) cross-checked against CoinMarketCap.
    atlas_signed_feed_address: str = ""
    price_deviation_max_bps: int = int(os.getenv("PRICE_DEVIATION_MAX_BPS", "200"))
    price_max_age: int = int(os.getenv("PRICE_MAX_AGE_SECONDS", "3600"))

    def __post_init__(self) -> None:
        self.registry_address = os.getenv("REGISTRY_ADDRESS", "") or _deployment(self.chain_id).get("registry", "")
        atlas = REPO_DIR / "contracts" / "deployments" / f"{self.chain_id}-atlas.json"
        self.atlas_signed_feed_address = os.getenv("ATLAS_SIGNED_FEED_ADDRESS", "") or (
            json.loads(atlas.read_text()).get("atlasSignedFeed", "") if atlas.exists() else ""
        )


settings = Settings()
