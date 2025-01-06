# Opus Lever

Leverage on [Opus](https://github.com/lindy-labs/opus_contracts) using flash mint. This relies on Ekubo's router API for [swaps](https://petstore3.swagger.io/?url=https://mainnet-api.ekubo.org/openapi.json#/Swap/get_GetQuote).

Leveraging (or up) occurs in the following steps:

1. Flash mint CASH to the Lever contract
2. Lever contract purchases collateral asset with flash minted CASH via Ekubo
3. Lever contract deposits purchased collateral asset to caller's trove
4. Lever contract borrows CASH from caller's trove
5. Flash mint contract burns flash minted CASH from Lever contract

Deleveraging (or down) occurs in the following steps:

1. Flash mint CASH to the Lever contract
2. Lever contract repays trove's debt using flash minted CASH
3. Withdraw collateral asset from trove to Lever contract
4. Lever contract purchases exact amount of flash minted CASH with withdrawn collateral asset via Ekubo
5. Lever contract transfers remainder collateral asset to caller
6. Flash mint contract burns flash minted CASH from Lever contract

## Development

### Prerequisites

- [Scarb](https://docs.swmansion.com/scarb/docs.html)
- [Starknet Foundry](https://github.com/foundry-rs/starknet-foundry)

### Testing

The test suite relies on fork testing using mainnet. You will need to set the `NODE_URL` environment variable before running the tests.

```
export NODE_URL=https://starknet-mainnet.public.blastapi.io/rpc/v0_7
scarb test
```
