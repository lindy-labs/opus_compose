# Opus Archabbot

The Archabbot is an Abbot — a trove manager — that extends the core functionality with support for **Rites** (attachable automation modules), **flash-loan-powered leverage**, and **automated LTV safety enforcement**.

It implements the same `IAbbot` interface, so all standard trove operations (deposit, withdraw, forge, melt, close) work identically. Troves are opened via the Abbot directly (open_trove is disabled on the Archabbot). The additional features the Archabbot provides are:

- **Rites**: attachable automation modules that execute predefined actions/strategies when conditions are met
  - **Keeper incentives**: permissionless execution with CASH rewards for keepers who trigger rites
  - **Per-trove safety configuration**: relative threshold and max forge fee to protect automated operations
- **Leverage**: flash-loan-powered lever up and lever down in a single transaction

## External Dependencies

| Contract | Role |
|---|---|
| **Shrine** | CASH token contract, health oracle, and forge/melt operations |
| **Sentinel** | Gateway contract handling collateral deposits/withdrawals |
| **Abbot** | Core trove manager (trove ownership, asset balances) |
| **Flash Mint** | EIP-3156 flash lender for leverage operations |
| **Ekubo Router** | DEX router for swaps (leverage and rites) |
| **Ekubo Core** | Pool price oracle (used by rites for swap quoting) |
| **Ekubo Oracle** | TWAP oracle (used by rites for sqrt ratio limit calculation to mitigate price manipulation) |

---

## Trove Configuration for Rites

Each trove managed by the Archabbot has a `TroveConfig` that applies to Rites:

| Field | Type | Description |
|---|---|---|
| `relative_threshold` | `Ray` | Safety multiplier on the trove's liquidation threshold. Effective max LTV = `relative_threshold * threshold`. Set to `RAY_ONE` (1.0) to disable. |
| `max_forge_fee_pct` | `Wad` | Maximum protocol fee the user accepts when CASH is forged. Cap: 4.0 (400%). Acts as slippage protection during automated rite execution. |
| `incentive` | `Wad` | CASH minted to the keeper who triggers a rite. Must be > 0 for keepers to have incentive. |

These values are packed into a single `felt252` for storage efficiency.

---

## Rites

A **Rite** is an external contract implementing the `IRite` interface that encodes an automated action/strategy. Each trove can have at most one Rite attached at a time. Users can swap their Rite at any time, even if a long-running rite is ongoing (to prevent a buggy rite from bricking a trove). Rites are intended to support arbitrary operations, including the possibility of not interacting with the trove itself at all (essentially functioning as a keeper).

### The `IRite` Interface

```cairo
trait IRite<TContractState> {
    fn get_rite_id(self: @TContractState) -> ByteArray;
    fn get_trove_config(self: @TContractState, trove_id: u64) -> Span<felt252>;
    fn set_trove_config(ref self: TContractState, trove_id: u64, config: Span<felt252>);
    fn is_ready(self: @TContractState, trove_id: u64) -> bool;
    fn has_ended(self: @TContractState, trove_id: u64) -> bool;
    fn perform(ref self: TContractState, trove_id: u64);
    fn end(ref self: TContractState, trove_id: u64);
}
```

| Method | Description |
|---|---|
| `get_rite_id` | Human-readable identifier (e.g. `"TOPUP"`). |
| `get_trove_config` / `set_trove_config` | Rite-specific per-trove configuration. Serialised as `Span<felt252>`. Ownership is verified: only the trove owner may set config. |
| `is_ready` | Returns whether the rite's conditions are met and it can be executed. For long-running rites, accounts for whether a previous execution has ended. |
| `has_ended` | Always `true` for one-off rites. For long-running rites, returns whether the multi-block operation has completed. |
| `perform` | Executes the rite. Must call `archabbot.on_rite_actions(...)` at least once. |
| `end` | Closes a long-running rite (e.g. withdraw DCA proceeds). No-op for one-off rites. |

Rites must register the `IRITE_ID` interface via SRC5 to be accepted by the Archabbot.

### Rite Execution Flow

