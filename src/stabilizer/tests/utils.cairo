pub mod stabilizer_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use ekubo::components::clear::{IClearDispatcher, IClearDispatcherTrait};
    use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use ekubo::interfaces::erc721::{IERC721Dispatcher, IERC721DispatcherTrait};
    use ekubo::interfaces::positions::{IPositionsDispatcher, IPositionsDispatcherTrait};
    use ekubo::types::bounds::Bounds;
    use ekubo::types::keys::PoolKey;
    use opus::interfaces::{
        IAllocatorDispatcher, IAllocatorDispatcherTrait, IEqualizerDispatcher,
        IEqualizerDispatcherTrait, IShrineDispatcher, IShrineDispatcherTrait,
    };
    use opus_compose::addresses::mainnet;
    use opus_compose::stabilizer::constants::{BOUNDS, POOL_KEY};
    use opus_compose::stabilizer::interfaces::stabilizer::{
        IStabilizerDispatcher, IStabilizerDispatcherTrait,
    };
    use opus_compose::stabilizer::periphery::frontend_data_provider::IFrontendDataProviderDispatcher;
    use snforge_std::{
        CheatSpan, ContractClass, ContractClassTrait, DeclareResultTrait, cheat_caller_address,
        declare, start_cheat_caller_address, stop_cheat_caller_address,
    };
    use starknet::ContractAddress;
    use wadray::{RAY_ONE, Wad};

    pub const USDC_DECIMALS_DIFF_SCALE: u256 = 1000000000000; // 10 ** 12

    #[derive(Copy, Drop)]
    pub struct StabilizerTestConfig {
        pub stabilizer: IStabilizerDispatcher,
        pub fdp: IFrontendDataProviderDispatcher,
    }

    //
    // Test setup helpers
    //

    pub fn setup(stabilizer_class: Option<ContractClass>) -> StabilizerTestConfig {
        let stabilizer_class = match stabilizer_class {
            Option::Some(class) => class,
            Option::None => *(declare("stabilizer").unwrap().contract_class()),
        };

        let mut calldata: Array<felt252> = array![
            mainnet::SHRINE.into(),
            mainnet::EQUALIZER.into(),
            mainnet::EKUBO_POSITIONS.into(),
            mainnet::EKUBO_POSITIONS_NFT.into(),
        ];
        POOL_KEY().serialize(ref calldata);
        BOUNDS().serialize(ref calldata);
        let (stabilizer_addr, _) = stabilizer_class.deploy(@calldata).unwrap();

        // Clear out surplus
        let equalizer = IEqualizerDispatcher { contract_address: mainnet::EQUALIZER };
        equalizer.equalize();
        equalizer.allocate();

        // Set stabilizer as the only recipient of surplus to make tests simpler
        start_cheat_caller_address(mainnet::ALLOCATOR, mainnet::MULTISIG);
        IAllocatorDispatcher { contract_address: mainnet::ALLOCATOR }
            .set_allocation(array![stabilizer_addr].span(), array![RAY_ONE.into()].span());
        stop_cheat_caller_address(mainnet::ALLOCATOR);

        start_cheat_caller_address(mainnet::SHRINE, mainnet::MULTISIG);
        let adjust_budget_role: u128 = 2;
        IAccessControlDispatcher { contract_address: mainnet::SHRINE }
            .grant_role(adjust_budget_role, mainnet::MULTISIG);
        stop_cheat_caller_address(mainnet::SHRINE);

        let fdp_class = declare("stabilizer_fdp").unwrap().contract_class();
        let (fdp_addr, _) = fdp_class.deploy(@array![]).unwrap();

        StabilizerTestConfig {
            stabilizer: IStabilizerDispatcher { contract_address: stabilizer_addr },
            fdp: IFrontendDataProviderDispatcher { contract_address: fdp_addr },
        }
    }

    pub fn fund_three_users(
        shrine: ContractAddress, funder: ContractAddress, mut users_yin_amts: Span<u256>,
    ) -> Span<ContractAddress> {
        let yin = IERC20Dispatcher { contract_address: shrine };
        let usdc = IERC20Dispatcher { contract_address: mainnet::USDC };

        let user1 = 'user 1'.try_into().unwrap();
        let user2 = 'user 2'.try_into().unwrap();
        let user3 = 'user 3'.try_into().unwrap();

        let users = array![user1, user2, user3].span();

        for user in users {
            let user_yin_amt = *users_yin_amts.pop_front().unwrap();

            start_cheat_caller_address(yin.contract_address, funder);
            yin.transfer(*user, user_yin_amt);
            stop_cheat_caller_address(yin.contract_address);

            start_cheat_caller_address(usdc.contract_address, funder);
            let scaled_usdc_amount: u256 = user_yin_amt / USDC_DECIMALS_DIFF_SCALE;
            usdc.transfer(*user, scaled_usdc_amount);
            stop_cheat_caller_address(usdc.contract_address);
        }

        users
    }

    pub fn create_surplus(shrine: ContractAddress, surplus: Wad) {
        let admin = mainnet::MULTISIG;
        let yin = IERC20Dispatcher { contract_address: shrine };

        // Account for leftover yin in Equalizer from previous distribution
        let equalizer_yin_balance: Wad = yin.balanceOf(mainnet::EQUALIZER).try_into().unwrap();
        assert(equalizer_yin_balance <= surplus, 'Surplus < equalizer balance');
        let adjusted_surplus = surplus - equalizer_yin_balance;

        start_cheat_caller_address(shrine, admin);
        IShrineDispatcher { contract_address: shrine }.adjust_budget(adjusted_surplus.into());
        stop_cheat_caller_address(shrine);
    }

    // CASH is at 0.98 at the forked block, so depositing in the range of 0.99 to 1.01 requires CASH
    // only
    pub fn create_valid_ekubo_position(
        yin: ContractAddress,
        ekubo_positions: ContractAddress,
        caller: ContractAddress,
        lp_amount: u256,
    ) -> (u64, u128) {
        create_ekubo_position(yin, ekubo_positions, caller, POOL_KEY(), BOUNDS(), lp_amount)
    }

    pub fn create_ekubo_position(
        yin: ContractAddress,
        ekubo_positions: ContractAddress,
        caller: ContractAddress,
        pool_key: PoolKey,
        bounds: Bounds,
        lp_amount: u256,
    ) -> (u64, u128) {
        let yin = IERC20Dispatcher { contract_address: mainnet::SHRINE };
        let usdc = IERC20Dispatcher { contract_address: mainnet::USDC };
        let ekubo_positions = IPositionsDispatcher { contract_address: mainnet::EKUBO_POSITIONS };
        let ekubo_positions_clear = IClearDispatcher { contract_address: mainnet::EKUBO_POSITIONS };

        start_cheat_caller_address(yin.contract_address, caller);
        yin.transfer(ekubo_positions.contract_address, lp_amount);
        stop_cheat_caller_address(yin.contract_address);

        start_cheat_caller_address(mainnet::USDC, caller);
        let scaled_lp_amount: u256 = lp_amount / USDC_DECIMALS_DIFF_SCALE;
        usdc.transfer(ekubo_positions.contract_address, scaled_lp_amount);
        stop_cheat_caller_address(mainnet::USDC);

        cheat_caller_address(ekubo_positions.contract_address, caller, CheatSpan::TargetCalls(1));
        let min_liquidity = 1;
        let (positions_nft_id, liquidity) = ekubo_positions
            .mint_and_deposit(pool_key, bounds, min_liquidity);

        let owner = IERC721Dispatcher { contract_address: mainnet::EKUBO_POSITIONS_NFT }
            .owner_of(positions_nft_id.into());
        assert_eq!(owner, caller, "Caller not owner");

        ekubo_positions_clear.clear(yin);
        ekubo_positions_clear.clear(usdc);
        stop_cheat_caller_address(ekubo_positions.contract_address);

        (positions_nft_id, liquidity)
    }

    pub fn stake_ekubo_position(
        positions_nft: IERC721Dispatcher,
        stabilizer: IStabilizerDispatcher,
        staker: ContractAddress,
        position_id: u64,
    ) {
        start_cheat_caller_address(positions_nft.contract_address, staker);
        positions_nft.approve(stabilizer.contract_address, position_id.into());
        stop_cheat_caller_address(positions_nft.contract_address);

        start_cheat_caller_address(stabilizer.contract_address, staker);
        stabilizer.stake(position_id);
        stop_cheat_caller_address(stabilizer.contract_address);
    }
}
