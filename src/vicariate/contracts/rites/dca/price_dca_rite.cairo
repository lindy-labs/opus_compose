#[starknet::contract]
pub mod price_dca_rite {
    use core::num::traits::Zero;
    use ekubo::extensions::oracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use ekubo::interfaces::extensions::twamm::{OrderInfo, OrderKey};
    use ekubo::interfaces::positions::{IPositionsDispatcher, IPositionsDispatcherTrait};
    use ekubo::types::keys::PoolKey;
    use opus::interfaces::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use opus::types::AssetBalance;
    use opus::utils::math::convert_ekubo_oracle_price_to_wad;
    use opus_compose::constants;
    use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus_compose::vicariate::contracts::rites::types::EkuboPoolParamsTrait;
    use opus_compose::vicariate::contracts::rites::dca::types::{
        ConsolidatedOrderData, DcaDurationTrait, DcaOrder, OrderStatus, OrderType, PriceDcaConfig,
    };
    use opus_compose::vicariate::contracts::rites::dca::utils::dca_utils;
    use opus_compose::vicariate::contracts::rites::utils::rites_utils;
    use opus_compose::vicariate::interfaces::prior::{IPriorDispatcher, IPriorDispatcherTrait};
    use opus_compose::vicariate::interfaces::rite::IRite;
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
        price_dca_configs: Map<u64, PriceDcaConfig>, // PDCA trove ID -> config
        // Mapping of smart trove ID to Ekubo NFT ID
        twamm_orders: Map<u64, DcaOrder>,
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        PriceDcaConfigUpdated: PriceDcaConfigUpdated,
        TwammOrderCreated: TwammOrderCreated,
        TwammOrderClosed: TwammOrderClosed,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct PriceDcaConfigUpdated {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub trove_id: u64,
        pub config: PriceDcaConfig,
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
    }

    #[abi(embed_v0)]
    pub impl IRiteImpl of IRite<ContractState> {
        fn get_rite_id(self: @ContractState) -> ByteArray {
            RITE_ID()
        }

        fn get_trove_config(self: @ContractState, trove_id: u64) -> Span<felt252> {
            let config = self.price_dca_configs.read(trove_id);
            let mut serialized_config: Array<felt252> = Default::default();
            config.serialize(ref serialized_config);
            serialized_config.span()
        }

        fn set_trove_config(ref self: ContractState, trove_id: u64, config: Span<felt252>) {
            assert!(self.has_ended(trove_id), "{}: Ongoing order", RITE_ID());

            let mut config = config;
            let config: PriceDcaConfig = Serde::<PriceDcaConfig>::deserialize(ref config)
                .expect('PRICE_DCA: Invalid config');
            assert!(config.durations.twap_duration >= MINIMUM_TWAP_DURATION, "{}: TWAP duration too short", RITE_ID());

            let user = get_caller_address();
            let prior_abbot = IAbbotDispatcher {
                contract_address: self.prior.read().contract_address,
            };
            assert!(
                prior_abbot.get_trove_owner(trove_id).expect('PRICE_DCA: Trove not found') == user,
                "{}: Not owner",
                RITE_ID(),
            );

            assert!(
                config.asset.is_non_zero(),
                "{}: Invalid asset",
                RITE_ID(),
            );
            let activated_buy: bool = config.buy_price.is_non_zero();
            let activated_sell: bool = config.sell_price.is_non_zero();
            if activated_buy || activated_sell {
                assert!(
                    config.pool_params.tick_spacing == constants::EKUBO_TWAMM_TICK_SPACING,
                    "{}: Wrong tick spacing",
                    RITE_ID(),
                );
            }
            if activated_buy && activated_sell {
                assert!(config.sell_price > config.buy_price, "{}: Invalid sell price", RITE_ID());
            }

            self.price_dca_configs.write(trove_id, config);

            self.emit(PriceDcaConfigUpdated { user, trove_id, config });
        }

        // Returns true if price conditions and no existing ongoing order
        fn is_ready(self: @ContractState, trove_id: u64) -> bool {
            let order_type: OrderType = self.price_conditions_met(trove_id);
            match order_type {
                OrderType::BuyAsset | OrderType::SellAsset => { self.has_ended(trove_id) },
                OrderType::None => false,
            }
        }

