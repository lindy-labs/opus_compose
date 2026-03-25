# Opus Vicariate

The Vicariate refers to a set of modules that allows users to create and manage Troves that enable specific actions to be triggered by anyone based on pre-determined conditions (also referred to as a Smart Trove).
- Prior: A trove manager module for users to create and manage Smart Troves. It introduces a layer of indirection on top of the Abbot, and implements the `IAbbot` interface itself. From the perspective of the Abbot, the Prior is the owner of all Smart Troves that it creates. 
- Rite: A mandate for a specific type of instruction that can be attached to a Smart Trove. 

For simplicity, each Smart Trove can have at most one Rite attached to it at any time. Once a Smart Trove has an attached Rite, anyone can check if the preconditions for executing the Rite are met, and to execute the Rite if so.

## Examples of Rites

1. Auto-topup functionality: If balance of token X for address A falls below Y amount, borrow CASH and swap for token X, then transfer token X to address A.
2. Auto-DCA functionality: If price of token X is below Y, borrow CASH and enter into a DCA buy order for token X.
3. Leverage: Take on leverage for a collateral asset using flash loan.
4. Auto-deleverage: Withdraw collateral to sell for CASH and repay debt if LTV drops below what user specifies.

## Implementing a Rite

Rites must implement the `IRite` interface.

The call sequence for an action is as follows:
1. User calls `prior.execute_rite(...)`
2. `prior.execute_rite(...)` calls `rite.perform(...)`
3. `rite.perform(...)` calls `prior.on_execute_rite(...)` to perform the necessary action on the Trove
4. Execution returns to `rite.perform(...)`
5. Steps (3) and (4) may be repeated more than once
6. The execution logic for (4) is completed, and execution returns to `prior.execute_rite(...)` which checks the smart trove's LTV

