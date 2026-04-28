use starknet::ContractAddress;

/// Configuration for a single trove in the mock rite.
/// - `is_deposit`: true = deposit, false = withdraw
/// - `num_calls`: how many times to repeat the action during `perform`
/// - `asset`: the asset address to deposit or withdraw
/// - `amount`: the amount per call
/// - `is_malicious`: if true, passes trove_id + 1 to on_rite_actions
#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
pub struct MockRiteConfig {
    pub is_deposit: bool,
    pub num_calls: u64,
    pub asset: ContractAddress,
    pub amount: u128,
    pub is_malicious: bool,
}

#[starknet::contract]
pub mod mock_rite {
    use opus::types::AssetBalance;
    use opus_compose::chantry::contracts::rites::utils::rites_utils;
    use opus_compose::chantry::interfaces::archabbot::{
        IArchabbotDispatcher, IArchabbotDispatcherTrait,
    };
    use opus_compose::chantry::interfaces::rite::{IRITE_ID, IRite};
    use opus_compose::chantry::types::Action;
    use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus_compose::shared::components::src5::SRC5Component;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address};
    use super::MockRiteConfig;

    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;

    impl SRC5InternalImpl = SRC5Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        archabbot: IArchabbotDispatcher,
        configs: Map<u64, MockRiteConfig> // trove_id -> config
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        SRC5Event: SRC5Component::Event,
    }

    #[constructor]
    fn constructor(ref self: ContractState, archabbot: ContractAddress) {
        self.archabbot.write(IArchabbotDispatcher { contract_address: archabbot });
        self.src5.register_interface(IRITE_ID);
    }

    #[abi(embed_v0)]
    pub impl IRiteImpl of IRite<ContractState> {
        fn get_rite_id(self: @ContractState) -> ByteArray {
            RITE_ID()
        }

        fn get_trove_config(self: @ContractState, trove_id: u64) -> Span<felt252> {
            let config = self.configs.read(trove_id);
            let mut serialized: Array<felt252> = Default::default();
            config.serialize(ref serialized);
            serialized.span()
        }

        fn set_trove_config(ref self: ContractState, trove_id: u64, config: Span<felt252>) {
            let mut config = config;
            let config: MockRiteConfig = Serde::<MockRiteConfig>::deserialize(ref config)
                .expect('MOCK_RITE: Invalid config');

            self.configs.write(trove_id, config);
        }

        fn is_ready(self: @ContractState, trove_id: u64) -> bool {
            let config = self.configs.read(trove_id);
            config.num_calls > 0 && config.amount > 0
        }

        fn has_ended(self: @ContractState, trove_id: u64) -> bool {
            true
        }

        fn perform(ref self: ContractState, trove_id: u64) {
            let archabbot = self.archabbot.read();
            let caller: ContractAddress = get_caller_address();
            rites_utils::assert_caller_is_archabbot(
                caller, archabbot.contract_address, self.get_rite_id(),
            );

            let config = self.configs.read(trove_id);
            let asset_balance = AssetBalance { address: config.asset, amount: config.amount };
            let action = if config.is_deposit {
                let total_asset_amount: u128 = config.num_calls.into() * config.amount;
                IERC20Dispatcher { contract_address: config.asset }
                    .transfer(archabbot.contract_address, total_asset_amount.into());

                Action::Deposit(asset_balance)
            } else {
                Action::Withdraw(asset_balance)
            };

            let target_trove_id = if config.is_malicious {
                trove_id + 1
            } else {
                trove_id
            };
            for _ in 0..config.num_calls {
                archabbot.on_rite_actions(target_trove_id, array![action].span());
            };
        }

        fn end(ref self: ContractState, trove_id: u64) {
            self.perform(trove_id);
        }
    }

    fn RITE_ID() -> ByteArray {
        "MOCK_RITE"
    }
}

