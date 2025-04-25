# Opus Compose

This repository contains contracts that extend the core functionality of [Opus](https://github.com/lindy-labs/opus_contracts).

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

## Addresses

### Mainnet

| Module | Address |
| ------ | --------|
| Stabilizer [CASH-USDC] | `0x03dbe818c99cf6658f23ef70656d64cce650fdb97105b96876d7e421fa25a528` |
| Stabilizer Frontend Data Provider | `0x062e44bdb480ec9e62ad1bdb2638c011c1c02840d9db349f7f048fc9286372a1` |
