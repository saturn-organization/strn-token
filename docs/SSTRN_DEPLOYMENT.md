# sSTRN offline deployment and product integration

The Ethereum input manifest and unapproved operator candidates are documented in [config/README.md](../config/README.md). Run its readiness check before preparing the explicit recipe arguments.

The recipes do not broadcast or sign transactions, and no sUSDat integration is implemented. The manifest contains public governance candidates, while operational inputs and production approvals remain incomplete. Use a reviewed existing STRN proxy and authentic five-day timelock on a chain supporting Cancun/EIP-1153. Confirm the timelock already administers STRN. The initial deployment duration is 120 days (10,368,000 seconds), recorded in config/ethereum.json. Pass it explicitly to the deployment recipe; the manifest does not automatically populate Solidity arguments. Future duration changes affect new stakes and renewals only, never existing unlock dates.

`script/DeployStakedSTRN.s.sol` takes explicit chain, timelock, proposer, pauser, unpauser, seizer, releaser, duration, admin-transfer delay and salt inputs. First create the locked implementation using the separate `DeployStakedSTRNImplementation.run()` helper. Then pass that reviewed implementation address into `DeployStakedSTRN.run(token, implementation, config)`, which deploys an atomically initialized transparent proxy, gives ProxyAdmin ownership and default administration to the timelock, and returns a six-operation batch:

1. Register the sSTRN proxy as protected STRN custody.
2. Grant staking PAUSER_ROLE to the emergency operator.
3. Grant staking UNPAUSER_ROLE to the recovery authority.
4. Grant staking SEIZER_ROLE to the enforcement authority.
5. Grant staking PARAMETER_MANAGER_ROLE to the timelock.
6. Grant staking RELEASER_ROLE to the release operator.

`releasePosition(id, recipient, redeemUnderlying)` is an immediate RELEASER_ROLE operation, with no per-release timelock. SEIZER_ROLE alone cannot release; DEFAULT_ADMIN_ROLE alone also cannot release without a grant. Role grants/revocations still pass through the timelock. STRN recovery-wallet rotation does not change recovery-held positions. Receipt release preserves the original lock; underlying release requires maturity. The rehearsal verifies both the delayed activation batch and immediate release by the configured release operator.

The returned schedule/execute calldata is unsent. It does not execute grants, bypass the five-day wait, or broadcast. Deposits fail until custody registration is effective. The rehearsal test executes the exact batch only after the delay and checks proxy ownership, role separation, custody registration and replay rejection.

The split helpers keep both runtime sizes below EIP-170. The implementation address is an explicit trusted input: verify its code identity. The recipe checks code presence, exact five-day delay, chain identity, selected proposer/canceller and open execution. These are sanity checks, not attestation of bytecode, complete membership, signer security or previously granted authority. Choose separately controlled pause/resume/enforcement/release addresses; the recipe does not assert that distinct addresses have independent signers. Parameter changes affect future positions only. Review initialization calldata, implementation bytecode, dependency pins and the full governance configuration before any separately authorized transaction.

## Consumer interface

Use `src/interfaces/IStakedSTRN.sol` for staking, renewal, redemption, position queries, ERC20 metadata/balances, voting and discount views. It also declares lifecycle events for indexers, including recovery and release. Receipt transfers/approvals still revert. Privileged operations are excluded from this consumer interface; their authorities and lifecycle remain defined by the implementation and security specification. Products needing only the percentage can keep importing the narrower `ISTRNDiscount`.

## Product-callable discount

Call `ISTRNDiscount.getFeeDiscountBps(beneficiary)` in the same transaction that determines the fee. Values are 0–2500, with 10,000 representing 100%. Calculate `savings = floor(nominalFee * discountBps / 10000)` using overflow-safe mulDiv, then charge `nominalFee - savings`. This applies to the WHOLE nominal fee, without a cost floor. Round savings down so integer rounding never makes the discount exceed the quoted percentage. Use the owner paying the fee, not an arbitrary caller-supplied rich account. Delegation does not transfer discounts.

For deposit-on-behalf, routers, delegated withdrawals and asynchronous redemption queues, the product must explicitly authenticate the beneficiary and use successful settlement as the eligibility timestamp for queued withdrawals. A quote can change before execution or expiry; do not cache it as a guaranteed entitlement. Products should not silently grant discounts when the call fails, nor interpret the read-only getter as consumption of a cap. The product decides how unavailable quotes affect liveness; this must be tested in its separate integration audit.

The test-only `DiscountProductFixture` illustrates full-fee math and zero/threshold/expiry behavior. It is not a product authentication, settlement or cap implementation. See [product fees and savings allowance](INTEGRATION_REQUIREMENTS.md#product-fees-and-savings-allowance) for the external accounting requirements, settlement rules and production inputs. The percentage getter implements no cumulative allowance and imposes no cost floor.

## Audit handoff

Review STRN, sSTRN, both offline deployment/role recipes, pinned parents, the discount interface and the documented cross-contract boundaries. Provide the exact final candidate revision and its generated package. Do not advertise combined liquid/sSTRN onchain governance, a season rewards distributor, a production fee cap or real vault integration as implemented. See [token deployment inputs](SSTRN_SPEC.md#verification-and-launch-gates) and [external integration inputs](INTEGRATION_REQUIREMENTS.md#production-integration-inputs).
