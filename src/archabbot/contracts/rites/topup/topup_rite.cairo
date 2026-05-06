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

    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;

    impl SRC5InternalImpl = SRC5Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        yin: IERC20Dispatcher,
        archabbot: ICelebrantDispatcher,
        ekubo_core: ICoreDispatcher,
        ekubo_router: IRouterDispatcher,
        topup_configs: Map<u64, TopupConfig> // ATU trove ID -> config
    }

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
        pub refunded: Wad,
        pub asset: ContractAddress,
        pub topup_amount: u128,
        pub destination: ContractAddress,
    }

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
            let archabbot_abbot = IAbbotDispatcher {
                contract_address: self.archabbot.read().contract_address,
            };
            assert!(
                archabbot_abbot.get_trove_owner(trove_id).expect('TOPUP: Trove not found') == user,
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
                assert!(
                    config
                        .topup_amount >= config
                        .conditions
                        .min_asset_balance // Prevent multiple topups
                        ,
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

            // Take slippage into account for non-CASH tokens and mint additional CASH
            let adjusted_forge_amount: Wad = if swap_params.swap_data.is_some() {
                rmul_wr(swap_params.forge_amount, RAY_ONE.into() + config.conditions.slippage)
            } else {
                swap_params.forge_amount
            };

            archabbot
                .on_rite_actions(trove_id, array![Action::Forge(adjusted_forge_amount)].span());

            let mut refunded: u256 = Zero::zero();
            if let Some((route_node, token_amount)) = swap_params.swap_data {
                let ekubo_router = self.ekubo_router.read();
                yin.transfer(ekubo_router.contract_address, adjusted_forge_amount.into());
                ekubo_router.swap(route_node, token_amount);

                // Clear at least the topup amount of asset to destination
                let router_clear = IClearDispatcher {
                    contract_address: ekubo_router.contract_address,
                };
                router_clear
                    .clear_minimum_to_recipient(
                        EkuboERC20Dispatcher { contract_address: config.asset },
                        config.topup_amount.into(),
                        config.destination,
                    );

                // Repay excess yin
                refunded = router_clear
                    .clear_minimum_to_recipient(
                        EkuboERC20Dispatcher { contract_address: yin.contract_address },
                        0,
                        archabbot.contract_address,
                    );
                if refunded.is_non_zero() {
                    archabbot
                        .on_rite_actions(
                            trove_id, array![Action::Melt(refunded.try_into().unwrap())].span(),
                        );
                }
            } else {
                yin.transfer(config.destination, adjusted_forge_amount.into());
            }

            self
                .emit(
                    TopupExecuted {
                        trove_id,
                        forge_amount: adjusted_forge_amount,
                        refunded: refunded.try_into().unwrap(),
                        asset: config.asset,
                        topup_amount: config.topup_amount,
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
                SwapParams { forge_amount: topup_amount.into(), swap_data: Option::None }
            } else {
                let pool_key: PoolKey = pool_params.into_pool_key(asset, cash);
                let ekubo_core = self.ekubo_core.read();
                let ekubo_router = self.ekubo_router.read();

                let pool_price: PoolPrice = ekubo_core.get_pool_price(pool_key);
                let cash_is_token0: bool = pool_key.token0 == cash;
                let sqrt_ratio_limit = calculate_sqrt_ratio_limit(
                    pool_price.sqrt_ratio, slippage, cash_is_token0,
                );
                let route_node = RouteNode { pool_key, sqrt_ratio_limit, skip_ahead: 0 };
                // Set amount to negative for exact output swap i.e. amount you want to get out of
                // the pool
                let token_amount = TokenAmount { token: asset, amount: -(topup_amount.into()) };
                let quote_delta: Delta = ekubo_router.quote_swap(route_node, token_amount);
                // Amount is positive i.e. amount you need to provide to the pool
                let cash_amount: u128 = if cash_is_token0 {
                    quote_delta.amount0.try_into().unwrap()
                } else {
                    quote_delta.amount1.try_into().unwrap()
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
