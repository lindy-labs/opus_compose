/// Configuration for the reentrant rite.
/// - `target_trove_id`: the trove_id to call execute_rite on during perform/end,
///   simulating a reentrancy attack to test the parallel execution guard.
#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct ReentrantRiteConfig {
    pub target_trove_id: u64,
}

#[starknet::contract]
pub mod reentrant_rite {
    use opus_compose::archabbot::contracts::rites::utils::rites_utils;
    use opus_compose::archabbot::interfaces::celebrant::{
        ICelebrantDispatcher, ICelebrantDispatcherTrait,
    };
    use opus_compose::archabbot::interfaces::rite::{IRITE_ID, IRite};
    use opus_compose::shared::components::src5::SRC5Component;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address};
    use super::ReentrantRiteConfig;

    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;

    impl SRC5InternalImpl = SRC5Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        archabbot: ICelebrantDispatcher,
        configs: Map<u64, ReentrantRiteConfig>,
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        SRC5Event: SRC5Component::Event,
    }

    #[constructor]
    fn constructor(ref self: ContractState, archabbot: ContractAddress) {
        self.archabbot.write(ICelebrantDispatcher { contract_address: archabbot });
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
            let config: ReentrantRiteConfig = Serde::<ReentrantRiteConfig>::deserialize(ref config)
                .expect('REENTRANT_RITE: Invalid config');
            self.configs.write(trove_id, config);
        }

        fn is_ready(self: @ContractState, trove_id: u64) -> bool {
            let config = self.configs.read(trove_id);
            config.target_trove_id > 0
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

            // Reentrancy: attempt to call execute_rite on target trove while
            // transient_trove_id is already set by the outer execute_rite call.
            let config = self.configs.read(trove_id);
            archabbot.execute_rite(config.target_trove_id);
        }

        fn end(ref self: ContractState, trove_id: u64) {
            let archabbot = self.archabbot.read();
            let caller: ContractAddress = get_caller_address();
            rites_utils::assert_caller_is_archabbot(
                caller, archabbot.contract_address, self.get_rite_id(),
            );

            // Reentrancy: attempt to call end_rite on target trove while
            // transient_trove_id is already set by the outer end_rite call.
            let config = self.configs.read(trove_id);
            archabbot.end_rite(config.target_trove_id);
        }
    }

    fn RITE_ID() -> ByteArray {
        "REENTRANT_RITE"
    }
}

