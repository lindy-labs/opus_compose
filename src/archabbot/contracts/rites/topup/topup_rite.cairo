use opus_compose::archabbot::contracts::rites::topup::types::SwapParams;

#[starknet::interface]
pub trait ITopupRite<TContractState> {
    fn get_swap_params(self: @TContractState, trove_id: u64) -> SwapParams;
}

#[starknet::contract]
pub mod topup_rite {
    use core::num::traits::Zero;
    use ekubo::components::clear::{IClearDispatcher, IClearDispatcherTrait};
    use ekubo::extensions::oracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait};
    use ekubo::interfaces::erc20::IERC20Dispatcher as EkuboERC20Dispatcher;
    use ekubo::interfaces::router::{
        IRouterDispatcher, IRouterDispatcherTrait, RouteNode, TokenAmount,
    };
    use ekubo::math::ticks::tick_to_sqrt_ratio;
    use ekubo::types::delta::Delta;
    use ekubo::types::keys::PoolKey;
    use ekubo::types::pool_price::PoolPrice;
    use opus::interfaces::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use opus_compose::archabbot::contracts::rites::topup::constants::{MAX_SLIPPAGE, TWAP_PERIOD};
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
        ekubo_oracle: IOracleDispatcher,
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
        #[key]
        pub asset: ContractAddress,
        #[key]
        pub destination: ContractAddress,
        pub forge_amount: Wad,
        pub topup_amount: u128,
        pub amount_received: u128,
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
        ekubo_oracle: ContractAddress,
    ) {
        self.yin.write(IERC20Dispatcher { contract_address: yin });
        self.archabbot.write(ICelebrantDispatcher { contract_address: archabbot });

        self.ekubo_core.write(ICoreDispatcher { contract_address: ekubo_core });
        self.ekubo_router.write(IRouterDispatcher { contract_address: ekubo_router });
        self.ekubo_oracle.write(IOracleDispatcher { contract_address: ekubo_oracle });

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
            assert!(config.destination.is_non_zero(), "{}: Invalid destination", RITE_ID());
            assert!(
                config.conditions.slippage.is_non_zero()
                    && config.conditions.slippage <= MAX_SLIPPAGE.into(),
                "{}: Slippage out of acceptable range",
                RITE_ID(),
            );
            assert!(config.asset.is_non_zero(), "{}: Invalid asset", RITE_ID());

            if config.topup_amount.is_non_zero() {
                let cash = self.yin.read().contract_address;
                if config.asset != cash {
                    assert!(
                        config.pool_params.tick_spacing.is_non_zero(),
                        "{}: Invalid pool params",
                        RITE_ID(),
                    );
                }
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

                // Catch non-existent pools
                let _swap_params: SwapParams = self
                    .get_swap_params_helper(
                        config.pool_params,
                        config.asset,
                        config.topup_amount,
                        config.conditions.slippage,
                        cash,
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
            let SwapParams {
                forge_amount, route_node,
            } =
                self
                    .get_swap_params_helper(
                        config.pool_params,
                        config.asset,
                        config.topup_amount,
                        config.conditions.slippage,
                        yin.contract_address,
                    );

            archabbot.on_rite_actions(trove_id, array![Action::Forge(forge_amount)].span());

            let mut amount_received = config.topup_amount;
            if let Some(route_node) = route_node {
                let ekubo_router = self.ekubo_router.read();
                let forge_amount: u128 = forge_amount.into();
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
                amount_received = router_clear
                    .clear_minimum_to_recipient(
                        EkuboERC20Dispatcher { contract_address: config.asset },
                        minimum.into(),
                        config.destination,
                    )
                    .try_into()
                    .unwrap();
            } else {
                yin.transfer(config.destination, forge_amount.into());
            }

            self
                .emit(
                    TopupExecuted {
                        trove_id,
                        asset: config.asset,
                        destination: config.destination,
                        forge_amount,
                        topup_amount: config.topup_amount,
                        amount_received,
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

                // Use TWAP-derived sqrt_ratio for the limit to resist spot price manipulation.
                // The forge amount is still sized from the spot-price quote; only the limit
                // (which bounds the swap's worst-case execution price) is anchored to the TWAP.
                let twap_tick = self
                    .ekubo_oracle
                    .read()
                    .get_average_tick_over_last(pool_key.token0, pool_key.token1, TWAP_PERIOD);
                let twap_sqrt_ratio: u256 = tick_to_sqrt_ratio(twap_tick);

                let cash_is_token0: bool = pool_key.token0 == cash;
                let sqrt_ratio_limit = calculate_sqrt_ratio_limit(
                    twap_sqrt_ratio, slippage, cash_is_token0,
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
                // There may be a negligible discrepancy due to AMM rounding depending on the
                // number of ticks crossed. No workarounds are implemented to guarantee the exact
                // topup amount to the smallest decimal so as to preserve the simplicity and
                // efficiency of the existing flow.
                let cash_amount: u128 = if cash_is_token0 {
                    quote_delta.amount0.try_into().unwrap()
                } else {
                    quote_delta.amount1.try_into().unwrap()
                };
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
