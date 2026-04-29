# Opus Archabbot

The Archabbot is a module that supersedes the Abbot and additionally supports the following features:
1. Bidirectional leverage with flashloan;
2. Enable specific instructions/actions to be triggered by anyone based on pre-determined conditions (also referred to as a "Rite").

For simplicity, each Trove can have at most one Rite attached to it at any time. Once a Trove has an attached Rite, anyone can check if the preconditions for executing the Rite are met, and to execute the Rite if so.

## Examples of Rites

1. Auto-topup functionality: If balance of token X for address A falls below Y amount, borrow CASH and swap for token X, then transfer token X to address A.
2. Auto-DCA functionality: If price of token X is below Y, borrow CASH and enter into a DCA buy order for token X.
3. Leverage: Take on leverage for a collateral asset using flash loan.
4. Auto-deleverage: Withdraw collateral to sell for CASH and repay debt if LTV drops below what user specifies.

## Implementing a Rite

Rites must implement the `IRite` interface.

The call sequence for an action is as follows:
1. User calls `archabbot.execute_rite(...)`
2. `archabbot.execute_rite(...)` calls `rite.perform(...)`
3. `rite.perform(...)` calls `archabbot.on_rite_actions(...)` to perform the necessary action(s) on the Trove
4. Execution returns to `rite.perform(...)`
5. Steps (3) and (4) may be repeated more than once
6. The execution logic for (4) is completed, and execution returns to `archabbot.execute_rite(...)` which checks the smart trove's LTV

## General principles for designing a Rite

- Access control should be avoided as far as possible. Where possible, let the user specify the configuration instead.