```text
Keeper calls execute_rite(trove_id)
  │
  ├─ Archabbot checks is_ready() on the rite
  ├─ Archabbot locks trove_id (transient storage)
  │
  ▼
Archabbot calls rite.perform(trove_id)
  │
  ├─ Rite calls archabbot.on_rite_actions(trove_id, [Action, ...])
  │    └─ Archabbot verifies caller == rite for this trove
  │    └─ Executes each Action (Forge / Melt / Deposit / Withdraw / None)
  │    └─ Increments callback nonce
  │
  ├─ (Rite may call on_rite_actions multiple times)
  │
  ▼
Execution returns to Archabbot
  │
  ├─ Settle incentive: forge CASH to keeper
  ├─ Enforce relative threshold (revert if LTV > relative_threshold * threshold)
  ├─ Verify at least one callback was made (callback nonce > 0)
  ├─ Clear transient locks
  └─ Emit RiteExecuted event
```

### Actions

Rites instruct the Archabbot to perform actions on the trove via `on_rite_actions`:

| Action | Description | Details |
|---|---|---|
| `Forge(amount)` | Borrow CASH | Minted to the rite contract directly |
| `Melt(amount)` | Repay CASH debt | Taken from the Archabbot's balance |
| `Deposit(AssetBalance)` | Add collateral | Rite must pre-transfer tokens to Archabbot |
| `Withdraw(AssetBalance)` | Remove collateral | Transferred to the rite contract directly |
| `None` | No-op | Used as callback acknowledgement (e.g. in `end`) |

### End Rite

`end_rite(trove_id)` is owner-only. It calls `rite.end(trove_id)`, which must also invoke `on_rite_actions` at least once. The relative threshold is **not** enforced after ending a rite, to avoid bricking long-running rites that may exceed it during settlement.

---

## Implemented Rites

### Auto-Topup (`TOPUP`)

Automatically tops up a destination address when its balance of a tracked asset falls below a minimum.

**Config (`TopupConfig`):**

| Field | Description |
|---|---|
| `asset` | Token to top up. Can be CASH or any ERC-20. |
| `topup_amount` | Amount to deliver. Set to **0 to disable**. |
| `destination` | Address receiving the topped-up asset. |
| `pool_params` | Ekubo pool parameters (`fee`, `tick_spacing`, `extension`) for CASH-to-asset swap. |
| `conditions` | A `TopupConditions` struct (see below) packing the trigger threshold and slippage. |

`conditions` is a `TopupConditions` packed into a single `felt252`:

