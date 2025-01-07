# Opus Stabilizer

The Stabilizer is an implementation of incentivized Ekubo LP staking with yield coming from surplus debt minted into circulation periodically via the Equalizer. The first intended use is for a CASH/USDC pool.

Yin will be streamed to the Stabilizer contract as and when surplus is minted from the Equalizer. The contract keeps track of its yin balance for each user action, and the difference in yin balance is then distributed on the next user action.

The contract is intentionally limited in scope and constrained in functionality to make implementation easier and reduce the surface for exploits:
- In order to stake a LP token, it must correspond to the exact fee / tick spacing AND lower and upper price range.
- Each address can only stake one Position. If the address wants to modify its liquidity, then it needs to unstake, modify, and re-stake.
- Once staked, users can either (1) unstake and receive their Position NFT back; or (2) claim accrued yin streamed to the contract.
- There is no winding down mechanism for the Stabilizer. Instead, the Stabilizer contract should be removed as a recipient of surplus in the Allocator module. Therefore, there is no deadline for users who have staked to unstake or claim rewards even after a Stabilizer contract stops being a recipient of surplus.
- Following on from the previous point, there is no access control involved in this contract.
