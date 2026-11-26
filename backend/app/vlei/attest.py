"""EIP-712 attestations accepted by VLEIRegistry.register()."""
from __future__ import annotations

from eth_account import Account
from eth_account.messages import encode_typed_data
from eth_utils import keccak

DOMAIN_NAME = "vLEI-Gate Registry"
DOMAIN_VERSION = "1"

ATTESTATION_TYPES = {
    "Attestation": [
        {"name": "wallet", "type": "address"},
        {"name": "leiHash", "type": "bytes32"},
        {"name": "role", "type": "uint8"},
        {"name": "nonce", "type": "uint256"},
        {"name": "expiresAt", "type": "uint64"},
    ]
}


def lei_hash(lei: str) -> str:
    return "0x" + keccak(text=lei.upper()).hex()


def sign_attestation(
    *, private_key: str, chain_id: int, registry: str, wallet: str, lei: str, role: int, nonce: int, expires_at: int
) -> dict:
    domain = {"name": DOMAIN_NAME, "version": DOMAIN_VERSION, "chainId": chain_id, "verifyingContract": registry}
    message = {
        "wallet": wallet,
        "leiHash": lei_hash(lei),
        "role": role,
        "nonce": nonce,
        "expiresAt": expires_at,
    }
    signable = encode_typed_data(domain_data=domain, message_types=ATTESTATION_TYPES, message_data=message)
    signed = Account.sign_message(signable, private_key=private_key)
    return {
        "domain": domain,
        "types": ATTESTATION_TYPES,
        "message": message,
        "signature": "0x" + signed.signature.hex().removeprefix("0x"),
        "signer": Account.from_key(private_key).address,
    }
