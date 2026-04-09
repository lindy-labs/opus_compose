#[starknet::contract]
pub mod time_dca_rite {
    use core::num::traits::Zero;
    use opus::interfaces::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use opus_compose::interfaces::erc20::IERC20Dispatcher;
    use opus_compose::shared::components::src5::SRC5Component;
    use opus_compose::vicariate::contracts::rites::dca::ekubo_dca_component::EkuboDcaComponent;
    use opus_compose::vicariate::contracts::rites::dca::ekubo_oracle_component::EkuboOracleComponent;
    use opus_compose::vicariate::contracts::rites::dca::types::{
        DcaOrder, OrderStatus, OrderType, TimeDcaConfig,
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
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address};

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
        time_dca_configs: Map<u64, TimeDcaConfig>,
        // Mapping of smart trove ID to the latest order's timestamp
        latest_order_ts: Map<u64, u64>,
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
        TimeDcaConfigUpdated: TimeDcaConfigUpdated,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct TimeDcaConfigUpdated {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub trove_id: u64,
        pub config: TimeDcaConfig,
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
            let config = self.time_dca_configs.read(trove_id);
            let mut serialized_config: Array<felt252> = Default::default();
            config.serialize(ref serialized_config);
            serialized_config.span()
        }

        fn set_trove_config(ref self: ContractState, trove_id: u64, config: Span<felt252>) {
            let current_config = self.time_dca_configs.read(trove_id);
            let order: DcaOrder = self.ekubo_dca.get_order(trove_id);
            let order_data = self
                .ekubo_dca
                .get_consolidated_order_data(
                    self.yin.read().contract_address, current_config.asset, order,
                );
            assert!(order_data.order_status == OrderStatus::None, "{}: Ongoing order", RITE_ID());

            let mut config = config;
            let config: TimeDcaConfig = Serde::<TimeDcaConfig>::deserialize(ref config)
                .expect('TIME_DCA: Invalid config');

            let user = get_caller_address();
            let prior_abbot = IAbbotDispatcher {
                contract_address: self.prior.read().contract_address,
            };
            assert!(
                prior_abbot.get_trove_owner(trove_id).expect('TIME_DCA: Trove not found') == user,
                "{}: Not owner",
                RITE_ID(),
            );

            assert!(config.asset.is_non_zero(), "{}: Invalid asset", RITE_ID());
            assert!(
                config.conditions.order_type != OrderType::None,
                "{}: Invalid order type",
                RITE_ID(),
            );

            self.time_dca_configs.write(trove_id, config);

            self.emit(TimeDcaConfigUpdated { user, trove_id, config });
        }

        // Returns true if
        // 1. the configured frequency period has elapsed since the last order; and
        // 2. the last order has completed (whether withdrawn or not).
        fn is_ready(self: @ContractState, trove_id: u64) -> bool {
            let config = self.time_dca_configs.read(trove_id);
            // Zero frequency is used as a flag for disabling time-DCA
            if config.conditions.order_frequency.is_zero() {
                return false;
            }

            let current_ts: u64 = get_block_timestamp();
            let latest_order_ts: u64 = self.latest_order_ts.read(trove_id);
            let earliest_next_order_ts: u64 = latest_order_ts + config.conditions.order_frequency;
            if earliest_next_order_ts >= current_ts {
                self.ekubo_dca.has_ended(self.yin.read().contract_address, config.asset, trove_id)
            } else {
                false
            }
        }

        fn has_ended(self: @ContractState, trove_id: u64) -> bool {
            let config = self.time_dca_configs.read(trove_id);
            self.ekubo_dca.has_ended(self.yin.read().contract_address, config.asset, trove_id)
        }

        fn perform(ref self: ContractState, trove_id: u64) {
            let prior = self.prior.read();
            let caller: ContractAddress = get_caller_address();
            // Prior should have checked that the rite can be executed
            rites_utils::assert_caller_is_prior(caller, prior.contract_address, RITE_ID());

            // Close existing + complete order if any
            // Reverts if existing + ongoing order
            let config = self.time_dca_configs.read(trove_id);
            let order: DcaOrder = self.ekubo_dca.get_order(trove_id);
            let yin: IERC20Dispatcher = self.yin.read();
            self.ekubo_dca.close_order(yin, prior, trove_id, config.asset, order, false, RITE_ID());

            self
                .ekubo_dca
                .create_order(
                    yin,
                    prior,
                    trove_id,
                    config.asset,
                    config.pool_params,
                    config.conditions.order_type,
                    config.conditions.order_duration,
                    config.conditions.amount,
                    RITE_ID(),
                );
            self.latest_order_ts.write(trove_id, get_block_timestamp());
        }

        fn end(ref self: ContractState, trove_id: u64) {
            let prior = self.prior.read();
            let caller: ContractAddress = get_caller_address();
            rites_utils::assert_caller_is_prior(caller, prior.contract_address, RITE_ID());

            let config = self.time_dca_configs.read(trove_id);
            let order: DcaOrder = self.ekubo_dca.get_order(trove_id);
            self
                .ekubo_dca
                .close_order(
                    self.yin.read(), prior, trove_id, config.asset, order, true, RITE_ID(),
                );
        }
    }

    #[generate_trait]
    impl TimeDcaRiteHelpers of TimeDcaRiteHelpersTrait {
        // Returns the order type based on
        // 1. the configured frequency period has elapsed since the last order; and
        // 2. the last order has completed (whether withdrawn or not).
        fn get_order_type(self: @ContractState, trove_id: u64, config: TimeDcaConfig) -> OrderType {
            // Zero frequency is used as a flag for disabling time-DCA
            if config.conditions.order_frequency.is_zero() {
                return OrderType::None;
            }

            let current_ts: u64 = get_block_timestamp();
            let latest_order_ts: u64 = self.latest_order_ts.read(trove_id);
            let earliest_next_order_ts: u64 = latest_order_ts + config.conditions.order_frequency;
            // TODO
            if earliest_next_order_ts >= current_ts {
                config.conditions.order_type
            } else {
                OrderType::None
            }
        }
    }

    fn RITE_ID() -> ByteArray {
        "TIME_DCA"
    }
}
