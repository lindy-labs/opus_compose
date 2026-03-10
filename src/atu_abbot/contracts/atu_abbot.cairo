#[starknet::contract]
pub mod atu_abbot {
    use core::cmp::minmax;
    use core::num::traits::Zero;
    use core::option::OptionTrait;
    use ekubo::components::clear::{IClearDispatcher, IClearDispatcherTrait};
    use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait};
    use ekubo::interfaces::erc20::IERC20Dispatcher as EkuboERC20Dispatcher;
    use ekubo::interfaces::router::{
        IRouterDispatcher, IRouterDispatcherTrait, RouteNode, TokenAmount,
    };
    use ekubo::types::delta::Delta;
    use ekubo::types::keys::PoolKey;
    use ekubo::types::pool_price::PoolPrice;
    use opus::interfaces::abbot::IAbbot;
    use opus::interfaces::{
        IAbbotDispatcher, IAbbotDispatcherTrait, ICaretakerDispatcher, ICaretakerDispatcherTrait, ISentinelDispatcher, ISentinelDispatcherTrait,
        IShrineDispatcher, IShrineDispatcherTrait,
    };
    use opus::types::{AssetBalance, Health};
    use opus_compose::atu_abbot::interfaces::atu_abbot::IAtuAbbot;
    use opus_compose::atu_abbot::types::AtuTroveConfig;
    use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus_compose::stabilizer::types::StoragePoolKey;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use wadray::{RAY_ONE, Ray, Wad};

    #[derive(Copy, Drop)]
    pub struct TopupPreview {
        borrow_amount: Wad,
        swap_data: Option<(RouteNode, TokenAmount)>,
    }

    #[storage]
    struct Storage {
        shrine: IShrineDispatcher,
        sentinel: ISentinelDispatcher,
        abbot: IAbbotDispatcher,
        caretaker: ICaretakerDispatcher,
        ekubo_core: ICoreDispatcher,
        ekubo_router: IRouterDispatcher,
        // Total ATU troves count (monotonically increasing)
        atu_troves_count: u64,
        atu_trove_ids: Map<u64, u64>,
        // Number of ATU troves per user
        // Starts from index 1
        user_atu_troves_count: Map<ContractAddress, u64>,
        user_atu_troves: Map<(ContractAddress, u64), u64>, // (user, index) -> ATU trove ID
        atu_trove_configs: Map<u64, AtuTroveConfig>, // ATU trove ID -> config
        // ATU trove ID -> owner
        atu_trove_owners: Map<u64, ContractAddress>,
        // Mapping of ERC-20 to the key of the pool to swap against.
        // Swaps are made against a single pool to guarantee on-chain execution.
        pool_keys: Map<ContractAddress, StoragePoolKey>,
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        AtuTroveCreated: AtuTroveCreated,
        ConfigUpdated: ConfigUpdated,
        TopupExecuted: TopupExecuted,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct AtuTroveCreated {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub trove_id: u64,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct ConfigUpdated {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub trove_id: u64,
        pub tracked_asset: ContractAddress,
        pub min_tracked_asset_balance: u128,
        pub topup_amount: u128,
        pub destination: ContractAddress,
        pub relative_threshold: Ray,
    }
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct TopupExecuted {
        #[key]
        pub caller: ContractAddress,
        #[key]
        pub trove_id: u64,
        pub borrow_amount: Wad,
        pub topup_amount: u128,
        pub destination: ContractAddress,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        shrine: ContractAddress,
        sentinel: ContractAddress,
        abbot: ContractAddress,
        caretaker: ContractAddress,
        ekubo_router: ContractAddress,
        ekubo_core: ContractAddress,
    ) {
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.sentinel.write(ISentinelDispatcher { contract_address: sentinel });
        self.abbot.write(IAbbotDispatcher { contract_address: abbot });
        self.caretaker.write(ICaretakerDispatcher { contract_address: caretaker });

        self.ekubo_core.write(ICoreDispatcher { contract_address: ekubo_core });
        self.ekubo_router.write(IRouterDispatcher { contract_address: ekubo_router });
    }

    #[abi(embed_v0)]
    impl IAbbotImpl of IAbbot<ContractState> {
        fn get_trove_owner(self: @ContractState, trove_id: u64) -> Option<ContractAddress> {
            let owner = self.atu_trove_owners.read(trove_id);
            if owner.is_zero() {
                Option::None
            } else {
                Option::Some(owner)
            }
        }

        fn get_user_trove_ids(self: @ContractState, user: ContractAddress) -> Span<u64> {
            let mut trove_ids: Array<u64> = ArrayTrait::new();
            let user_troves_count: u64 = self.user_atu_troves_count.read(user);
            for i in 0..user_troves_count {
                trove_ids.append(self.user_atu_troves.read((user, i + 1)));
            }
            trove_ids.span()
        }

        fn get_troves_count(self: @ContractState) -> u64 {
            self.atu_troves_count.read()
        }

        fn get_trove_asset_balance(
            self: @ContractState, trove_id: u64, yang: ContractAddress,
        ) -> u128 {
            assert!(self.atu_trove_owners.read(trove_id).is_non_zero(), "ATU: Not ATU trove");
            self.abbot.read().get_trove_asset_balance(trove_id, yang)
        }

        fn open_trove(
            ref self: ContractState,
            yang_assets: Span<AssetBalance>,
            forge_amount: Wad,
            max_forge_fee_pct: Wad,
        ) -> u64 {
            let user = get_caller_address();

            let sentinel = self.sentinel.read();
            let atu_abbot: ContractAddress = get_contract_address();
            for yang_asset in yang_assets {
                self.deposit_setup(sentinel, atu_abbot, user, *yang_asset);
            }

            let trove_id: u64 = self
                .abbot
                .read()
                .open_trove(yang_assets, forge_amount, max_forge_fee_pct);

            let new_atu_troves_count: u64 = self.atu_troves_count.read() + 1;
            self.atu_troves_count.write(new_atu_troves_count);
            self.atu_trove_ids.write(new_atu_troves_count, trove_id);

            let new_user_atu_troves_count: u64 = self.user_atu_troves_count.read(user) + 1;
            self.user_atu_troves_count.write(user, new_user_atu_troves_count);
            self.user_atu_troves.write((user, new_user_atu_troves_count), trove_id);
            self.atu_trove_owners.write(trove_id, user);

            self.emit(AtuTroveCreated { user, trove_id });
            trove_id
        }

        fn close_trove(ref self: ContractState, trove_id: u64) {
            let user = get_caller_address();
            self.assert_atu_trove_owner(user, trove_id);

            // Close trove in Abbot
            self.abbot.read().close_trove(trove_id);
        }

        fn deposit(ref self: ContractState, trove_id: u64, yang_asset: AssetBalance) {
            let user = get_caller_address();
            self.assert_atu_trove_owner(user, trove_id);

            // Transfer yang from user to this contract
            let yang_erc20 = IERC20Dispatcher { contract_address: yang_asset.address };
            yang_erc20.transfer_from(user, get_contract_address(), yang_asset.amount.into());

            // Approve Gate for yang
            let gate_address = self.sentinel.read().get_gate_address(yang_asset.address);
            yang_erc20.approve(gate_address, yang_asset.amount.into());

            self.abbot.read().deposit(trove_id, yang_asset);
        }

        fn withdraw(ref self: ContractState, trove_id: u64, yang_asset: AssetBalance) {
            let user = get_caller_address();
            self.assert_atu_trove_owner(user, trove_id);

            self.abbot.read().withdraw(trove_id, yang_asset);

            IERC20Dispatcher { contract_address: yang_asset.address }
                .transfer(user, yang_asset.amount.into());
        }

        fn forge(ref self: ContractState, trove_id: u64, amount: Wad, max_forge_fee_pct: Wad) {
            let user = get_caller_address();
            self.assert_atu_trove_owner(user, trove_id);
            self.abbot.read().forge(trove_id, amount, max_forge_fee_pct);

            IERC20Dispatcher { contract_address: self.shrine.read().contract_address }
                .transfer(user, amount.into());
        }

        fn melt(ref self: ContractState, trove_id: u64, amount: Wad) {
            let caller = get_caller_address();
            IERC20Dispatcher { contract_address: self.shrine.read().contract_address }
                .transfer_from(caller, get_contract_address(), amount.into());

            self.abbot.read().melt(trove_id, amount);
        }
    }

    #[abi(embed_v0)]
    impl IAtuAbbotImpl of IAtuAbbot<ContractState> {
        fn get_trove_id_by_index(self: @ContractState, index: u64) -> u64 {
            self.atu_trove_ids.read(index)
        }

        fn get_trove_config(self: @ContractState, trove_id: u64) -> Option<AtuTroveConfig> {
            let owner = self.atu_trove_owners.read(trove_id);
            if owner.is_zero() {
                Option::None
            } else {
                let config = self.atu_trove_configs.read(trove_id);
                Option::Some(config)
            }
        }

        fn set_pool_key(ref self: ContractState, asset: ContractAddress, pool_key: PoolKey) {
            let cash = self.shrine.read().contract_address;
            assert!(
                minmax(pool_key.token0, pool_key.token1) == minmax(asset, cash),
                "ATU: Invalid pool key assets",
            );

            self.pool_keys.write(asset, pool_key.into());
        }

        fn set_trove_config(
            ref self: ContractState,
            trove_id: u64,
            tracked_asset: ContractAddress,
            min_tracked_asset_balance: u128,
            topup_amount: u128,
            destination: ContractAddress,
            relative_threshold: Option<Ray>,
        ) {
            let user = get_caller_address();
            assert!(self.atu_trove_owners.read(trove_id) == user, "ATU: Not owner");

            assert!(self.pool_keys.read(tracked_asset).token0.is_non_zero(), "ATU: No swap path");
            assert!(
                topup_amount.is_zero() // Topup is disabled
                    || 
                    topup_amount >= min_tracked_asset_balance // Prevent multiple topups
                    ,
                "ATU: Invalid topup amount",
            );
            assert!(destination.is_non_zero(), "ATU: Invalid destination");

            let relative_threshold: Ray = relative_threshold.unwrap_or(RAY_ONE.into());
            assert!(relative_threshold <= RAY_ONE.into(), "ATU: Invalid relative threshold");

            let mut config = self.atu_trove_configs.read(trove_id);
            config.tracked_asset = tracked_asset;
            config.min_tracked_asset_balance = min_tracked_asset_balance;
            config.topup_amount = topup_amount;
            config.destination = destination;
            config.relative_threshold = relative_threshold;
            self.atu_trove_configs.write(trove_id, config);

            self
                .emit(
                    ConfigUpdated {
                        user,
                        trove_id,
                        tracked_asset,
                        min_tracked_asset_balance,
                        topup_amount,
                        destination,
                        relative_threshold,
                    },
                );
        }


        fn should_topup(self: @ContractState, trove_id: u64) -> bool {
            let owner = self.atu_trove_owners.read(trove_id);
            if owner.is_zero() {
                return false;
            }

            let config = self.atu_trove_configs.read(trove_id);

            // Zero topup amount is used as a flag for disabling auto-topup
            if config.topup_amount.is_zero() {
                return false;
            }

            // Check LTV condition if relative_threshold is set
            let trove_health: Health = self.shrine.read().get_trove_health(trove_id);
            let stop_ltv = trove_health.threshold * config.relative_threshold;
            if trove_health.ltv > stop_ltv {
                return false;
            }

            let tracked_balance = IERC20Dispatcher { contract_address: config.tracked_asset }
                .balance_of(config.destination);
            tracked_balance < config.min_tracked_asset_balance.into()
        }

        fn execute_topup(ref self: ContractState, trove_id: u64) {
            let caller: ContractAddress = get_caller_address();
            assert(self.should_topup(trove_id), 'ATU: Topup not needed');
            let config = self.atu_trove_configs.read(trove_id);

            let topup_preview: TopupPreview = self
                .preview_topup(trove_id, config.tracked_asset, config.topup_amount);

            self
                .abbot
                .read()
                .forge(trove_id, topup_preview.borrow_amount, config.max_forge_fee_pct);

            let cash = IERC20Dispatcher { contract_address: self.shrine.read().contract_address };
            if let Some((route_node, token_amount)) = topup_preview.swap_data {
                let ekubo_router = self.ekubo_router.read();
                cash.transfer(ekubo_router.contract_address, topup_preview.borrow_amount.into());
                ekubo_router.swap(route_node, token_amount);

                IClearDispatcher { contract_address: ekubo_router.contract_address }
                    .clear_minimum_to_recipient(
                        EkuboERC20Dispatcher { contract_address: config.tracked_asset },
                        0,
                        config.destination,
                    );
            } else {
                cash.transfer(config.destination, topup_preview.borrow_amount.into());
            }

            self
                .emit(
                    TopupExecuted {
                        caller,
                        trove_id,
                        borrow_amount: topup_preview.borrow_amount,
                        topup_amount: config.topup_amount,
                        destination: config.destination,
                    },
                );
        }

        // Mirror Caretaker's release function due to ownership check on primary Abbot
        fn release(ref self: ContractState, trove_id: u64) -> Span<AssetBalance> {
            let caller: ContractAddress = get_caller_address();
            self.assert_atu_trove_owner(caller, trove_id);

            let released_assets: Span<AssetBalance> = self.caretaker.read().release(trove_id);            
            for asset in released_assets {
                IERC20Dispatcher { contract_address: *asset.address }.transfer(
                    caller, (*asset.amount).into(),
                );
            }

            released_assets
        }
    }

    #[generate_trait]
    impl AtuAbbotHelpers of AtuAbbotHelpersTrait {
        fn assert_atu_trove_owner(self: @ContractState, user: ContractAddress, trove_id: u64) {
            assert!(self.atu_trove_owners.read(trove_id) == user, "ATY: Not owner");
        }

        fn preview_topup(
            self: @ContractState, trove_id: u64, tracked_asset: ContractAddress, topup_amount: u128,
        ) -> TopupPreview {
            let cash = self.shrine.read().contract_address;
            let pool_key: PoolKey = self.pool_keys.read(tracked_asset).into();
            assert!(tracked_asset == cash || pool_key.token0.is_non_zero(), "ATU: No swap path");

            if tracked_asset == cash {
                TopupPreview { borrow_amount: topup_amount.into(), swap_data: Option::None }
            } else {
                let ekubo_core = self.ekubo_core.read();
                let ekubo_router = self.ekubo_router.read();

                let pool_price: PoolPrice = ekubo_core.get_pool_price(pool_key);
                let (cash_is_token0, sqrt_ratio_limit) = if pool_key.token0 == cash {
                    (true, pool_price.sqrt_ratio / 2)
                } else {
                    (false, pool_price.sqrt_ratio * 2)
                };
                let route_node = RouteNode { pool_key, sqrt_ratio_limit, skip_ahead: 0 };
                let token_amount = TokenAmount {
                    token: tracked_asset, amount: topup_amount.into(),
                };
                let quote_delta: Delta = ekubo_router.quote_swap(route_node, token_amount);
                let cash_amount: u128 = if cash_is_token0 {
                    (-quote_delta.amount0).try_into().unwrap()
                } else {
                    (-quote_delta.amount1).try_into().unwrap()
                };
                TopupPreview {
                    borrow_amount: cash_amount.into(),
                    swap_data: Option::Some((route_node, token_amount)),
                }
            }
        }

        fn deposit_setup(
            ref self: ContractState,
            sentinel: ISentinelDispatcher,
            atu_abbot: ContractAddress,
            user: ContractAddress,
            yang_asset: AssetBalance,
        ) {
            let yang = IERC20Dispatcher { contract_address: yang_asset.address };
            yang.transfer_from(user, atu_abbot, yang_asset.amount.into());

            let gate = sentinel.get_gate_address(yang_asset.address);
            yang.approve(gate, yang_asset.amount.into());
        }
    }
}
