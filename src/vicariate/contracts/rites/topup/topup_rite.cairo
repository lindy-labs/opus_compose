use opus_compose::vicariate::contracts::rites::topup::types::SwapParams;

#[starknet::interface]
pub trait ITopupRite<TContractState> {
    fn get_swap_params(self: @TContractState, trove_id: u64) -> SwapParams;
}

#[starknet::contract]
pub mod topup_rite {
    use core::num::traits::Zero;
    use ekubo::components::clear::{IClearDispatcher, IClearDispatcherTrait};
    use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait};
    use ekubo::interfaces::erc20::IERC20Dispatcher as EkuboERC20Dispatcher;
    use ekubo::interfaces::router::{
        IRouterDispatcher, IRouterDispatcherTrait, RouteNode, TokenAmount,
    };
    use ekubo::types::delta::Delta;
    use ekubo::types::keys::PoolKey;
    use ekubo::types::pool_price::PoolPrice;
    use opus::interfaces::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus_compose::vicariate::contracts::rites::components::pool_key_manager::{
        IPoolKeyManager, pool_key_manager_component,
    };
    use opus_compose::vicariate::contracts::rites::topup::types::{SwapParams, TopupConfig};
    use opus_compose::vicariate::contracts::rites::utils::rites_utils;
    use opus_compose::vicariate::interfaces::prior::{IPriorDispatcher, IPriorDispatcherTrait};
    use opus_compose::vicariate::interfaces::rite::IRite;
    use opus_compose::vicariate::types::Action;
    use opus_compose::vicariate::utils::sqrt_ratio_limit::calculate_sqrt_ratio_limit;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address};
    use wadray::{RAY_PERCENT, Ray, Wad};
    use super::ITopupRite;

    pub const MAX_SLIPPAGE: u128 = RAY_PERCENT * 20;

    component!(
        path: pool_key_manager_component, storage: pool_key_manager, event: PoolKeyManagerEvent,
    );

    impl PoolKeyManagerInternalImpl =
        pool_key_manager_component::PoolKeyManagerHelpers<ContractState>;

    #[storage]
    struct Storage {
        yin: IERC20Dispatcher,
        prior: IPriorDispatcher,
        ekubo_core: ICoreDispatcher,
        ekubo_router: IRouterDispatcher,
        topup_configs: Map<u64, TopupConfig>, // ATU trove ID -> config
        #[substorage(v0)]
        pool_key_manager: pool_key_manager_component::Storage,
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        TopupConfigUpdated: TopupConfigUpdated,
        TopupExecuted: TopupExecuted,
        PoolKeyManagerEvent: pool_key_manager_component::Event,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct TopupConfigUpdated {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub trove_id: u64,
        pub config: TopupConfig,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct TopupExecuted {
        #[key]
        pub trove_id: u64,
        pub forge_amount: Wad,
        pub asset: ContractAddress,
        pub topup_amount: u128,
        pub destination: ContractAddress,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        yin: ContractAddress,
        prior: ContractAddress,
        ekubo_router: ContractAddress,
        ekubo_core: ContractAddress,
    ) {
        self.yin.write(IERC20Dispatcher { contract_address: yin });
        self.prior.write(IPriorDispatcher { contract_address: prior });

        self.ekubo_core.write(ICoreDispatcher { contract_address: ekubo_core });
        self.ekubo_router.write(IRouterDispatcher { contract_address: ekubo_router });
    }

    #[abi(embed_v0)]
    pub impl IPoolKeyManagerImpl of IPoolKeyManager<ContractState> {
        fn set_pool_key(ref self: ContractState, asset: ContractAddress, pool_key: PoolKey) {
            let cash = self.yin.read().contract_address;
            self.pool_key_manager.set_pool_key_helper(cash, asset, pool_key);
        }

        fn get_pool_key(self: @ContractState, asset: ContractAddress) -> PoolKey {
            self.pool_key_manager.get_pool_key_helper(asset)
        }

        fn clear_pool_key(ref self: ContractState, asset: ContractAddress) {
            self.pool_key_manager.clear_pool_key_helper(asset);
        }
    }

    #[abi(embed_v0)]
    pub impl ITopupRiteImpl of ITopupRite<ContractState> {
        fn get_swap_params(self: @ContractState, trove_id: u64) -> SwapParams {
            let config = self.topup_configs.read(trove_id);
            self.get_swap_params_helper(config.asset, config.topup_amount, config.slippage)
        }
    }

    #[abi(embed_v0)]
    pub impl IRiteImpl of IRite<ContractState> {
        fn get_rite_id(self: @ContractState) -> ByteArray {
            RITE_ID()
        }

        fn get_trove_config(self: @ContractState, trove_id: u64) -> Span<felt252> {
            let config = self.topup_configs.read(trove_id);
            let mut serialized_config: Array<felt252> = Default::default();
            config.serialize(ref serialized_config);
            serialized_config.span()
        }

        fn set_trove_config(ref self: ContractState, trove_id: u64, config: Span<felt252>) {
            let mut config = config;
            let config: TopupConfig = Serde::<TopupConfig>::deserialize(ref config)
                .expect('TOPUP: Invalid config');

            let user = get_caller_address();
            let prior_abbot = IAbbotDispatcher {
                contract_address: self.prior.read().contract_address,
            };
            assert!(
                prior_abbot.get_trove_owner(trove_id).expect('TOPUP: Trove not found') == user,
                "{}: Not owner",
                RITE_ID(),
            );

            assert!(config.asset.is_non_zero(), "{}: Invalid asset", RITE_ID());
            if config.topup_amount.is_non_zero() {
                assert!(
                    config.asset == self.yin.read().contract_address
                        || self
                            .pool_key_manager
                            .get_pool_key_helper(config.asset)
                            .token0
                            .is_non_zero(),
                    "{}: No swap path",
                    RITE_ID(),
                );
                assert!(
                    config.topup_amount >= config.min_asset_balance // Prevent multiple topups
                    ,
                    "{}: Invalid topup amount",
                    RITE_ID(),
                );
                assert!(config.destination.is_non_zero(), "{}: Invalid destination", RITE_ID());
                assert!(
                    config.slippage.is_non_zero() && config.slippage <= MAX_SLIPPAGE.into(),
                    "{}: Slippage out of acceptable range",
                    RITE_ID(),
                );
            }

            self.topup_configs.write(trove_id, config);

            self.emit(TopupConfigUpdated { user, trove_id, config });
        }


        fn is_ready(self: @ContractState, trove_id: u64) -> bool {
            let config = self.topup_configs.read(trove_id);
            // Zero topup amount is used as a flag for disabling auto-topup
            if config.topup_amount.is_zero() {
                return false;
            }

            let tracked_balance = IERC20Dispatcher { contract_address: config.asset }
                .balance_of(config.destination);
            tracked_balance < config.min_asset_balance.into()
        }

        fn has_ended(self: @ContractState, trove_id: u64) -> bool {
            true
        }

        fn perform(ref self: ContractState, trove_id: u64) {
            let prior = self.prior.read();
            let caller: ContractAddress = get_caller_address();
            // Prior should have checked that the rite can be executed
            rites_utils::assert_caller_is_prior(caller, prior.contract_address, self.get_rite_id());

            let config = self.topup_configs.read(trove_id);
            let swap_params: SwapParams = self
                .get_swap_params_helper(config.asset, config.topup_amount, config.slippage);

            prior.on_rite_actions(trove_id, array![Action::Forge(swap_params.forge_amount)].span());

            let cash = self.yin.read();

            if let Some((route_node, token_amount)) = swap_params.swap_data {
                let ekubo_router = self.ekubo_router.read();
                cash.transfer(ekubo_router.contract_address, swap_params.forge_amount.into());
                ekubo_router.swap(route_node, token_amount);

                IClearDispatcher { contract_address: ekubo_router.contract_address }
                    .clear_minimum_to_recipient(
                        EkuboERC20Dispatcher { contract_address: config.asset },
                        0,
                        config.destination,
                    );
            } else {
                cash.transfer(config.destination, swap_params.forge_amount.into());
            }

            self
                .emit(
                    TopupExecuted {
                        trove_id,
                        forge_amount: swap_params.forge_amount,
                        asset: config.asset,
                        topup_amount: config.topup_amount,
                        destination: config.destination,
                    },
                );
        }

        fn end(ref self: ContractState, trove_id: u64) {
            let prior = self.prior.read();
            let caller: ContractAddress = get_caller_address();
            rites_utils::assert_caller_is_prior(caller, prior.contract_address, self.get_rite_id());

            prior.on_rite_actions(trove_id, array![Action::None].span());
        }
    }

    #[generate_trait]
    impl TopupRiteHelpers of TopupRiteHelpersTrait {
        fn get_swap_params_helper(
            self: @ContractState, asset: ContractAddress, topup_amount: u128, slippage: Ray,
        ) -> SwapParams {
            let cash = self.yin.read().contract_address;
            let pool_key: PoolKey = self.pool_key_manager.get_pool_key_helper(asset);
            assert!(asset == cash || pool_key.token0.is_non_zero(), "{}: No swap path", RITE_ID());

            if asset == cash {
                SwapParams { forge_amount: topup_amount.into(), swap_data: Option::None }
            } else {
                let ekubo_core = self.ekubo_core.read();
                let ekubo_router = self.ekubo_router.read();

                let pool_price: PoolPrice = ekubo_core.get_pool_price(pool_key);
                let cash_is_token0: bool = pool_key.token0 == cash;
                let sqrt_ratio_limit = calculate_sqrt_ratio_limit(
                    pool_price.sqrt_ratio, slippage, cash_is_token0,
                );
                let route_node = RouteNode { pool_key, sqrt_ratio_limit, skip_ahead: 0 };
                let token_amount = TokenAmount { token: asset, amount: topup_amount.into() };
                let quote_delta: Delta = ekubo_router.quote_swap(route_node, token_amount);
                let cash_amount: u128 = if cash_is_token0 {
                    (-quote_delta.amount0).try_into().unwrap()
                } else {
                    (-quote_delta.amount1).try_into().unwrap()
                };
                SwapParams {
                    forge_amount: cash_amount.into(),
                    swap_data: Option::Some((route_node, token_amount)),
                }
            }
        }
    }

    fn RITE_ID() -> ByteArray {
        "TOPUP"
    }
}
