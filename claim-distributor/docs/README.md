# AlphaNexus ClaimDistributor

`ClaimDistributor` holds one immutable ERC20 token and funds each distribution separately. Deploy it with the token address, a publisher, and an independent admin address. The publisher approves the distributor before calling `createDistribution`. Funding must increase the distributor's token balance by exactly `fundingAmount`; fee-on-transfer or rebasing behavior is unsupported.

Publisher changes require two transactions: the current publisher calls `transferPublisher(newPublisher)` to nominate a nonzero address other than the distributor itself, then that address calls `acceptPublisher()`. Until acceptance, the current publisher retains all publishing authority; the nominee has none. The current publisher can replace the nomination or call `cancelPublisherTransfer()` to clear it. Acceptance clears `pendingPublisher` and emits `PublisherTransferred`; nomination emits `PublisherTransferStarted`. Existing deployments with the one-step interface require a new deployment to adopt this behavior.

Build each Merkle tree with OpenZeppelin `StandardMerkleTree` using leaf types `uint256`, `address`, `uint256` and values `(index, account, amount)`. The on-chain leaf is:

```solidity
keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))))
```

The proof binds the allocation to `account`, while `distributionId` selects the root and claimed bitmap. The off-chain publisher must check that indices and accounts are unique within a distribution and that the allocations fit its funding. The contract does not store a full allocation list or impose a claim deadline.

- `claim` lets the proven account send its allocation to any nonzero recipient other than the distributor itself.
- `claimFor` lets anyone submit a proof, but sends tokens only to the proven account.
- `claimBatch` and `claimForBatch` consume several proofs atomically and transfer the total once.

The admin has three distinct emergency actions:

- `cancelDistribution(distributionId, recipient)` permanently cancels one distribution and sends its unclaimed `remainingAmount` to the recipient. Its root, claimed bitmap, and count remain recorded, and its ID cannot be reused. Other distributions and new publications stay available. Cancellation remains available after a global stop.
- `emergencyStop()` permanently stops all creation and claims without transferring tokens. It can take effect even if the token currently rejects outgoing transfers.
- `emergencyWithdraw(recipient)` permanently stops all creation and claims **and transfers the distributor's entire balance of its bound token** to the recipient. The admin can call it again after the stop to collect bound tokens sent to the contract later.

`renounceAdmin` permanently removes these emergency powers. After a global stop, it requires the bound-token balance to be zero; while active, it can still be called with funded batches, potentially leaving future unclaimable balances or mistaken transfers unrecoverable. Use separate publisher and admin signers so root publication and emergency actions remain independent. These admin powers can extinguish users' unclaimed allocations; disclose the policy to users and use appropriate admin controls before production.

If the bound token has additional compliance requirements, the distributor and each payout recipient must satisfy its transfer rules; token-level pauses and blacklists also apply.

`cancelDistribution` is atomic: if the token blocks its outgoing transfer, the batch remains active with its original balance. `emergencyWithdraw` is also atomic, so if its transfer fails on the first call, the global stop does not take effect; use `emergencyStop()` to stop immediately in that case. The token balance is a shared pool, while `remainingAmount` tracks each batch's entitlement; direct token transfers do not create a distribution. There is no separate surplus-recovery function: collecting directly sent bound tokens requires `emergencyWithdraw`, which stops every batch. Normal funding should always use `createDistribution`. Claims and emergency payouts reject the distributor's own address as recipient so a token self-transfer cannot consume an allocation without moving tokens.

Because `claimFor` and `claimForBatch` are permissionless, anyone with a valid proof can send an allocation to its account before that account chooses another recipient with `claim`. Contract accounts should be able to receive and manage this token.

## Public resources

- [Production source](../contracts/ClaimDistributor.sol)
- Third-party audit report: pending publication
- [Unit tests](../test/ClaimDistributor.t.sol)
- [中文说明](README.zh-CN.md)

The contract is deployed directly and has no proxy or upgrade entry point. Third-party audit reports will be published in `audits/` when available.
