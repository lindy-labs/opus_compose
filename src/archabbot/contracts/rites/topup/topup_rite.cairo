use opus_compose::archabbot::contracts::rites::topup::types::SwapParams;

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
    use opus_compose::archabbot::contracts::rites::topup::constants::MAX_SLIPPAGE;
    use opus_compose::archabbot::contracts::rites::topup::types::{SwapParams, TopupConfig};
    use opus_compose::archabbot::contracts::rites::types::{EkuboPoolParams, EkuboPoolParamsTrait};
    use opus_compose::archabbot::contracts::rites::utils::rites_utils;
    use opus_compose::archabbot::interfaces::celebrant::{
        ICelebrantDispatcher, ICelebrantDispatcherTrait,
    };
    use opus_compose::archabbot::interfaces::rite::{IRITE_ID, IRite};
    use opus_compose::archabbot::types::Action;
    use opus_compose::archabbot::utils::sqrt_ratio_limit::calculate_sqrt_ratio_limit;
    use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus_compose::shared::components::src5::SRC5Component;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address};
    use wadray::{RAY_ONE, Ray, Wad, rmul_wr};
    use super::ITopupRite;

    //
    // Components
    //

    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;
    impl SRC5InternalImpl = SRC5Component::InternalImpl<ContractState>;

    //
    // Storage
    //

    #[storage]
    struct Storage {
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        yin: IERC20Dispatcher,
        archabbot: ICelebrantDispatcher,
        ekubo_core: ICoreDispatcher,
        ekubo_router: IRouterDispatcher,
        // Mapping of trove ID -> topup config
        topup_configs: Map<u64, TopupConfig>,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        #[flat]
        SRC5Event: SRC5Component::Event,
        TopupConfigUpdated: TopupConfigUpdated,
        TopupExecuted: TopupExecuted,
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

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        ref self: ContractState,
        yin: ContractAddress,
        archabbot: ContractAddress,
        ekubo_router: ContractAddress,
        ekubo_core: ContractAddress,
    ) {
        self.yin.write(IERC20Dispatcher { contract_address: yin });
        self.archabbot.write(ICelebrantDispatcher { contract_address: archabbot });

        self.ekubo_core.write(ICoreDispatcher { contract_address: ekubo_core });
        self.ekubo_router.write(IRouterDispatcher { contract_address: ekubo_router });

        self.src5.register_interface(IRITE_ID);
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
            let abbot_dispatcher = IAbbotDispatcher {
                contract_address: self.archabbot.read().contract_address,
            };
            assert!(
                abbot_dispatcher.get_trove_owner(trove_id).expect('TOPUP: Trove not found') == user,
                "{}: Not owner",
                RITE_ID(),
            );

            assert!(config.asset.is_non_zero(), "{}: Invalid asset", RITE_ID());
            if config.topup_amount.is_non_zero() {
                let cash = self.yin.read().contract_address;

                assert!(
                    config.asset == cash || config.pool_params.tick_spacing.is_non_zero(),
                    "{}: Invalid pool params",
                    RITE_ID(),
                );
                // Prevent multiple topups
                // There is an edge case where the minimum asset balance is within the slippage
                // allowance of the topup amount, and the swap outputs less than the minimum
                // asset balance. However, this is acceptable since it would at most result in
                // two top-ups.
                assert!(
                    config.topup_amount >= config.conditions.min_asset_balance,
                    "{}: Topup amount less than minimum",
                    RITE_ID(),
                );
                assert!(config.destination.is_non_zero(), "{}: Invalid destination", RITE_ID());
                assert!(
                    config.conditions.slippage.is_non_zero()
                        && config.conditions.slippage <= MAX_SLIPPAGE.into(),
                    "{}: Slippage out of acceptable range",
                    RITE_ID(),
                );

                // Catch non-existent pools
                let _swap_params: SwapParams = self
                    .get_swap_params_helper(
                        config.pool_params,
                        config.asset,
                        config.topup_amount,
                        config.conditions.slippage,
                        self.yin.read().contract_address,
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
            tracked_balance < config.conditions.min_asset_balance.into()
        }

        fn has_ended(self: @ContractState, trove_id: u64) -> bool {
            true
        }

        fn perform(ref self: ContractState, trove_id: u64) {
            let archabbot = self.archabbot.read();
            let caller: ContractAddress = get_caller_address();
            // Archabbot should have checked that the rite can be executed
            rites_utils::assert_caller_is_archabbot(
                caller, archabbot.contract_address, self.get_rite_id(),
            );

            let config = self.topup_configs.read(trove_id);
            let yin = self.yin.read();
            let swap_params: SwapParams = self
                .get_swap_params_helper(
                    config.pool_params,
                    config.asset,
                    config.topup_amount,
                    config.conditions.slippage,
                    yin.contract_address,
                );

            archabbot
                .on_rite_actions(trove_id, array![Action::Forge(swap_params.forge_amount)].span());

            let mut topup_amount = config.topup_amount;
            if let Some(route_node) = swap_params.route_node {
                let ekubo_router = self.ekubo_router.read();
                let forge_amount: u128 = swap_params.forge_amount.into();
                yin.transfer(ekubo_router.contract_address, forge_amount.into());
                ekubo_router
                    .swap(
                        route_node,
                        TokenAmount { token: yin.contract_address, amount: forge_amount.into() },
                    );

                // Take slippage into account for non-CASH tokens to
                // calculate the minimum amount required
                let minimum: u128 = rmul_wr(
                    config.topup_amount.into(), RAY_ONE.into() - config.conditions.slippage,
                )
                    .into();
                let router_clear = IClearDispatcher {
                    contract_address: ekubo_router.contract_address,
                };
                topup_amount = router_clear
                    .clear_minimum_to_recipient(
                        EkuboERC20Dispatcher { contract_address: config.asset },
                        minimum.into(),
                        config.destination,
                    )
                    .try_into()
                    .unwrap();
            } else {
                yin.transfer(config.destination, swap_params.forge_amount.into());
            }

            self
                .emit(
                    TopupExecuted {
                        trove_id,
                        forge_amount: swap_params.forge_amount,
                        asset: config.asset,
                        topup_amount,
                        destination: config.destination,
                    },
                );
        }

        fn end(ref self: ContractState, trove_id: u64) {
            let archabbot = self.archabbot.read();
            let caller: ContractAddress = get_caller_address();
            rites_utils::assert_caller_is_archabbot(
                caller, archabbot.contract_address, self.get_rite_id(),
            );

            archabbot.on_rite_actions(trove_id, array![Action::None].span());
        }
    }

    #[abi(embed_v0)]
    pub impl ITopupRiteImpl of ITopupRite<ContractState> {
        fn get_swap_params(self: @ContractState, trove_id: u64) -> SwapParams {
            let config = self.topup_configs.read(trove_id);
            let cash = self.yin.read().contract_address;
            self
                .get_swap_params_helper(
                    config.pool_params,
                    config.asset,
                    config.topup_amount,
                    config.conditions.slippage,
                    cash,
                )
        }
    }

    #[generate_trait]
    impl TopupRiteHelpers of TopupRiteHelpersTrait {
        fn get_swap_params_helper(
            self: @ContractState,
            pool_params: EkuboPoolParams,
            asset: ContractAddress,
            topup_amount: u128,
            slippage: Ray,
            cash: ContractAddress,
        ) -> SwapParams {
            if asset == cash {
                SwapParams { forge_amount: topup_amount.into(), route_node: Option::None }
            } else {
                let pool_key: PoolKey = pool_params.into_pool_key(asset, cash);
                let ekubo_core = self.ekubo_core.read();
                let ekubo_router = self.ekubo_router.read();

                let pool_price: PoolPrice = ekubo_core.get_pool_price(pool_key);
                // Catches invalid pools
                assert!(pool_price.sqrt_ratio.is_non_zero(), "{}: Pool price is zero", RITE_ID());

                let cash_is_token0: bool = pool_key.token0 == cash;
                let sqrt_ratio_limit = calculate_sqrt_ratio_limit(
                    pool_price.sqrt_ratio, slippage, cash_is_token0,
                );
                let route_node = RouteNode { pool_key, sqrt_ratio_limit, skip_ahead: 0 };
                // Set amount to negative for exact output swap i.e. amount you want to get out of
                // the pool
                let exact_output_token_amount = TokenAmount {
                    token: asset, amount: -(topup_amount.into()),
                };
                let quote_delta: Delta = ekubo_router
                    .quote_swap(route_node, exact_output_token_amount);
                // Switch amount to positive for exact input swap
                // i.e. amount you need/want to provide to the pool
                let mut cash_amount: u128 = if cash_is_token0 {
                    quote_delta.amount0.try_into().unwrap()
                } else {
                    quote_delta.amount1.try_into().unwrap()
                };
                // Add 1 wei to account for AMM rounding
                // assuming 1 tick for the general case
                cash_amount += 1;
                SwapParams {
                    forge_amount: cash_amount.into(), route_node: Option::Some(route_node),
                }
            }
        }
    }

    fn RITE_ID() -> ByteArray {
        "TOPUP"
    }
}
