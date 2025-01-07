# Opus Compositions

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
