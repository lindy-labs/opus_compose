#[starknet::contract]
pub mod price_dca_rite {
    use core::num::traits::Zero;
    use opus::interfaces::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use opus_compose::constants;
    use opus_compose::interfaces::erc20::IERC20Dispatcher;
    use opus_compose::shared::components::src5::SRC5Component;
    use opus_compose::vicariate::contracts::rites::dca::ekubo_dca_component::EkuboDcaComponent;
    use opus_compose::vicariate::contracts::rites::dca::ekubo_oracle_component::EkuboOracleComponent;
    use opus_compose::vicariate::contracts::rites::dca::types::{
        DcaOrder, OrderStatus, OrderType, PriceDcaConfig,
    };
    use opus_compose::vicariate::contracts::rites::utils::rites_utils;
    use opus_compose::vicariate::interfaces::prior::IPriorDispatcher;
    use opus_compose::vicariate::interfaces::rite::{IRITE_ID, IRite};

    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: EkuboDcaComponent, storage: ekubo_dca, event: EkuboDcaEvent);
    component!(path: EkuboOracleComponent, storage: ekubo_oracle, event: EkuboOracleEvent);

    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;

    impl SRC5InternalImpl = SRC5Component::InternalImpl<ContractState>;
    impl EkuboDcaInternalImpl = EkuboDcaComponent::InternalImpl<ContractState>;
    impl EkuboOracleInternalImpl = EkuboOracleComponent::InternalImpl<ContractState>;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address};
    use wadray::Wad;

    pub const MINIMUM_TWAP_DURATION: u64 = 5 * 60;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        ekubo_dca: EkuboDcaComponent::Storage,
        #[substorage(v0)]
        ekubo_oracle: EkuboOracleComponent::Storage,
        yin: IERC20Dispatcher,
        prior: IPriorDispatcher,
        price_dca_configs: Map<u64, PriceDcaConfig>,
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        EkuboDcaEvent: EkuboDcaComponent::Event,
        #[flat]
        EkuboOracleEvent: EkuboOracleComponent::Event,
        PriceDcaConfigUpdated: PriceDcaConfigUpdated,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct PriceDcaConfigUpdated {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub trove_id: u64,
        pub config: PriceDcaConfig,
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

        self.ekubo_oracle.set_ekubo_oracle(ekubo_oracle);
        self.ekubo_dca.set_ekubo_positions(ekubo_positions);

        self.src5.register_interface(IRITE_ID);
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
            let current_config = self.price_dca_configs.read(trove_id);
            let order: DcaOrder = self.ekubo_dca.get_order(trove_id);
            let order_data = self
                .ekubo_dca
                .get_consolidated_order_data(
                    self.yin.read().contract_address, current_config.asset, order,
                );
            assert!(order_data.order_status == OrderStatus::None, "{}: Ongoing order", RITE_ID());

            let mut config = config;
            let config: PriceDcaConfig = Serde::<PriceDcaConfig>::deserialize(ref config)
                .expect('PRICE_DCA: Invalid config');
            assert!(
                config.durations.twap_duration >= MINIMUM_TWAP_DURATION,
                "{}: TWAP duration too short",
                RITE_ID(),
            );

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
            let activated_buy: bool = config.price_conditions.buy_price.is_non_zero();
            let activated_sell: bool = config.price_conditions.sell_price.is_non_zero();
            if activated_buy || activated_sell {
                assert!(
                    config.pool_params.tick_spacing == constants::EKUBO_TWAMM_TICK_SPACING,
                    "{}: Wrong tick spacing",
                    RITE_ID(),
                );
            }
            if activated_buy && activated_sell {
                assert!(
                    config.price_conditions.sell_price > config.price_conditions.buy_price,
                    "{}: Invalid sell price",
                    RITE_ID(),
                );
            }

            self.price_dca_configs.write(trove_id, config);

            self.emit(PriceDcaConfigUpdated { user, trove_id, config });
        }

        // Returns true if price conditions and no existing ongoing order
        fn is_ready(self: @ContractState, trove_id: u64) -> bool {
            let config = self.price_dca_configs.read(trove_id);
            match self.get_order_type(config) {
                OrderType::BuyAsset |
                OrderType::SellAsset => {
                    self
                        .ekubo_dca
                        .has_ended(self.yin.read().contract_address, config.asset, trove_id)
                },
                OrderType::None => false,
            }
        }

        fn has_ended(self: @ContractState, trove_id: u64) -> bool {
            let config = self.price_dca_configs.read(trove_id);
            self.ekubo_dca.has_ended(self.yin.read().contract_address, config.asset, trove_id)
        }

        fn perform(ref self: ContractState, trove_id: u64) {
            let prior = self.prior.read();
            let caller: ContractAddress = get_caller_address();
            // Prior should have checked that the rite can be executed
            rites_utils::assert_caller_is_prior(caller, prior.contract_address, RITE_ID());

            // Close existing + complete order if any
            // Reverts if existing + ongoing order
            let config = self.price_dca_configs.read(trove_id);
            let order: DcaOrder = self.ekubo_dca.get_order(trove_id);
            let yin: IERC20Dispatcher = self.yin.read();
            self.ekubo_dca.close_order(yin, prior, trove_id, config.asset, order, false, RITE_ID());

            let order_type = self.get_order_type(config);
            let order_amount: u128 = match order_type {
                OrderType::BuyAsset => { config.price_conditions.buy_amount.into() },
                OrderType::SellAsset => { config.price_conditions.sell_amount },
                OrderType::None => {
                    // Should be unreachable because Prior already checked if
                    // rite is ready for execution
                    Zero::zero()
                },
            };

            self
                .ekubo_dca
                .create_order(
                    yin,
                    prior,
                    trove_id,
                    config.asset,
                    config.pool_params,
                    order_type,
                    config.durations.order_duration,
                    order_amount,
                    RITE_ID(),
                );
        }

        fn end(ref self: ContractState, trove_id: u64) {
            let prior = self.prior.read();
            let caller: ContractAddress = get_caller_address();
            rites_utils::assert_caller_is_prior(caller, prior.contract_address, RITE_ID());

            let config = self.price_dca_configs.read(trove_id);
            let order: DcaOrder = self.ekubo_dca.get_order(trove_id);
            self
                .ekubo_dca
                .close_order(
                    self.yin.read(), prior, trove_id, config.asset, order, true, RITE_ID(),
                );
        }
    }

    #[generate_trait]
    impl PriceDcaRiteHelpers of PriceDcaRiteHelpersTrait {
        // Returns the order type based on the price conditions configured
        fn get_order_type(self: @ContractState, config: PriceDcaConfig) -> OrderType {
            // Zero order amounts are used as a flag for disabling price-DCA
            let buy_is_enabled: bool = config.price_conditions.buy_amount.is_non_zero();
            let sell_is_enabled: bool = config.price_conditions.sell_amount.is_non_zero();
            if !buy_is_enabled && !sell_is_enabled {
                return OrderType::None;
            }

            let asset_price: Wad = self
                .ekubo_oracle
                .get_asset_price(
                    config.asset, self.yin.read().contract_address, config.durations.twap_duration,
                );
            let should_buy: bool = buy_is_enabled
                && asset_price <= config.price_conditions.buy_price;
            let should_sell: bool = sell_is_enabled
                && asset_price >= config.price_conditions.sell_price;
            if should_buy {
                OrderType::BuyAsset
            } else if should_sell {
                OrderType::SellAsset
            } else {
                OrderType::None
            }
        }
    }

    fn RITE_ID() -> ByteArray {
        "PRICE_DCA"
    }
}