| Field | Description |
|---|---|
| `min_asset_balance` | Trigger threshold — when destination balance drops below this. |
| `slippage` | Max acceptable price impact (used for the swap's sqrt-ratio limit) and output amount (max 20%). |

**Execution:**
1. Keeper sees `destination.balanceOf(asset) < min_asset_balance`.
2. Keeper calls `execute_rite`.
3. Archabbot borrows CASH via `Forge`.
4. If `asset != CASH`, CASH is swapped for the asset through Ekubo. The forge amount is sized by quoting an exact-output swap for the asset (at spot price), then flipping it to an exact-input swap of CASH. The swap's worst-case execution price is bounded by a sqrt-ratio limit derived from a **60-second TWAP** (`TWAP_PERIOD`) from Ekubo's oracle, rather than the spot price, to resist manipulation. No rounding workaround is applied; a negligible discrepancy from AMM rounding is accepted.
5. Asset is transferred to `destination` (via `clear_minimum_to_recipient` for slippage protection on the output amount).
6. Keeper receives incentive (if any).

**Type:** One-off (completes in a single transaction). `has_ended()` always returns `true`.

---

## Leverage

Flash-loan-powered leverage operations. These are **user-initiated** (not automated by rites) and are **not subject to the relative threshold check** — the user explicitly chooses their risk level via `max_ltv`.

### Lever Up

Borrow CASH via flash mint, swap for collateral on Ekubo, deposit collateral, repay flash loan from trove's debt.

**Parameters (`LeverUpParams`):**

| Field | Description |
|---|---|
| `trove_id` | Target trove |
| `max_ltv` | Revert if resulting LTV exceeds this |
| `yang` | Collateral asset to acquire |
| `max_forge_fee_pct` | Max protocol fee for the forge step |
| `min_asset_amount` | Minimum collateral to receive (slippage protection) |
| `swaps` | Ekubo swap route (one or more hops) |

### Lever Down

Flash-mint CASH, repay trove debt, withdraw collateral, swap for CASH on Ekubo, repay flash loan. Any remaining collateral is re-deposited; any excess CASH is returned to the user.

**Parameters (`LeverDownParams`):**

| Field | Description |
|---|---|
| `trove_id` | Target trove |
| `max_ltv` | Revert if resulting LTV exceeds this |
| `yang` | Collateral asset to unwind |
| `yang_amt` | Amount of collateral (in yang units) to withdraw and sell |
| `swaps` | Ekubo swap route (one or more hops) |

---

## Safety Mechanisms

- **Reentrancy guard** on deposit and withdraw helpers.
- **Transient trove ID lock** prevents concurrent rite execution on the same trove.
- **Callback nonce** ensures `on_rite_actions` is called at least once during execution.
- **SRC5 interface check** when setting a rite — must support `IRITE_ID`.
- **Relative threshold enforcement** after every rite execution (reverts if LTV exceeds the safe boundary).
- **User can swap rites anytime** — prevents a buggy rite from permanently locking a trove.

---

## Design Principles for Rites

- **No access control on execution.** Anyone (a "keeper") can call `execute_rite`. Incentives drive decentralised execution.
- **User-configured over permissioned.** Where possible, let the user specify parameters rather than requiring whitelisting or admin gates.
- **One rite at a time.** Each trove has at most one active rite. The user can change it freely.
- **Callback enforcement.** A rite must call `on_rite_actions` at least once. This guarantees the Archabbot retains control over trove mutations.
- **Stateless execution.** Rites should not rely on persistent mutable state beyond their config. The Archabbot provides the trove context; the rite provides the logic.

---

## Directory Structure

```text
src/archabbot/
├── contracts/
│   ├── archabbot.cairo          # Main Archabbot contract
│   └── rites/
│       ├── types.cairo          # EkuboPoolParams, shared rite types
│       ├── utils.cairo          # Shared rite utilities
│       └── topup/
│           ├── topup_rite.cairo # Auto-Topup rite implementation
│           ├── types.cairo      # TopupConfig, TopupConditions, SwapParams
│           └── constants.cairo  # MAX_SLIPPAGE (20%)
├── interfaces/
│   ├── celebrant.cairo          # ICelebrant — config + rite management
│   ├── lever.cairo              # ILever — leverage up/down
│   └── rite.cairo               # IRite — rite interface + IRITE_ID
├── utils/
│   └── sqrt_ratio_limit.cairo  # Ekubo sqrt ratio limit calculation
├── tests/
│   ├── test_archabbot.cairo     # Core Archabbot tests
│   ├── test_archabbot_lever.cairo
│   ├── test_types.cairo
│   ├── utils.cairo
│   ├── mocks/                   # Mock contracts for testing
│   └── rites/
│       └── test_topup_rite.cairo
├── types.cairo                  # Action, TroveConfig, LeverParams
└── README.md                    # This file
```

## Events

| Event | Emitted By | Description |
|---|---|---|
| `Deposit` | deposit | Collateral deposited |
| `Withdraw` | withdraw | Collateral withdrawn |
| `TroveClosed` | close_trove | Trove fully closed |
| `ConfigUpdated` | set_trove_config | Trove config changed |
| `RiteSet` | set_rite | Rite attached/detached/changed |
| `RiteExecuted` | execute_rite | Rite execution completed (includes incentive) |
| `RiteEnded` | end_rite | Long-running rite ended |
| `LeverUp` | lever up | Leverage increased (includes min_asset_amount) |
| `LeverDown` | lever down | Leverage decreased (includes amounts withdrawn/re-deposited) |
