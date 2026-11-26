# vLEI-Gate on BSC Testnet: partial run (no launch)

Run on **2026-11-25** against the real BSC Testnet (chainId 97) with `scripts/testnet_partial.py`, using the deployed
contracts from `contracts/deployments/97.json` and the live Flap Portal.

**Why partial:** at the time of this run Flap had not enabled `VLEILauncherFactory` on the Portal
(`launcherFactoryMultiplier(factory) = (false, 10000)`; all three launcher factories were enabled on 2026-11-26, see the end of this file), so the Portal's launch floor is about $1,500, i.e. about
2.14 tBNB at the Portal's $700 BNB price. With ~0.5 tBNB available the 2.3 BNB target is not reached, so the
`launch` and `claim` steps are not part of this run. Every contribution stays recoverable.

| Item | Value |
| --- | --- |
| Demo launcher (beacon proxy) | [`0x721765B1022145ebE90ba7B06FBB06C942965d92`](https://testnet.bscscan.com/address/0x721765B1022145ebE90ba7B06FBB06C942965d92) |
| Config | name `vLEI Demo Treasury`, symbol `VLDT`, target 2.3 BNB ($1,610 at $700), sale 3600 s, cap $1,000 per entity |
| Salt / predicted token | `0x7f2db57a44f7485c50ac6c64ab237616168f1a9159e06086c05a0ccc54c2f436` → `0xD6f4808bfD2FCaCa1F71eA8EdA49ca7Ce4137777` (created only at launch) |
| Sale deadline | 1795610278 (2026-11-25 12:37:58 UTC) |
| Price feed | `MockPriceFeed` set to $700 (at the time of this run; the Atlas signed feed went live on 2026-11-26, see the end of this file) |

## Wallets

| Persona | Address | Credential |
| --- | --- | --- |
| deployer (registry admin, feed owner) | `0x219795b90ea283ca8a2511b0752d8a2d2AE7A9Ef` | – |
| alice | `0xdF607926654E21e188c8c8CFB120CBD49c282246` | OOR, authorized officer (CEO) |
| bob | `0xa8A215c7c71830F8aC068Bae60CD408463C6e181` | ECR |
| erin | `0x99Db2c98C52139bDf24ae78C6AB81437E2eEd44C` | OOR (same legal entity as bob) |
| outsider | `0x32bE4D85B1bDF59B6E5639E9350693ff5232A229` | none (unverified) |

## Transactions

| # | Step | Tx | Result |
| --- | --- | --- | --- |
| 1a | deployer funds alice 0.02 tBNB | [`0x6a3d629a…230666`](https://testnet.bscscan.com/tx/0x6a3d629a6b9052e44f4e9b40a8588a2b9c43b3788f0ee459740d38f8e5230666) | success |
| 1b | deployer funds bob 0.12 tBNB | [`0xaac1a28c…dbb572`](https://testnet.bscscan.com/tx/0xaac1a28c65f3e2330913960e95c4cd6d3b560ab2860f2634af0e077f92dbb572) | success |
| 1c | deployer funds erin 0.03 tBNB | [`0xd912ca3e…17e12e`](https://testnet.bscscan.com/tx/0xd912ca3e6a680456fc459dafab648b3c4a6248b8bc78770c2d80a52d7417e12e) | success |
| 1d | deployer funds outsider 0.002 tBNB | [`0x86669483…8b6bb4`](https://testnet.bscscan.com/tx/0x866694838cf402782c8b167ecd038a8bcab9a9fb10cd7d524a1ef8a2258b6bb4) | success |
| 2 | `MockPriceFeed.setAnswer(70000000000)` ($600 → $700) | [`0xe615de72…d892a9`](https://testnet.bscscan.com/tx/0xe615de72471df5cf63709103059616364a0346f53f0ebd03b342244898d892a9) | success |
| 3 | alice: verifier `action=launch` OK (role 3, OOR officer) → `registry.register` | [`0x27d99557…e2178f`](https://testnet.bscscan.com/tx/0x27d995576b220123270d9acdfd1eb093c21e25a2648aa669809cb36d25e2178f) | success |
| 4 | bob: verifier `action=invest` OK (role 1, ECR) → `registry.register` | [`0x67c16076…eff184`](https://testnet.bscscan.com/tx/0x67c16076fb2ea22483f1575a35073ad2235cc687f6dc7a5f9a4af014c3eff184) | success |
| 5 | erin: verifier `action=invest` OK (role 2, OOR) → `registry.register` | [`0x5a2ffc81…ac37ca`](https://testnet.bscscan.com/tx/0x5a2ffc811ec17ec5e454218d2a86b46c0689e1650d61abce20cd39da2eac37ca) | success |
| 6 | alice: `Portal.newLauncher(factory, VLEIMintConfig)` + 0.005 SALT_LOCK_FEE → launcher `0x721765B1…65d92` | [`0xd5c9a0dc…908fda`](https://testnet.bscscan.com/tx/0xd5c9a0dcdb37b989f2b514f09f324879f8b80d79bbb85e45cfe7f1e370908fda) | success |
| 7 | outsider (unverified): `contribute()` 0.001 BNB, gas limit 300000 | [`0xaa61aeaa…939c41`](https://testnet.bscscan.com/tx/0xaa61aeaafa051fb24eb81169785df8eac19803e7ceb440b34030cce596939c41) | **reverted as expected** (`NotVerified()`) |
| 8 | bob: `contribute()` 0.1 BNB | [`0x98a9dbd0…dd41ed`](https://testnet.bscscan.com/tx/0x98a9dbd03806a6b0580f2c9a0b9b7209915422f1024c81d13d90bf47b6dd41ed) | success |
| 9 | erin: `contribute()` 0.02 BNB → raised 0.12 / 2.3, status Raising | [`0x1704bf43…53a6b9`](https://testnet.bscscan.com/tx/0x1704bf432c958c8d09fbc82fb8d981df4eb2fa414bf2b84dae1e8500bd53a6b9) | success |
| 10 | admin: `revokeWallet(bob, "demo: TEL revocation")` → `vleiStatusOf(bob) = 3` | [`0xa1b6822b…c3f9a5`](https://testnet.bscscan.com/tx/0xa1b6822bd1a01801bfa215f7b329105d48408e4e62b459fe17a5c5bbd4c3f9a5) | success |
| 11 | bob: `withdrawContribution()` → +0.1 BNB (balance delta 0.099994 after gas) | [`0x32eca640…e02332`](https://testnet.bscscan.com/tx/0x32eca640212bf74caed05fabda6af4919f9dfae1deac765e346e57839ce02332) | success |
| 12 | verifier (HTTP only): alice's credentials, holder challenge signed by mallory's AID | – | **rejected as expected** at `holder` ("holder-AID signature mismatch: presenter does not control the credential's AID") |

After step 11 the launcher holds erin's 0.02 BNB (raised 0.02). Erin can `refund()` once the sale deadline has passed
(`backend/.venv/bin/python scripts/testnet_partial.py refund`).

## Cost

| | tBNB |
| --- | --- |
| Gas for all 14 txs (0.1 gwei) | 0.000172 |
| `SALT_LOCK_FEE` (non-refundable, paid to the Portal) | 0.005 |
| **Total spent** | **0.005172** |
| Recoverable in the launcher (erin, after the deadline) | 0.02 |

Balances after the run: deployer 0.327283, alice 0.014926, bob 0.119958, erin 0.009969, outsider 0.001993,
launcher 0.02 (start: deployer 0.499301, all others 0).

## Not done in this run (superseded)

This BNB run stopped before the launch. Launch, graduation, `claim`, gated vault yield and the post-launch revocation
checks were all done later in the [full USDT run](#full-usdt-launch-vault-factory) below, on the v2 vault factory,
without Flap enabling any factory (Portal v1.2.0 does not require it).

---

# Full USDT launch (vault factory)

Run on **2026-11-25** against the real BSC Testnet (chainId 97) with `scripts/testnet_full_usdt.py`. It mirrors
`contracts/test/fork/VLEIUsdt.BSCTest.fork.t.sol` and uses the v2 factories from
`contracts/deployments/97-usdt.json`. The quote is Flap's mock USDT, the launcher is the **vault** variant
(Burn 10 / LP 15 / VAULT 75), and the factories were not enabled at the time (Portal v1.2.0 does not require that; enabled on 2026-11-26). The whole
journey ran: launch, graduation, claim, gated vault yield in USDT, revocation and eviction. The run was first
rehearsed on an anvil fork with the same keys and gave identical amounts.

| Item | Value |
| --- | --- |
| `VLEIVaultLauncherFactoryV2` | [`0xEA3d889e5EA5f684268cDEcc45CE77322F0D9CeD`](https://testnet.bscscan.com/address/0xEA3d889e5EA5f684268cDEcc45CE77322F0D9CeD) (paired `VLEIDividendVaultFactoryV2` [`0x3C90…9c03`](https://testnet.bscscan.com/address/0x3C90db983d2eE6D3aa8fD88d6CF5Ae8535d49c03)) |
| Launcher (beacon proxy) | [`0x9fEE3844a9E0D38A10E9cC53Adb6c7FFa4F08f27`](https://testnet.bscscan.com/address/0x9fEE3844a9E0D38A10E9cC53Adb6c7FFa4F08f27) |
| Token (Flap tax token, `…7777`) | [`0xa27228Eec1d484A32aDD3AfCEb2Ad01cc6b07777`](https://testnet.bscscan.com/address/0xa27228Eec1d484A32aDD3AfCEb2Ad01cc6b07777) (= the CREATE2 prediction from salt `0x288a0655…a199decd`) |
| Gated vault (`VLEIDividendVaultV2`, quote USDT) | [`0xE45AdBf496Ad04145fC60bB756bf1917dF642433`](https://testnet.bscscan.com/address/0xE45AdBf496Ad04145fC60bB756bf1917dF642433) (= `Portal.getLaunchVault(token)`, factory `0x3C90…9c03`) |
| DEX pool | [`0x041595d7EAb3279d7caF762420Bca33359b75643`](https://testnet.bscscan.com/address/0x041595d7EAb3279d7caF762420Bca33359b75643) |
| TaxProcessor | [`0x11BaF3D431372BA739E954cD8d19EBA36AFC5ed3`](https://testnet.bscscan.com/address/0x11BaF3D431372BA739E954cD8d19EBA36AFC5ed3) |
| Quote | mock USDT [`0x190C989D5665a0e404B444b53CAE9AbCfb600157`](https://testnet.bscscan.com/address/0x190C989D5665a0e404B444b53CAE9AbCfb600157) (18 decimals, 1 USDT = $1) |
| Config | name `vLEI Demo Treasury`, symbol `VLDT`, target 3,000 USDT, sale 86,400 s, cap 2,000 USDT per entity |
| Launch | block 144812744, `FlapTokenGraduated` **emitted** (3,000 USDT ≥ graduation floor), no `LaunchFailed`, 4,758,318 gas (tx limit 9M ≥ `MIN_LAUNCH_GAS` 7M) |

Wallets as in the partial run above. Alice (OOR CEO, entity Siam) and erin (OOR, entity Andaman) were still active
from the earlier run, so they were not registered again. Bob (ECR, Andaman) had been revoked earlier: he was verified
again through the backend (on a temp copy of `backend/data`) and re-registered, which cleared `walletRevoked`.

## Transactions

| Step | Action | Tx | Result |
| --- | --- | --- | --- |
| 0 | fund outsider 0.003007 tBNB | [`0xc21b44a3…5a78ba`](https://testnet.bscscan.com/tx/0xc21b44a3fae7129c46f0bb2e6d509a7f0c69dae0e0bed2223a05d575ed5a78ba) | success |
| 1 | mint 1500 USDT to alice | [`0xeb0cbec3…9fba2d`](https://testnet.bscscan.com/tx/0xeb0cbec3971625801e8d88d108abe5459e257b9e9cef35a0d402cc4c799fba2d) | success |
| 1 | mint 2000 USDT to bob | [`0xece125c7…5dae56`](https://testnet.bscscan.com/tx/0xece125c79efb60fe09858f3a69aa08a0bcd251c1c0c0f3e9ba1107b5c75dae56) | success |
| 1 | mint 1000 USDT to erin | [`0x50db747c…aa3edd`](https://testnet.bscscan.com/tx/0x50db747cc2073355273fb0f77fe0918f7c8eef5b6268e22d1c4a8cbfccaa3edd) | success |
| 1 | mint 500 USDT to outsider | [`0x417691fa…7bb0d0`](https://testnet.bscscan.com/tx/0x417691fa97ed5b49a790acde41057ef4b207d2a8465b25c089bdf7991c7bb0d0) | success |
| 2 | bob register (invest) | [`0x99c35ba2…e1dc63`](https://testnet.bscscan.com/tx/0x99c35ba2d5d75fe16581d573a6d97947644a3759b2c316b902e8508f8ee1dc63) | success |
| 3 | alice Portal.newLauncher(vaultLauncherFactory) | [`0xd4edfad7…94f4e5`](https://testnet.bscscan.com/tx/0xd4edfad7e38f4f7381e3696d774ea074397f48d35c73560ac7efdc3cad94f4e5) | success; launcher 0x9fEE3844a9E0D38A10E9cC53Adb6c7FFa4F08f27 |
| 4 | outsider approve 500 USDT to launcher | [`0xb8b53786…8cff08`](https://testnet.bscscan.com/tx/0xb8b53786e52ade5163afdee289a6556953ca29a1251c4cc21e1b36dd2f8cff08) | success |
| 4 | outsider contribute() | [`0x07b7f61e…7b4e8d`](https://testnet.bscscan.com/tx/0x07b7f61ebebe2bb3004a285d870539c3fdadf6fd0ac7fe7f7362b6e8127b4e8d) | **reverted as expected** (`NotVerified()`) |
| 5 | bob approve 1500 USDT to launcher | [`0xaef46085…91107a`](https://testnet.bscscan.com/tx/0xaef460855f394fdaf4be6adba0cb7738c753ba99cacc103c0ebd49da6691107a) | success |
| 5 | bob contribute() | [`0xad7caa68…8f57ed`](https://testnet.bscscan.com/tx/0xad7caa6885985530f2e0f92549dca3599ffac6641d986d0bd9e59169788f57ed) | success; pulled 1,500.000000 USDT (previewContribute said 1,500.000000); raised 1,500.000000 |
| 5 | erin approve 1000 USDT to launcher | [`0x99040297…5973cf`](https://testnet.bscscan.com/tx/0x990402971de0ba0b1b1ba48b3b01c6c0654cbf935f5e46005f98c69b795973cf) | success |
| 5 | erin contribute() | [`0xdd11183c…18eb34`](https://testnet.bscscan.com/tx/0xdd11183ca6ade886400aefc4ea5b5e584b12fcdae30c37ab2be1fb3d7518eb34) | success; pulled 500.000000 USDT (previewContribute said 500.000000); raised 2,000.000000 |
| 5 | erin contribute() again (entity cap) | [`0xed9a9dc9…c89afc`](https://testnet.bscscan.com/tx/0xed9a9dc9fa080e5488b715ba0cf923f29515bb722092c0204e977dd33ac89afc) | **reverted as expected** (`EntityCapReached`); reverted EntityCapReached(2000e18, 2000e18): Andaman entity (bob + erin) at its 2,000 USDT cap |
| 5 | alice approve 1000 USDT to launcher | [`0x27398161…73630a`](https://testnet.bscscan.com/tx/0x2739816162e1c3015abea15ceb7458258db09c07e1767036db2d1fb18373630a) | success |
| 5 | alice contribute() -> launch | [`0x726e10d1…2d905f`](https://testnet.bscscan.com/tx/0x726e10d11225a21299b8a709c80237afb5a423541ab423610a5a016c4c2d905f) | success; launched; gasUsed 4758318; FlapTokenGraduated emitted |
| 6 | bob launcher.claim() | [`0x6b6f84d9…f53e4e`](https://testnet.bscscan.com/tx/0x6b6f84d93876948cbf84a48c6cbd893a8887fb636f52757b7ae991267ff53e4e) | success; bob token balance 250,000.000000 |
| 6 | bob approve tokens to vault | [`0xed1637ee…b4cfd0`](https://testnet.bscscan.com/tx/0xed1637eec6c4cc9f3bc3d039ad7b51152285e052dd4605d033a6b80fdcb4cfd0) | success |
| 6 | bob vault.stake(250,000.000000) | [`0xf88f401b…dcba5c`](https://testnet.bscscan.com/tx/0xf88f401b6c20929ab6333576faeab16f93016ba98b7a506efbecf37671dcba5c) | success |
| 6 | erin launcher.claim() | [`0x95cd66a7…87475d`](https://testnet.bscscan.com/tx/0x95cd66a73b2d9e0196b42b5be10e2d5bdf0b59564d881dbb4ad9f7c0bd87475d) | success; erin token balance 83,333.333333 |
| 6 | erin approve tokens to vault | [`0x43f5e148…17cf93`](https://testnet.bscscan.com/tx/0x43f5e1489c5ed63fad438ab00f05efce20b9081c0e6125bfcf763867c617cf93) | success |
| 6 | erin vault.stake(83,333.333333) | [`0x5d4c22e8…3885e2`](https://testnet.bscscan.com/tx/0x5d4c22e85eec2b52ddad009dbd8a7add7c0ebc2040441cd978d16aac3d3885e2) | success |
| 6 | alice launcher.claim() | [`0x80e36329…a65a41`](https://testnet.bscscan.com/tx/0x80e3632973d7641ba841a4f1cd9174bc9a1e0c5e570be4347216f55d4ba65a41) | success; alice token balance 166,666.666667 |
| 6 | alice approve tokens to vault | [`0x41f75e4d…306cf8`](https://testnet.bscscan.com/tx/0x41f75e4df4b373caf58b1f60f650d7976ca81fbb5f2866a4a7300b0ed2306cf8) | success |
| 6 | alice vault.stake(83,333.333333) | [`0xae716c37…7e447b`](https://testnet.bscscan.com/tx/0xae716c378a4a0fddb5455ad2fc23e27f35e5e2212c531cbd203bf7dc857e447b) | success |
| 7 | outsider approve USDT to router | [`0x21f8bc92…3c9804`](https://testnet.bscscan.com/tx/0x21f8bc9208e708e301f54fd64c9534714fa2aa59b760324bdb0c51a5613c9804) | success |
| 7 | outsider approve token to router | [`0x6e31b273…21c0b7`](https://testnet.bscscan.com/tx/0x6e31b2736dde65674f2a075ca760a5f4fc8b5850239c9aa3706e37900721c0b7) | success |
| 7 | outsider buy: 500.000000 USDT -> token | [`0x956261bf…e5f2d1`](https://testnet.bscscan.com/tx/0x956261bf34d392497840a823e8e2ebc2f513a6bd61b703ac4acfc61789e5f2d1) | success; outsider token balance 69,107.474632 |
| 7 | outsider sell #1: 30% tokens | [`0x19c5a642…59825c`](https://testnet.bscscan.com/tx/0x19c5a642d876f46e8b2a3d100186d57a23be976d7641070b2bb30c90b559825c) | success |
| 7 | TaxProcessor.dispatch() (by outsider) | [`0x6f840f9f…d4ec4f`](https://testnet.bscscan.com/tx/0x6f840f9f8139e2abb179f05600b6c903739b5028d18310d46707ee0447d4ec4f) | success; only the LP slot (2.467710 USDT) was left to pay; the vault's 12.338552 USDT had already been dispatched by a Flap keeper (see note) |
| 8 | admin revokeWallet(erin) | [`0x74b03f92…bcc26a`](https://testnet.bscscan.com/tx/0x74b03f9257c7933ed6c0600c77ff4d54f41d9c1b0b8357601c8eef4f7fbcc26a) | success |
| 8 | erin vault.claim() | [`0x0d908da6…faefaa`](https://testnet.bscscan.com/tx/0x0d908da6853ca5c9c585be310bca0fb4e6852076e016570510d4eacf5dfaefaa) | **reverted as expected** (`NotVerified()`) |
| 8 | bob vault.evict(erin) | [`0x8dfe526d…a334ef`](https://testnet.bscscan.com/tx/0x8dfe526d8c0a502b163657f5e2e38a0c8712e6f384c051e5ab25d004e0a334ef) | success; erin's 83,333.333333 tokens returned (balance +83,333.333333); 2.467710 USDT rewards forfeited to the remaining stakers (pending before 2.467710) |
| 9 | bob vault.claim() | [`0x0fd77dcd…23d843`](https://testnet.bscscan.com/tx/0x0fd77dcdc0b8e29beff85705751f35d595248266e2e866f8dce05bcc4523d843) | success; bob received 9.253914 USDT (pending was 9.253914) |
| 9 | outsider approve tokens to vault | [`0xf949f2d3…2ebd2f`](https://testnet.bscscan.com/tx/0xf949f2d35cf9dafc4a75ca3bd6a16b622591cdd69be5b638ad4e8cd1f52ebd2f) | success |
| 9 | outsider vault.stake(24,187.616121) | [`0x2e9a7a52…339724`](https://testnet.bscscan.com/tx/0x2e9a7a52db125f1318ab2c639ec45d0027d9f6ce8750e146bc65026596339724) | **reverted as expected** (`NotVerified()`) |
| 10 | outsider token.transfer(deployer, 1) | [`0x869d1962…0f1ef4`](https://testnet.bscscan.com/tx/0x869d19622f2f87f2944fb074d21b91b6fef7a424cbd3c79920b20c58af0f1ef4) | success |

## Results

- **Gate at contribution:** the unverified outsider, with a 500 USDT allowance, was refused with `NotVerified()`.
- **Entity cap (2,000 USDT per LEI):** bob 1,500 + erin's approval of 1,000 → the no-argument `contribute()` pulled
  only **500** from erin (the cap left for Andaman). Erin's second `contribute()` reverted with
  `EntityCapReached(2000e18, 2000e18)` while she still had a 500 USDT allowance. Alice (Siam) supplied the final 1,000.
- **Launch:** alice's contribution reached 3,000 USDT and launched the token in the same tx. The launcher holds 0 USDT
  afterwards (the Portal pulled the whole raise), and `FlapTokenGraduated` was emitted.
- **Claims** (500,000 tokens pro rata to 3,000 USDT): bob 250,000, erin 83,333.33, alice 166,666.67.
  **Staked (at the end of the run):** bob 250,000, erin 83,333.33, alice 83,333.33 (half), for a total of 416,666.67, well above
  `HELD_RELEASE_MIN_STAKE` (10,000).
- **Tax → vault in USDT:** about 10 minutes after the launch (the fork test's `vm.warp(+601)`), the unverified outsider
  bought with 500 USDT (69,107.47 tokens), then sold 30% (proceeds 151.93 USDT). That sell liquidated the tax.
  **12.338552 USDT** reached the vault and was fully recognized (`totalRevenue` = 12.338552). Bob, erin and alice
  had 7.403131, 2.467710 and 2.467710 USDT pending.
- **Revocation:** after `revokeWallet(erin)`, erin's `vault.claim()` reverted with `NotVerified()`. Bob's
  `evict(erin)` **returned her 83,333.33 tokens** and **forfeited her 2.467710 USDT** to the remaining stakers
  (`totalForfeited` = 2.467710).
- **Yield:** bob claimed **9.253914 USDT** (7.403131 of his own + 3/4 of erin's forfeit). At the end of the run alice had 3.084638 USDT
  pending, unclaimed (= the vault's remaining balance; she has claimed it since). The vault's books close exactly: claimed 9.253914 +
  balance 3.084638 = revenue 12.338552.
- **Gate at staking:** the outsider approved the vault and called `stake(24,187.6)`, which reverted with `NotVerified()`.
- **Known limitation:** the token itself is not gated. The outsider bought it on the DEX and transferred 1 token to
  another unverified wallet (the deployer).

**Note on dispatch:** a Flap keeper dispatched the tax first. Four blocks after our sell (block 144814144), keeper
EOA `0xB5b631ecfe0417e2F035EB34b6A0d2ab65242a1C` called `batchDispatch(address[])` on
`0x9eaFA518617880D4D9e472D7A29a96842FFc3aee`
([`0xc7501455…a99728`](https://testnet.bscscan.com/tx/0xc75014554ee1a56ab859ea488fc2b4f02b8312d9ea8696ac2fee5de2f2a99728)),
which paid the vault its 12.338552 USDT and woke it (`RevenueReceived`). Our permissionless `dispatch()` then paid
out only the remaining LP slot. On the fork no keeper exists, so the test's own `dispatch()` delivers the vault share.

## Cost

| | tBNB |
| --- | --- |
| Gas for all 37 txs (0.1 gwei) | 0.000947 |
| `SALT_LOCK_FEE` (non-refundable, paid to the Portal) | 0.005 |
| **Total spent** | **0.005947** |
| Moved between own wallets (deployer → outsider top-up, not spent) | 0.003007 |

Balances after the run: deployer 0.321565, alice 0.009336, bob 0.119837, erin 0.009887, outsider 0.004874
(start: 0.324600, 0.014926, 0.119958, 0.009969, 0.001993). State (no keys): `logs/testnet/testnet_full_usdt_97.json`;
console log: `logs/testnet/testnet_full_usdt_97.log`.
Rerun or resume: `backend/.venv/bin/python scripts/testnet_full_usdt.py` (finished steps are skipped). Rehearse on a
fork with `FULL_RPC=http://127.0.0.1:<anvil port>`.

## Later maintenance

| Date | Step | Tx | Result |
| --- | --- | --- | --- |
| 2026-11-26 | `MockPriceFeed.setAnswer(55206106489)` ($700 → $552.06, aligned with the live CoinMarketCap BNB price) | [`0x919b29d0…0e282c3f`](https://testnet.bscscan.com/tx/0x919b29d025f80d91f3c2971abc982f567cde6558dd70ef8854bb1d16e0282c3f) | success |
| 2026-11-26 | Deploy `AtlasSignedFeed` `0x34aa570cDa23282af94aA3CE4232bD4B18B644d5` (owner = deployer, `atlasSigner` = Atlas `0x59eD…C600`, `feedId` = 0 / unset) (`script/DeployAtlasFeed.s.sol`) | [`0x956d6403…e31f7a52`](https://testnet.bscscan.com/tx/0x956d64031e10b0bb0db273563cc1c8d9d044d3bbd5cecfa8b4a26ab6e31f7a52) | success |
| 2026-11-26 | Deploy `VLEILauncherFactoryV2` `0x394928211B03Eb74a6f7061a56973F77A7fC48a4` (native BNB quote, `priceFeed` = `AtlasSignedFeed`, `maxPriceAge` 3600; also creates launcher impl `0x9e03a4C1800dcD775bAb42Bf8e0F899c91CC8Ef5` and beacon `0xE6E5FbEF9E88BB63734081b60BCedA7FCe62065c`) | [`0x10c31f65…f7799ecc`](https://testnet.bscscan.com/tx/0x10c31f65eb14fd64443635cf730c1e0b1823888f78bd836fcb078b42f7799ecc) | success |
| 2026-11-26 | `AtlasSignedFeed.setFeedId(633)` (Atlas BNB/USD; matched exactly against Atlas' BSC-mainnet `bnb/usd` push feed on 12/12 updates) | [`0xc44b3231…4fc09c4a`](https://testnet.bscscan.com/tx/0xc44b3231010001640699ba5256ad83ecf16e978c98c558c799462b084fc09c4a) | success |
| 2026-11-26 | First real Atlas price: `submit(payload, signature)` → $559.29 (consensus HEALTHY) via `scripts/push_atlas_price.py` | [`0xd641ffcd…e6dbfc38`](https://testnet.bscscan.com/tx/0xd641ffcdcf6da68ec03dd3c8934bd6e3880962eb5f23cbbe87dfadd7e6dbfc38) | success |

The two deployments cost 0.00069 tBNB and are verified (exact match) on Sourcify and BscScan; addresses are in
`contracts/deployments/97-atlas.json`. **Update:** real Atlas prices are live since 2026-11-26 (feedId 633, rows above). Original note: no Atlas price had been pushed at deploy time (no `ATLAS_API_KEY`, and the Atlas
feedId of BNB/USD is not in the public docs), so `latestRoundData()` returns zeros and the new factory's
`quoteUsd` / `newLauncher` revert `InvalidPrice` until `scripts/push_atlas_price.py --set-feed-id` has run. The script
was rehearsed on an anvil fork with the signed example from the Atlas docs (feedId 624): `setFeedId` + `submit`
succeeded, a replay was skipped, and the factory then reverted `StalePrice` as expected for a months-old price.

## Atlas-priced BNB launch (2026-11-26)

`scripts/testnet_atlas_bnb.py` (state: `logs/testnet/testnet_atlas_bnb_97.json`) shows the Atlas BNB/USD price
(feedId 633, `AtlasSignedFeed` `0x34aa…44d5`) doing the USD accounting of the native-BNB factory
`VLEILauncherFactoryV2` `0x3949…48a4` (`minTargetUsd` $1,600, `maxPriceAge` 1 h). Atlas price at the run: $559.97.

| # | Action | Tx | Result |
|---|---|---|---|
| 1 | alice `Portal.newLauncher` with a **1 BNB** target (Atlas: ~$560 < $1,600) | [`0xfa6fcbaf…5d351a5c`](https://testnet.bscscan.com/tx/0xfa6fcbafc0f52032bf97841ac0852f4b6e10937f8f6d81bc47b5cb955d351a5c) | **reverted as expected** (`TargetBelowMinimum`) |
| 2 | alice `Portal.newLauncher` with a **3.2 BNB** target (Atlas: $1,791.90), cap **$10 per entity** → launcher [`0x206dB9B3b73Ca3f57a0cB1C8C3fc83cFDfcD609b`](https://testnet.bscscan.com/address/0x206dB9B3b73Ca3f57a0cB1C8C3fc83cFDfcD609b), token `0x1FbB…7777` | [`0x567695e6…a1e2344e`](https://testnet.bscscan.com/tx/0x567695e6da548b3204a7954ab8f3a091a5e1091371b77f1483883a96a1e2344e) | success |
| 3 | alice `contribute()` 0.01 BNB (Atlas: ~$5.60) → `remainingCapUsd` $4.40 | [`0x9a47c34c…8d8d7a8d`](https://testnet.bscscan.com/tx/0x9a47c34c51a057f3c98fc279d77fb52414634ced8db123adcab074688d8d7a8d) | success |
| 4 | alice `contribute()` 0.01 BNB again (Atlas-valued total ~$11.20 > $10 cap) | [`0x0ac3a496…eb19a980`](https://testnet.bscscan.com/tx/0x0ac3a49672169b30185a5bcaaaf04a9050da65741b129e91ea81934aeb19a980) | **reverted as expected** (`CapExceeded`) |

The price is kept fresh by `scripts/atlas_keeper.sh` (runs `scripts/push_atlas_price.py` every 30 minutes) during the demo; with a price
older than 1 h the same calls revert `StalePrice` (fail-safe).

## Flap factory enablement (2026-11-26)

Flap's testnet helper `LauncherFactoryWhitelister` `0x77779969a11eff7582f3bCf48135A846A3457777` (verified on BscScan;
`PORTAL()` = `0x0000…0000` Portal; calls `setLauncherFactoryMultiplier(factory, 10000, true)`), called from the deployer:

| Factory | Tx | `launcherFactoryMultiplier` after |
|---|---|---|
| v1 `VLEILauncherFactory` `0x279141bABEEEFF178E7ADad7db131Eb48763Eb3b` | [`0xa41bf4b7…6d046652`](https://testnet.bscscan.com/tx/0xa41bf4b7679242c3b0094cf08e545e7fbf1e41d6ad1f0cdaddf8c59e6d046652) | `true, 10000` |
| v2 `VLEIVaultLauncherFactoryV2` `0xEA3d889e5EA5f684268cDEcc45CE77322F0D9CeD` | [`0x77dec1f7…18886212`](https://testnet.bscscan.com/tx/0x77dec1f770f36bba07139dd86bcea3ce8e37b77495d9f63ab35431dd18886212) | `true, 10000` |
| v2 `VLEILauncherFactoryV2` (BNB, Atlas) `0x394928211B03Eb74a6f7061a56973F77A7fC48a4` | [`0x7a64226b…9650b9`](https://testnet.bscscan.com/tx/0x7a64226beb9ee245dd4a068f8b01ac134f5814419575a30cbfb9bea4ce9650b9) | `true, 10000` |

The vault factory `VLEIDividendVaultFactoryV2` `0x3C90db983d2eE6D3aa8fD88d6CF5Ae8535d49c03` still reads
`vaultFactoryMultiplier` = `false`; the helper only covers launcher factories, so it is requested from Flap.

