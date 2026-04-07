#[starknet::contract]
pub mod time_dca_rite {
    use core::num::traits::Zero;
    use ekubo::extensions::oracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use ekubo::interfaces::extensions::twamm::{OrderInfo, OrderKey};
    use ekubo::interfaces::positions::{IPositionsDispatcher, IPositionsDispatcherTrait};
    use ekubo::types::keys::PoolKey;
    use opus::interfaces::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use opus::types::AssetBalance;
    use opus::utils::math::convert_ekubo_oracle_price_to_wad;
    use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus_compose::shared::components::src5::SRC5Component;
    use opus_compose::vicariate::contracts::rites::dca::types::{
        ConsolidatedOrderData, DcaDurationTrait, DcaOrder, OrderStatus, OrderType, TimeDcaConfig,
    };
    use opus_compose::vicariate::contracts::rites::dca::utils::dca_utils;
    use opus_compose::vicariate::contracts::rites::types::EkuboPoolParamsTrait;
    use opus_compose::vicariate::contracts::rites::utils::rites_utils;
    use opus_compose::vicariate::interfaces::prior::{IPriorDispatcher, IPriorDispatcherTrait};
    use opus_compose::vicariate::interfaces::rite::{IRITE_ID, IRite};

    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;

    impl SRC5InternalImpl = SRC5Component::InternalImpl<ContractState>;
    use opus_compose::vicariate::types::Action;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address};
    use wadray::Wad;

    const CASH_DECIMALS: u8 = 18;
    pub const MINIMUM_TWAP_DURATION: u64 = 5 * 60;

    #[storage]
    struct Storage {
        yin: IERC20Dispatcher,
        prior: IPriorDispatcher,
        ekubo_oracle: IOracleDispatcher,
        ekubo_positions: IPositionsDispatcher,
        time_dca_configs: Map<u64, TimeDcaConfig>,
        // Mapping of smart trove ID to Ekubo NFT ID
        twamm_orders: Map<u64, DcaOrder>,
        // Mapping of smart trove ID to the latest order's timestamp
        latest_order_ts: Map<u64, u64>,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        TimeDcaConfigUpdated: TimeDcaConfigUpdated,
        TwammOrderCreated: TwammOrderCreated,
        TwammOrderClosed: TwammOrderClosed,
        SRC5Event: SRC5Component::Event,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct TimeDcaConfigUpdated {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub trove_id: u64,
        pub config: TimeDcaConfig,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct TwammOrderCreated {
        #[key]
        pub trove_id: u64,
        #[key]
        pub asset: ContractAddress,
        // This need not be indexed since it is unique for each order
        pub order_id: u64,
        pub order_type: OrderType,
        pub fee: u128,
        pub order_duration: u64,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct TwammOrderClosed {
        #[key]
        pub trove_id: u64,
        #[key]
        pub asset: ContractAddress,
        // This need not be indexed since it is unique for each order
        pub order_id: u64,
        pub order_type: OrderType,
        pub remaining_sell_token: u128,
        pub purchased_buy_token: u128,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        yin: ContractAddress,
        prior: ContractAddress,
        ekubo_oracle: ContractAddress,
        ekubo_positions: ContractAddress,
    ) {
        self.yin.write(IERC20Dispatcher { contract_address: yin });
        self.prior.write(IPriorDispatcher { contract_address: prior });

        self.ekubo_oracle.write(IOracleDispatcher { contract_address: ekubo_oracle });
        self.ekubo_positions.write(IPositionsDispatcher { contract_address: ekubo_positions });

        self.src5.register_interface(IRITE_ID);
    }

    #[abi(embed_v0)]
    pub impl IRiteImpl of IRite<ContractState> {
        fn get_rite_id(self: @ContractState) -> ByteArray {
            RITE_ID()
        }

        fn get_trove_config(self: @ContractState, trove_id: u64) -> Span<felt252> {
            let config = self.time_dca_configs.read(trove_id);
            let mut serialized_config: Array<felt252> = Default::default();
            config.serialize(ref serialized_config);
            serialized_config.span()
        }

        fn set_trove_config(ref self: ContractState, trove_id: u64, config: Span<felt252>) {
            let current_config = self.time_dca_configs.read(trove_id);
            let order: DcaOrder = self.twamm_orders.read(trove_id);
            let order_data = self.get_consolidated_order_data(order, current_config.asset);
            assert!(order_data.order_status == OrderStatus::None, "{}: Ongoing order", RITE_ID());

            let mut config = config;
            let config: TimeDcaConfig = Serde::<TimeDcaConfig>::deserialize(ref config)
                .expect('TIME_DCA: Invalid config');

            let user = get_caller_address();
            let prior_abbot = IAbbotDispatcher {
                contract_address: self.prior.read().contract_address,
            };
            assert!(
                prior_abbot.get_trove_owner(trove_id).expect('PRICE_DCA: Trove not found') == user,
                "{}: Not owner",
                RITE_ID(),
            );

            assert!(config.asset.is_non_zero(), "{}: Invalid asset", RITE_ID());
            assert!(config.order_type != OrderType::None, "{}: Invalid order type", RITE_ID());

            self.time_dca_configs.write(trove_id, config);

            self.emit(TimeDcaConfigUpdated { user, trove_id, config });
        }

        // Returns true if
        // 1. the configured frequency period has elapsed since the last order; and
        // 2. the last order has completed (whether withdrawn or not).
        fn is_ready(self: @ContractState, trove_id: u64) -> bool {
            let config = self.time_dca_configs.read(trove_id);
            // Zero frequency is used as a flag for disabling time-DCA
            if config.durations.order_frequency.is_zero() {
                return false;
            }

            let current_ts: u64 = get_block_timestamp();
            let latest_order_ts: u64 = self.latest_order_ts.read(trove_id);
            let earliest_next_order_ts: u64 = latest_order_ts + config.durations.order_frequency;
            if earliest_next_order_ts >= current_ts {
                self.has_ended(trove_id)
            } else {
                false
            }
        }

        fn has_ended(self: @ContractState, trove_id: u64) -> bool {
            let order: DcaOrder = self.twamm_orders.read(trove_id);
            if order.position_id.is_zero() {
                return true;
            }

            let config = self.time_dca_configs.read(trove_id);
            let consolidated = self.get_consolidated_order_data(order, config.asset);
            match consolidated.order_status {
                OrderStatus::Ongoing => false,
                _ => true,
            }
        }

        fn perform(ref self: ContractState, trove_id: u64) {
            let prior = self.prior.read();
            let caller: ContractAddress = get_caller_address();
            // Prior should have checked that the rite can be executed
            rites_utils::assert_caller_is_prior(caller, prior.contract_address, RITE_ID());

            // Close existing + complete order if any
            // Reverts if existing + ongoing order
            let config = self.time_dca_configs.read(trove_id);
            let order: DcaOrder = self.twamm_orders.read(trove_id);
            self.close_order(trove_id, false, config, order);

            let yin = self.yin.read();
            let pool_key: PoolKey = config
                .pool_params
                .into_pool_key(config.asset, yin.contract_address);

            let ekubo_positions = self.ekubo_positions.read();

            let mut sell_token: ContractAddress = Zero::zero();
            let mut buy_token: ContractAddress = Zero::zero();
            let mut dca_amount: u128 = Zero::zero();
            match config.order_type {
                OrderType::BuyAsset => {
                    let forge_amt: Wad = config.amount.into();
                    let action = Action::Forge(forge_amt);
                    prior.on_rite_actions(trove_id, array![action].span());
                    yin.transfer(ekubo_positions.contract_address, forge_amt.into());

                    sell_token = yin.contract_address;
                    buy_token = config.asset;
                    dca_amount = forge_amt.into();
                },
                OrderType::SellAsset => {
                    let withdraw_amt: u128 = config.amount;
                    let action = Action::Withdraw(
                        AssetBalance { address: config.asset, amount: withdraw_amt },
                    );
                    prior.on_rite_actions(trove_id, array![action].span());
                    IERC20Dispatcher { contract_address: config.asset }
                        .transfer(ekubo_positions.contract_address, withdraw_amt.into());

                    sell_token = config.asset;
                    buy_token = yin.contract_address;
                    dca_amount = withdraw_amt;
                },
                OrderType::None => {
                    // Should be unreachable because it cannot be set in the config
                    return;
                },
            }

            let start_time: u64 = get_block_timestamp();
            let end_time: u64 = config.durations.order_duration.to_valid_end_time(start_time);
            let order_key = OrderKey {
                sell_token,
                buy_token,
                fee: pool_key.fee, // Zero can be used for order that starts immediately
                start_time: 0,
                end_time,
            };

            let (position_id, _sale_rate) = ekubo_positions
                .mint_and_increase_sell_amount(order_key, dca_amount);

            self
                .twamm_orders
                .write(
                    trove_id,
                    DcaOrder {
                        position_id, fee: pool_key.fee, end_time, order_type: config.order_type,
                    },
                );
            self.latest_order_ts.write(trove_id, get_block_timestamp());

            self
                .emit(
                    TwammOrderCreated {
                        trove_id,
                        asset: config.asset,
                        order_id: position_id,
                        order_type: config.order_type,
                        fee: pool_key.fee,
                        order_duration: config.durations.order_duration.to_seconds(),
                    },
                );
        }

        fn end(ref self: ContractState, trove_id: u64) {
            let prior = self.prior.read();
            let caller: ContractAddress = get_caller_address();
            rites_utils::assert_caller_is_prior(caller, prior.contract_address, RITE_ID());

            let config = self.time_dca_configs.read(trove_id);
            let order: DcaOrder = self.twamm_orders.read(trove_id);
            self.close_order(trove_id, true, config, order);
        }
    }

    #[generate_trait]
    impl PriceDcaRiteHelpers of PriceDcaRiteHelpersTrait {
        // Returns the price of the asset in CASH
        fn get_asset_price(
            self: @ContractState, asset: ContractAddress, twap_duration: u64,
        ) -> Wad {
            let oracle = self.ekubo_oracle.read();
            let price_x128: u256 = oracle
                .get_price_x128_over_last(asset, self.yin.read().contract_address, twap_duration);

            convert_ekubo_oracle_price_to_wad(
                price_x128, IERC20Dispatcher { contract_address: asset }.decimals(), CASH_DECIMALS,
            )
        }

        // Returns the order type based on
        // 1. the configured frequency period has elapsed since the last order; and
        // 2. the last order has completed (whether withdrawn or not).
        fn get_order_type(self: @ContractState, trove_id: u64, config: TimeDcaConfig) -> OrderType {
            // Zero frequency is used as a flag for disabling time-DCA
            if config.durations.order_frequency.is_zero() {
                return OrderType::None;
            }

            let current_ts: u64 = get_block_timestamp();
            let latest_order_ts: u64 = self.latest_order_ts.read(trove_id);
            let earliest_next_order_ts: u64 = latest_order_ts + config.durations.order_frequency;
            // TODO
            if earliest_next_order_ts >= current_ts {
                config.order_type
            } else {
                OrderType::None
            }
        }

        fn get_consolidated_order_data(
            self: @ContractState, order: DcaOrder, asset: ContractAddress,
        ) -> ConsolidatedOrderData {
            let mut consolidated = ConsolidatedOrderData {
                order_key: Option::None, order_status: OrderStatus::None, order_info: Option::None,
            };
            if order.position_id.is_zero() {
                return consolidated;
            }

            let order_key: OrderKey = dca_utils::get_order_key_from_order(
                order, self.yin.read().contract_address, asset,
            );
            let ekubo_positions = self.ekubo_positions.read();
            let order_info: OrderInfo = ekubo_positions
                .get_order_info(order.position_id, order_key);

            consolidated.order_key = Option::Some(order_key);
            consolidated.order_info = Option::Some(order_info);

            // Order is ongoing if there are still tokens to sell
            let is_ongoing: bool = order_info.remaining_sell_amount.is_non_zero();
            if is_ongoing {
                consolidated.order_status = OrderStatus::Ongoing;
                return consolidated;
            }

            let has_withdrawn: bool = order_info.purchased_amount.is_zero();
            if has_withdrawn {
                consolidated.order_status = OrderStatus::CompletedAndWithdrawn;
            } else {
                consolidated.order_status = OrderStatus::CompletedNotWithdrawn;
            }

            consolidated
        }

        // Closes a TWAMM order and withdraws the proceeds to Prior directly.
        // Returns a tuple of the amount of sell tokens (only non-zero if the order
        // is stopped before completion) and the amount of buy tokens, both withdrawn
        // to Prior directly.
        fn close_order(
            ref self: ContractState,
            trove_id: u64,
            force_closure: bool,
            config: TimeDcaConfig,
            order: DcaOrder,
        ) {
            let ConsolidatedOrderData {
                order_key, order_status, order_info,
            } = self.get_consolidated_order_data(order, config.asset);

            let ekubo_positions = self.ekubo_positions.read();
            let prior = self.prior.read();

            let mut remaining_sell_token: u128 = Zero::zero();
            let mut purchased_buy_token: u128 = Zero::zero();

            match order_status {
                OrderStatus::None |
                OrderStatus::CompletedAndWithdrawn => {
                    let action = Action::None;
                    prior.on_rite_actions(trove_id, array![action].span());
                    return;
                },
                OrderStatus::CompletedNotWithdrawn => {},
                OrderStatus::Ongoing => {
                    assert!(force_closure, "{}: Ongoing order", RITE_ID());

                    let order_key = order_key.unwrap();
                    let order_info = order_info.unwrap();
                    // Withdraw remaining sell tokens directly to Prior
                    remaining_sell_token = ekubo_positions
                        .decrease_sale_rate_to(
                            order.position_id,
                            order_key,
                            order_info.sale_rate,
                            prior.contract_address,
                        );
                },
            }

            // Withdraw purchased tokens directly to Prior
            let order_key = order_key.unwrap();
            purchased_buy_token = ekubo_positions
                .withdraw_proceeds_from_sale_to(
                    order.position_id, order_key, prior.contract_address,
                );

            let yin: IERC20Dispatcher = self.yin.read();
            let mut buy_token: ContractAddress = Zero::zero();
            let mut sell_token: ContractAddress = Zero::zero();
            let mut actions: Array<Action> = Default::default();
            match order.order_type {
                OrderType::BuyAsset => {
                    let action = Action::Deposit(
                        AssetBalance { address: config.asset, amount: purchased_buy_token },
                    );
                    actions.append(action);

                    buy_token = config.asset;
                    sell_token = yin.contract_address;
                },
                OrderType::SellAsset => {
                    let action = Action::Melt(purchased_buy_token.into());
                    actions.append(action);

                    buy_token = yin.contract_address;
                    sell_token = config.asset;
                },
                OrderType::None => { return; },
            }

            if remaining_sell_token.is_non_zero() {
                match order.order_type {
                    OrderType::BuyAsset => {
                        let action = Action::Melt(remaining_sell_token.into());
                        actions.append(action);
                    },
                    OrderType::SellAsset => {
                        let action = Action::Deposit(
                            AssetBalance { address: config.asset, amount: remaining_sell_token },
                        );
                        actions.append(action);
                    },
                    // This should be unreachable
                    OrderType::None => { return; },
                };
            }

            prior.on_rite_actions(trove_id, actions.span());

            self.twamm_orders.write(trove_id, Default::default());

            self
                .emit(
                    TwammOrderClosed {
                        trove_id,
                        asset: config.asset,
                        order_id: order.position_id,
                        order_type: order.order_type,
                        remaining_sell_token,
                        purchased_buy_token,
                    },
                );
        }
    }

    fn RITE_ID() -> ByteArray {
        "TIME_DCA"
    }
}
