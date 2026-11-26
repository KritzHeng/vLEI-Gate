"""vLEI credential types and the role policy.

Schema SAIDs below mirror the GLEIF vLEI schema registry (WebOfTrust/vLEI).
Double-check them against the registry before verifying production credentials.
"""
from __future__ import annotations

import re

_LEI_RE = re.compile(r"^[0-9A-Z]{20}$")

QVI = "EBfdlu8R27Fbx-ehrqwImnK-8Cm79sqbAQ4MmvEAYqao"
LE = "ENPXp1vQzRF6JwIuS-mp2U8Uf1MoADoP_GqQ62VsDZWY"
OOR_AUTH = "EKA57bKBKxr_kN7iN5i7lMUxpMG-s19dRcmov1iDxz-E"
OOR = "EBNaNu-M9P5cgrnfl2Fvymy4E_jvxxyjb70PRtiANlJy"
ECR_AUTH = "EH6ekLjSr8V32WyFbGe1zXjTzFs9PkTYmupJ9H65O14g"
ECR = "EEy9PkikFcANV1l7EHukCeXqrzT1hNZjGlUk7wuMO5jw"

NAMES = {QVI: "QVI", LE: "LE", OOR_AUTH: "OOR-Auth", OOR: "OOR", ECR_AUTH: "ECR-Auth", ECR: "ECR"}

# On-chain role codes (must match VLEIRegistry).
ROLE_NONE = 0
ROLE_ECR = 1
ROLE_OOR = 2
ROLE_OOR_OFFICER = 3

ROLE_NAMES = {ROLE_ECR: "ECR", ROLE_OOR: "OOR", ROLE_OOR_OFFICER: "OOR (authorized officer)"}


def lei_checksum(base18: str) -> str:
    """Return a full 20-char LEI with ISO 17442 (ISO 7064 MOD 97-10) check digits."""
    base18 = base18.upper()
    assert len(base18) == 18 and base18.isalnum()
    digits = "".join(str(int(c, 36)) for c in base18) + "00"
    return f"{base18}{98 - int(digits) % 97:02d}"


def lei_is_valid(lei: str) -> bool:
    if not isinstance(lei, str) or not _LEI_RE.match(lei):
        return False
    return int("".join(str(int(c, 36)) for c in lei)) % 97 == 1
