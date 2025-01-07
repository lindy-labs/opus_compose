pub mod mainnet {
    use starknet::{contract_address_const, ContractAddress};

    pub fn admin() -> ContractAddress {
        contract_address_const::<
            0x0684f8b5dd37cad41327891262cb17397fdb3daf54e861ec90f781c004972b15,
        >()
    }

    pub fn multisig() -> ContractAddress {
        contract_address_const::<
            0x00Ca40fCa4208A0c2a38fc81a66C171623aAC3B913A4365F7f0BC0EB3296573C,
        >()
    }

    // Binance's address
    pub fn whale() -> ContractAddress {
        contract_address_const::<
            0x0213c67ed78bc280887234fe5ed5e77272465317978ae86c25a71531d9332a2d,
        >()
    }

    // Tokens
    //
    // Unless otherwise stated, token's address is available at:
    // https://github.com/starknet-io/starknet-addresses/blob/master/bridged_tokens/mainnet.json

    pub fn usdc() -> ContractAddress {
        contract_address_const::<
            0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8,
        >()
    }

    pub fn eth() -> ContractAddress {
        contract_address_const::<
            0x49D36570D4E46F48E99674BD3FCC84644DDD6B96F7C741B1562B82F9E004DC7,
        >()
    }

    pub fn strk() -> ContractAddress {
        contract_address_const::<
            0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d,
        >()
    }

    pub fn ekubo() -> ContractAddress {
        contract_address_const::<
            0x075afe6402ad5a5c20dd25e10ec3b3986acaa647b77e4ae24b0cbc9a54a27a87,
        >()
    }

    // deployments
    pub fn abbot() -> ContractAddress {
        contract_address_const::<
            0x04d0bb0a4c40012384e7c419e6eb3c637b28e8363fb66958b60d90505b9c072f,
        >()
    }

    pub fn allocator() -> ContractAddress {
        contract_address_const::<
            0x06a3593f7115f8f5e0728995d8924229cb1c4109ea477655bad281b36a760f41,
        >()
    }

    pub fn equalizer() -> ContractAddress {
        contract_address_const::<
            0x066e3e2ea2095b2a0424b9a2272e4058f30332df5ff226518d19c20d3ab8e842,
        >()
    }

    pub fn eth_gate() -> ContractAddress {
        contract_address_const::<
            0x0315ce9c5d3e5772481181441369d8eea74303b9710a6c72e3fcbbdb83c0dab1,
        >()
    }

    pub fn flash_mint() -> ContractAddress {
        contract_address_const::<
            0x05e57a033bb3a03e8ac919cbb4e826faf8f3d6a58e76ff7a13854ffc78264681,
        >()
    }

    pub fn sentinel() -> ContractAddress {
        contract_address_const::<
            0x06428ec3221f369792df13e7d59580902f1bfabd56a81d30224f4f282ba380cd,
        >()
    }

    pub fn shrine() -> ContractAddress {
        contract_address_const::<
            0x0498edfaf50ca5855666a700c25dd629d577eb9afccdf3b5977aec79aee55ada,
        >()
    }

    // Ekubo
    pub fn ekubo_positions() -> ContractAddress {
        contract_address_const::<
            0x02e0af29598b407c8716b17f6d2795eca1b471413fa03fb145a5e33722184067,
        >()
    }

    pub fn ekubo_positions_nft() -> ContractAddress {
        contract_address_const::<
            0x07b696af58c967c1b14c9dde0ace001720635a660a8e90c565ea459345318b30,
        >()
    }

    pub fn ekubo_router() -> ContractAddress {
        contract_address_const::<
            0x0199741822c2dc722f6f605204f35e56dbc23bceed54818168c4c49e4fb8737e,
        >()
    }
}
