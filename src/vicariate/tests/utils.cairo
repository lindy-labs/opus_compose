pub mod prior_utils {
    use core::num::traits::Zero;
    use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::{
        IAbbotDispatcher, IAbbotDispatcherTrait, IGateDispatcher, ISentinelDispatcher, IShrineDispatcher,
    };
    use opus::types::AssetBalance;
    use opus_compose::addresses::mainnet;
    use opus_compose::vicariate::interfaces::prior::IPriorDispatcher;
    use snforge_std::{
        CheatSpan, cheat_caller_address, ContractClass, ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address,
        stop_cheat_caller_address,
    };
    use starknet::ContractAddress;
    use wadray::{WAD_ONE, Wad};

    pub const USER: ContractAddress = 'user'.try_into().unwrap();
    pub const BAD_GUY: ContractAddress = 'bad guy'.try_into().unwrap();

    #[derive(Copy, Drop)]
    pub struct PriorTestClasses {
        pub prior: Option<ContractClass>,
    }

    #[derive(Copy, Drop)]
    pub struct PriorTestConfig {
        pub prior: IPriorDispatcher,
        pub abbot: IAbbotDispatcher,
        pub sentinel: ISentinelDispatcher,
        pub shrine: IShrineDispatcher,
        pub usdc_token: ContractAddress,
        pub eth_gate: IGateDispatcher,
    }

    // Declare the test contracts required for Prior tests
    pub fn declare_contracts() -> PriorTestClasses {
        PriorTestClasses { prior: Some(*declare("prior").unwrap().contract_class()) }
    }

    // Deploy Prior on forked mainnet using existing infrastructure
    pub fn prior_deploy(classes: Option<PriorTestClasses>) -> PriorTestConfig {
        let classes = classes.unwrap_or(declare_contracts());

        // Use existing mainnet contracts
        let shrine = IShrineDispatcher { contract_address: mainnet::SHRINE };
        let sentinel = ISentinelDispatcher { contract_address: mainnet::SENTINEL };
        let abbot = IAbbotDispatcher { contract_address: mainnet::ABBOT };
        let eth_gate = IGateDispatcher { contract_address: mainnet::ETH_GATE };

        // Deploy Prior
        let calldata: Array<felt252> = array![
            mainnet::SHRINE.into(),
            mainnet::SENTINEL.into(),
            mainnet::ABBOT.into(),
            mainnet::CARETAKER.into(),
            mainnet::FLASH_MINT.into(),
            mainnet::EKUBO_ROUTER.into(),
        ];
        let (prior_addr, _) = classes.prior.unwrap().deploy(@calldata).expect('prior deploy fail');
        let prior_dispatcher = IPriorDispatcher { contract_address: prior_addr };

        PriorTestConfig {
            prior: prior_dispatcher, abbot, sentinel, shrine, usdc_token: mainnet::USDC, eth_gate,
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

    pub fn open_trove_for_user(prior_abbot: IAbbotDispatcher, user: ContractAddress) -> u64 {
        let yang = mainnet::ETH;
        let yang_amount: u128 = WAD_ONE;
        let forge_amount: Wad = (5 * WAD_ONE).into();
        let max_forge_fee_pct: Wad = Zero::zero();

        // Setup
        fund_user_eth(user, yang_amount.into());
        approve_gate_for_user(IGateDispatcher { contract_address: mainnet::ETH }, yang, user);
        approve_for_user(prior_abbot.contract_address, yang, user);

        // Open trove as user
        cheat_caller_address(prior_abbot.contract_address, user, CheatSpan::TargetCalls(1));
        prior_abbot
            .open_trove(
                array![AssetBalance { address: yang, amount: yang_amount }].span(),
                forge_amount,
                max_forge_fee_pct,
            )
    }
}
