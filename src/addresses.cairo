pub mod mainnet {
    use starknet::ContractAddress;

    pub fn admin() -> ContractAddress {
        0x0684f8b5dd37cad41327891262cb17397fdb3daf54e861ec90f781c004972b15
            .try_into()
            .expect('invalid admin address')
    }

    pub fn multisig() -> ContractAddress {
        0x00Ca40fCa4208A0c2a38fc81a66C171623aAC3B913A4365F7f0BC0EB3296573C
            .try_into()
            .expect('invalid multisig address')
    }

    // Binance's address
    pub fn whale() -> ContractAddress {
        0x0213c67ed78bc280887234fe5ed5e77272465317978ae86c25a71531d9332a2d
            .try_into()
            .expect('invalid whale address')
    }

    // Tokens
    //
    // Unless otherwise stated, token's address is available at:
    // https://github.com/starknet-io/starknet-addresses/blob/master/bridged_tokens/mainnet.json

    pub fn usdc() -> ContractAddress {
        0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
            .try_into()
            .expect('invalid USDC address')
    }

    pub fn eth() -> ContractAddress {
        0x49D36570D4E46F48E99674BD3FCC84644DDD6B96F7C741B1562B82F9E004DC7
            .try_into()
            .expect('invalid ETH address')
    }

    pub fn wbtc() -> ContractAddress {
        0x03fe2b97c1fd336e750087d68b9b867997fd64a2661ff3ca5a7c771641e8e7ac
            .try_into()
            .expect('invalid WBTC address')
    }

    pub fn strk() -> ContractAddress {
        0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d
            .try_into()
            .expect('invalid STRK address')
    }

    // deployments
    pub fn abbot() -> ContractAddress {
        0x04d0bb0a4c40012384e7c419e6eb3c637b28e8363fb66958b60d90505b9c072f.try_into().unwrap()
    }

    pub fn eth_gate() -> ContractAddress {
        0x0315ce9c5d3e5772481181441369d8eea74303b9710a6c72e3fcbbdb83c0dab1.try_into().unwrap()
    }

    pub fn flash_mint() -> ContractAddress {
        0x05e57a033bb3a03e8ac919cbb4e826faf8f3d6a58e76ff7a13854ffc78264681.try_into().unwrap()
    }

    pub fn sentinel() -> ContractAddress {
        0x06428ec3221f369792df13e7d59580902f1bfabd56a81d30224f4f282ba380cd.try_into().unwrap()
    }

    pub fn shrine() -> ContractAddress {
        0x0498edfaf50ca5855666a700c25dd629d577eb9afccdf3b5977aec79aee55ada.try_into().unwrap()
    }

    pub fn wbtc_gate() -> ContractAddress {
        0x05bc1c8a78667fac3bf9617903dbf2c1bfe3937e1d37ada3d8b86bf70fb7926e.try_into().unwrap()
    }

    // Ekubo

    pub fn ekubo_core() -> ContractAddress {
        0x00000005dd3D2F4429AF886cD1a3b08289DBcEa99A294197E9eB43b0e0325b4b.try_into().unwrap()
    }

    pub fn ekubo_router() -> ContractAddress {
        0x0199741822c2dc722f6f605204f35e56dbc23bceed54818168c4c49e4fb8737e.try_into().unwrap()
    }
}
