# Opus Compose

This repository contains contracts that extend the core functionality of [Opus](https://github.com/lindy-labs/opus_contracts).

## Development

### Prerequisites

- [Scarb](https://docs.swmansion.com/scarb/docs.html)
- [Starknet Foundry](https://github.com/foundry-rs/starknet-foundry)

### Testing

The test suite relies on fork testing using mainnet. You will need to set the `NODE_URL` environment variable before running the tests.

```
export NODE_URL=https://starknet-mainnet.public.blastapi.io/rpc/v0_8
scarb test
```

## Addresses

### Mainnet

| Module | Address | Version |
| ------ | --------|---------|
| Stabilizer [CASH-USDC] | `0x03dbe818c99cf6658f23ef70656d64cce650fdb97105b96876d7e421fa25a528` | `v1.0.0` |
| Stabilizer Frontend Data Provider | `0x02618ba4d6821521fe2501ad1795b24ef896e108a5d54fdaa9e5f24dc78b81b2` | `main` |
| Stabilizer Estimator | `0x077492b0ee941ec8aa24688051ff5443e81ffa11243365554c09344db0f8b071` | `main` branch |
