# Ethereum deployment configuration

`ethereum.json` is the reviewable Ethereum mainnet input manifest for STRN and sSTRN. It is intentionally **unapproved and incomplete**. Nothing loads private environment files, substitutes a deployer, or broadcasts. Addresses belong in deployment configuration, not token implementations.

## Established governance configuration

| Field                              | Address / value                              |
| ---------------------------------- | -------------------------------------------- |
| Chain                              | Ethereum mainnet, chain ID 1                 |
| Default admin and ProxyAdmin owner | `0xfD5782E3BFF366601da3973aE30C583dE4F08A67` |
| Proposer and canceller             | `0x610182581C93687Ca03F4a8E7f124f8cEC616820` |
| Timelock minimum delay             | 432,000 seconds (five days)                  |
| STRN parameter manager             | The same admin timelock                      |

These assignments were verified at Ethereum block **25,950,120**: the timelock held DEFAULT_ADMIN_ROLE on USDat, sUSDat and its withdrawal queue; the proposer held proposer/canceller roles on that timelock, which allowed open execution. This is historical provenance, not a substitute for checking current membership, code and ownership before deployment. The sSTRN recipe assigns its parameter-manager role to this timelock as well.

The independent token default-admin transfer delay is **not** the timelock's minimum delay. It remains unset for each token. An explicitly selected zero is representable; null never means zero.

## Existing addresses to consider, not approved assignments

| Address                                      | Observed use at that block                                                                       | Candidate relevance                                                                          |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------- |
| `0x10D59F776db12b4B271b2609CB8b7Ddd0A82703B` | USDat pause, freeze, forced-transfer and whitelist roles; live sUSDat and queue compliance roles | Consider for explicitly approved pause/blacklist/seizure assignments                         |
| `0x09d6e34ce24d54890ff0bc6a090b5f880f8c729f` | USDat yield-recipient manager; live sUSDat and queue processor                                   | Operational precedent; not automatic release authority                                       |
| `0x3dc0Aa75a6FD01c3DCF9F6FDaf08308B6489F5b5` | USDat yield recipient and live sUSDat fee recipient                                              | Revenue destination only; not evidence of the intended STRN allocation or recovery recipient |

The live yield contracts used the older role interface. Yield V2's checked-in upgrade recipe had unapproved operational/recovery placeholders and expressly allowed corresponding vault/queue holders to overlap. USDat also had scripts proposing a forced-transfer-role move to the timelock, but that move was not reflected in the checked role membership. Recheck live state instead of treating a merged script as an executed assignment.

The manifest deliberately does not assign these candidates. Select STRN pause/resume/blacklist/seizure roles and sSTRN pause/resume/seizure/release roles explicitly. The same wallet may deliberately hold multiple roles or corresponding roles across contracts; document and approve that choice. No address comparison establishes independent signers. Existing wallet operators and custody controls must be confirmed separately.

Release uses RELEASER_ROLE immediately; seizure uses SEIZER_ROLE immediately. Their role grants and revocations remain administered by the timelock. Putting an operational role on a timelock would delay its use, so do not infer the resume or release holder from default administration.

## Validation and use

Validate the checked-in draft and regression checks:

```sh
python3 scripts/check-deployment-config.py --check-draft
python3 scripts/test-deployment-config.py
```

Before preparing a deployment, fill the selected section's null values and record its explicit approval. Choose separate nonzero salts for the two role batches. Then require readiness for that stage:

```sh
python3 scripts/check-deployment-config.py --ready strn
python3 scripts/check-deployment-config.py --ready staking
```

Both readiness commands intentionally fail for the checked-in draft. Flipping approval alone is insufficient: missing recipients/holders, malformed or zero addresses/salts, invalid durations, unexpected fields and duplicate JSON keys are rejected. The two stages have independent approval flags, so preparing STRN need not implicitly approve staking. `--config <path>` supports a separately reviewed copy; it must still target chain ID 1.

This manifest is a preflight input source, not a deployment script. The existing offline recipes continue to take explicit typed arguments and independently validate chain/timelock/role conditions. Passing arguments manually does not consult this JSON or its approval flags. Follow the readiness check when preparing a ceremony; no config-file flag can constrain a separately constructed transaction.

Map the manifest into the recipes as follows:

- `DeploySTRN.runWithRoles`: first supply the reviewed locked implementation from `DeploySTRNImplementation.run()`; pass `strn.allocationRecipient`, `strn.recoveryRecipient`, `strn.adminTransferDelaySeconds`, and a RoleConfig containing shared `chainId`, `timelock`, `proposer` plus the section's role holders and `salt`.
- `DeployStakedSTRN.run`: supply the independently verified STRN proxy and locked sSTRN implementation addresses. Its Config uses shared `chainId`, `timelock`, `proposer`, staking role holders and `salt`, with `durationSeconds` mapped to `duration` and `adminTransferDelaySeconds` mapped to `adminTransferDelay`.

Readiness validates local input completeness, not live chain state, final approval authority, wallet ownership, bytecode authenticity or deployment success. The offline recipes produce unsent role/custody batches; public distribution still requires the real grants and staking protection to be effective.

The approved initial staking duration is **120 days (10,368,000 seconds)**. This resolves the duration input only; approval flags remain false and other missing deployment inputs must still be supplied. Existing position maturities never change when future duration is updated.

STRN also requires an explicit `releaser` holder for immediate authorized release of seized balances; it is included as the sixth grant. The manifest keeps that holder unset. SEIZER_ROLE and recovery-wallet ownership do not grant release authority.
