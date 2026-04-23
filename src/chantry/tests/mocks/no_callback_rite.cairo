#[starknet::contract]
pub mod no_callback_rite {
    use opus_compose::shared::components::src5::SRC5Component;
    use opus_compose::chantry::contracts::rites::utils::rites_utils;
    use opus_compose::chantry::interfaces::archabbot::IArchabbotDispatcher;
    use opus_compose::chantry::interfaces::rite::{IRITE_ID, IRite};
    use starknet::storage::{
        StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address};

    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;

    impl SRC5InternalImpl = SRC5Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        archabbot: IArchabbotDispatcher,
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
            array![].span()
        }

        fn set_trove_config(ref self: ContractState, trove_id: u64, config: Span<felt252>) {
            // No-op: no config needed
        }

        fn is_ready(self: @ContractState, trove_id: u64) -> bool {
            true
        }

        fn has_ended(self: @ContractState, trove_id: u64) -> bool {
            true
        }

        fn perform(ref self: ContractState, trove_id: u64) {
            let archabbot = self.archabbot.read();
            let caller: ContractAddress = get_caller_address();
            rites_utils::assert_caller_is_archabbot(caller, archabbot.contract_address, self.get_rite_id());

            // Intentionally does NOT call archabbot.on_rite_actions(...)
        }

        fn end(ref self: ContractState, trove_id: u64) {
            let archabbot = self.archabbot.read();
            let caller: ContractAddress = get_caller_address();
            rites_utils::assert_caller_is_archabbot(caller, archabbot.contract_address, self.get_rite_id());

            // Intentionally does NOT call archabbot.on_rite_actions(...)
        }
    }

    fn RITE_ID() -> ByteArray {
        "NO_CALLBACK_RITE"
    }
}


