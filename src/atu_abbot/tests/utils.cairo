pub mod atu_abbot_utils {
    use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::{
        IAbbotDispatcher, IGateDispatcher, ISentinelDispatcher, IShrineDispatcher,
    };
    use opus_compose::addresses::mainnet;
    use opus_compose::atu_abbot::interfaces::atu_abbot::IAtuAbbotDispatcher;
    use snforge_std::{
        ContractClass, ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address,
        stop_cheat_caller_address,
    };
    use starknet::ContractAddress;

    #[derive(Copy, Drop)]
    pub struct AtuAbbotTestClasses {
        pub atu_abbot: Option<ContractClass>,
    }

    #[derive(Copy, Drop)]
    pub struct AtuAbbotTestConfig {
        pub atu_abbot: IAtuAbbotDispatcher,
        pub abbot: IAbbotDispatcher,
        pub sentinel: ISentinelDispatcher,
        pub shrine: IShrineDispatcher,
        pub usdc_token: ContractAddress,
        pub eth_gate: IGateDispatcher,
    }

    // Declare the test contracts required for AtuAbbot tests
    pub fn declare_contracts() -> AtuAbbotTestClasses {
        AtuAbbotTestClasses { atu_abbot: Some(*declare("atu_abbot").unwrap().contract_class()) }
    }

    // Deploy AtuAbbot on forked mainnet using existing infrastructure
    pub fn atu_abbot_deploy(classes: Option<AtuAbbotTestClasses>) -> AtuAbbotTestConfig {
        let classes = classes.unwrap_or(declare_contracts());

        // Use existing mainnet contracts
        let shrine = IShrineDispatcher { contract_address: mainnet::SHRINE };
        let sentinel = ISentinelDispatcher { contract_address: mainnet::SENTINEL };
        let abbot = IAbbotDispatcher { contract_address: mainnet::ABBOT };
        let eth_gate = IGateDispatcher { contract_address: mainnet::ETH_GATE };

        // Deploy AtuAbbot
        let calldata: Array<felt252> = array![
            mainnet::SHRINE.into(),
            mainnet::SENTINEL.into(),
            mainnet::ABBOT.into(),
            mainnet::CARETAKER.into(),
            mainnet::EKUBO_ROUTER.into(),
            mainnet::EKUBO_CORE.into(),
        ];
        let (atu_addr, _) = classes
            .atu_abbot
            .unwrap()
            .deploy(@calldata)
            .expect('atu_abbot deploy fail');
        let atu_dispatcher = IAtuAbbotDispatcher { contract_address: atu_addr };

        AtuAbbotTestConfig {
            atu_abbot: atu_dispatcher, abbot, sentinel, shrine, usdc_token: mainnet::USDC, eth_gate,
        }
    }

    // Helper to fund user with ETH from whale
    pub fn fund_user_eth(user: ContractAddress, amount: u256) {
        let eth = IERC20Dispatcher { contract_address: mainnet::ETH };
        start_cheat_caller_address(eth.contract_address, mainnet::WHALE);
        eth.transfer(user, amount);
        stop_cheat_caller_address(eth.contract_address);
    }

    // Helper to approve gate for token
    pub fn approve_gate_for_user(
        gate: IGateDispatcher, token: ContractAddress, user: ContractAddress,
    ) {
        let token_contract = IERC20Dispatcher { contract_address: token };
        start_cheat_caller_address(token, user);
        token_contract.approve(gate.contract_address, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF);
        stop_cheat_caller_address(token);
    }

    // Helper to approve contract for token
    pub fn approve_for_user(
        contract_addr: ContractAddress, token: ContractAddress, user: ContractAddress,
    ) {
        let token_contract = IERC20Dispatcher { contract_address: token };
        start_cheat_caller_address(token, user);
        token_contract.approve(contract_addr, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF);
        stop_cheat_caller_address(token);
    }
}