        fn has_ended(self: @ContractState, trove_id: u64) -> bool {
            let order: DcaOrder = self.twamm_orders.read(trove_id);
            if order.position_id.is_zero() {
                return true;
            }
            
            let config = self.price_dca_configs.read(trove_id);
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
            self.close_order(trove_id, false);

            let config = self.price_dca_configs.read(trove_id);
            let cash = self.yin.read().contract_address;
            let pool_key: PoolKey = config.pool_params.into_pool_key(config.asset, cash);

            let yin = self.yin.read();
            let ekubo_positions = self.ekubo_positions.read();

            let mut sell_token: ContractAddress = Zero::zero();
            let mut buy_token: ContractAddress = Zero::zero();
            let mut dca_amount: u128 = Zero::zero();
            let order_type = self.price_conditions_met(trove_id);
            match order_type {
                OrderType::BuyAsset => {
                    let action = Action::Forge(config.buy_amount);
                    prior.on_rite_actions(trove_id, array![action].span());
                    yin.transfer(ekubo_positions.contract_address, config.buy_amount.into());

                    sell_token = yin.contract_address;
                    buy_token = config.asset;
                    dca_amount = config.buy_amount.into();
                },
                OrderType::SellAsset => {
                    let action = Action::Withdraw(
                        AssetBalance { address: config.asset, amount: config.sell_amount },
                    );
                    prior.on_rite_actions(trove_id, array![action].span());
                    IERC20Dispatcher { contract_address: config.asset }
                        .transfer(ekubo_positions.contract_address, config.sell_amount.into());

                    sell_token = config.asset;
                    buy_token = yin.contract_address;
                    dca_amount = config.sell_amount;
                },
                OrderType::None => {
                    // Should be unreachable via Prior since `is_ready` returns false
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
                .write(trove_id, DcaOrder { position_id, fee: pool_key.fee, end_time, order_type });

            self
                .emit(
                    TwammOrderCreated {
                        trove_id,
                        asset: config.asset,
                        order_id: position_id,
                        order_type,
                        fee: pool_key.fee,
                        order_duration: config.durations.order_duration.to_seconds(),
                    },
                );
        }

        fn end(ref self: ContractState, trove_id: u64) {
            let prior = self.prior.read();
            let caller: ContractAddress = get_caller_address();
            rites_utils::assert_caller_is_prior(caller, prior.contract_address, RITE_ID());

            self.close_order(trove_id, true);
        }
    }

    #[generate_trait]
    impl PriceDcaRiteHelpers of PriceDcaRiteHelpersTrait {
        // Returns the price of the asset in CASH
        fn get_asset_price(self: @ContractState, asset: ContractAddress, twap_duration: u64) -> Wad {
            let oracle = self.ekubo_oracle.read();
            let price_x128: u256 = oracle
                .get_price_x128_over_last(asset, self.yin.read().contract_address, twap_duration);

            convert_ekubo_oracle_price_to_wad(
                price_x128, IERC20Dispatcher { contract_address: asset }.decimals(), CASH_DECIMALS,
            )
        }

        fn price_conditions_met(self: @ContractState, trove_id: u64) -> OrderType {
            let config = self.price_dca_configs.read(trove_id);
            // Zero order amounts are used as a flag for disabling price-DCA
            let buy_is_enabled: bool = config.buy_amount.is_non_zero();
            let sell_is_enabled: bool = config.sell_amount.is_non_zero();
            if !buy_is_enabled && !sell_is_enabled {
                return OrderType::None;
            }

            let asset_price: Wad = self.get_asset_price(config.asset, config.durations.twap_duration);
            let should_buy: bool = buy_is_enabled && asset_price <= config.buy_price;
            let should_sell: bool = sell_is_enabled && asset_price >= config.sell_price;
            if should_buy {
                OrderType::BuyAsset
            } else if should_sell {
                OrderType::SellAsset
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
        fn close_order(ref self: ContractState, trove_id: u64, force_closure: bool) {
            let config = self.price_dca_configs.read(trove_id);
            let order: DcaOrder = self.twamm_orders.read(trove_id);
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
            };

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
        "PRICE_DCA"
    }
}
