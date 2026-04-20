pub mod archabbot_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use core::num::traits::Zero;
    use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::{
        IAbbotDispatcher, IAbbotDispatcherTrait, IGateDispatcher, ISentinelDispatcher,
        IShrineDispatcher,
    };
    use opus::types::AssetBalance;
    use opus_compose::addresses::mainnet;
    use opus_compose::chantry::interfaces::archabbot::IArchabbotDispatcher;
    use opus_compose::chantry::types::TroveConfig;
    use snforge_std::{
        CheatSpan, ContractClass, ContractClassTrait, DeclareResultTrait, cheat_caller_address,
        declare, start_cheat_caller_address, stop_cheat_caller_address,
    };
    use starknet::ContractAddress;
    use wadray::{RAY_ONE, WAD_ONE, Wad};

    pub const USER: ContractAddress = 'user'.try_into().unwrap();
    pub const BAD_GUY: ContractAddress = 'bad guy'.try_into().unwrap();

    pub fn BASE_TROVE_CONFIG() -> TroveConfig {
        TroveConfig {
            relative_threshold: RAY_ONE.into(),
            max_forge_fee_pct: Zero::zero(),
            incentive: Zero::zero(),
        }
    }

    #[derive(Copy, Drop)]
    pub struct ArchabbotTestClasses {
        pub archabbot: Option<ContractClass>,
    }

    #[derive(Copy, Drop)]
    pub struct ArchabbotTestConfig {
        pub archabbot: IArchabbotDispatcher,
        pub abbot: IAbbotDispatcher,
        pub sentinel: ISentinelDispatcher,
        pub shrine: IShrineDispatcher,
        pub usdc_token: ContractAddress,
        pub eth_gate: IGateDispatcher,
    }

    // Declare the test contracts required for Archabbot tests
    pub fn declare_contracts() -> ArchabbotTestClasses {
        ArchabbotTestClasses { archabbot: Some(*declare("archabbot").unwrap().contract_class()) }
    }

    // Deploy Archabbot on forked mainnet using existing infrastructure
    pub fn archabbot_deploy(classes: Option<ArchabbotTestClasses>) -> ArchabbotTestConfig {
        let classes = classes.unwrap_or(declare_contracts());

        // Use existing mainnet contracts
        let shrine = IShrineDispatcher { contract_address: mainnet::SHRINE };
        let sentinel = ISentinelDispatcher { contract_address: mainnet::SENTINEL };
        let abbot = IAbbotDispatcher { contract_address: mainnet::ABBOT };
        let eth_gate = IGateDispatcher { contract_address: mainnet::ETH_GATE };

        // Deploy Archabbot
        let calldata: Array<felt252> = array![
            mainnet::SHRINE.into(),
            mainnet::SENTINEL.into(),
            mainnet::ABBOT.into(),
            mainnet::FLASH_MINT.into(),
            mainnet::EKUBO_ROUTER.into(),
        ];
        let (archabbot_addr, _) = classes.archabbot.unwrap().deploy(@calldata).expect('archabbot deploy fail');
        let archabbot_dispatcher = IArchabbotDispatcher { contract_address: archabbot_addr };

        // Grant access control to Archabbot
        cheat_caller_address(mainnet::SHRINE, mainnet::MULTISIG, CheatSpan::TargetCalls(1));
        // Deposit + Forge + Melt + Withdraw
        let abbot_role_for_shrine: u128 = 8 + 32 + 256 + 524288;
        IAccessControlDispatcher { contract_address: mainnet::SHRINE  }.grant_role(abbot_role_for_shrine, archabbot_addr);

        cheat_caller_address(mainnet::SENTINEL, mainnet::MULTISIG, CheatSpan::TargetCalls(1));
        // Enter + Exit
        let abbot_role_for_sentinel: u128 = 2 + 4;
        IAccessControlDispatcher { contract_address: mainnet::SENTINEL  }.grant_role(abbot_role_for_sentinel, archabbot_addr);

        ArchabbotTestConfig {
            archabbot: archabbot_dispatcher, abbot, sentinel, shrine, usdc_token: mainnet::USDC, eth_gate,
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

    pub fn open_trove_for_user(archabbot: IAbbotDispatcher, user: ContractAddress) -> u64 {
        let yang = mainnet::ETH;
        let yang_amount: u128 = WAD_ONE;
        let forge_amount: Wad = (5 * WAD_ONE).into();
        let max_forge_fee_pct: Wad = Zero::zero();

        // Setup
        fund_user_eth(user, yang_amount.into());
        approve_gate_for_user(IGateDispatcher { contract_address: mainnet::ETH_GATE }, yang, user);

        // Open trove as user
        cheat_caller_address(archabbot.contract_address, user, CheatSpan::TargetCalls(1));
        archabbot
            .open_trove(
                array![AssetBalance { address: yang, amount: yang_amount }].span(),
                forge_amount,
                max_forge_fee_pct,
            )
    }
}
