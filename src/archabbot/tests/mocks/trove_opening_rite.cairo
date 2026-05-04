use starknet::ContractAddress;

/// A malicious rite that opens a new trove during end() and then attempts
/// to call end_rite on it. Since the rite is the owner of the new trove,
/// assert_trove_owner passes, but the transient_trove_id guard catches it.
#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct TroveOpeningRiteConfig {
    pub yang: ContractAddress,
    pub asset_amount: u128,
    pub forge_amount: u128,
    pub max_forge_fee_pct: u128,
}

#[starknet::contract]
pub mod trove_opening_rite {
    use opus::interfaces::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use opus::types::AssetBalance;
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
    use super::TroveOpeningRiteConfig;

    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;

    impl SRC5InternalImpl = SRC5Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        abbot: IAbbotDispatcher,
        archabbot: ICelebrantDispatcher,
        configs: Map<u64, TroveOpeningRiteConfig>,
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        SRC5Event: SRC5Component::Event,
    }

    #[constructor]
    fn constructor(ref self: ContractState, abbot: ContractAddress, archabbot: ContractAddress) {
        self.abbot.write(IAbbotDispatcher { contract_address: abbot });
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
            let config: TroveOpeningRiteConfig = Serde::<
                TroveOpeningRiteConfig,
            >::deserialize(ref config)
                .expect('TROVE_OPEN_RITE: bad config');
            self.configs.write(trove_id, config);
        }

        fn is_ready(self: @ContractState, trove_id: u64) -> bool {
            let config = self.configs.read(trove_id);
            config.asset_amount > 0
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
        }

        fn end(ref self: ContractState, trove_id: u64) {
            let archabbot = self.archabbot.read();
            let caller: ContractAddress = get_caller_address();
            rites_utils::assert_caller_is_archabbot(
                caller, archabbot.contract_address, self.get_rite_id(),
            );

            // Open a new trove — this contract becomes the owner
            let config = self.configs.read(trove_id);
            let new_trove_id = self.abbot.read()
                .open_trove(
                    array![AssetBalance { address: config.yang, amount: config.asset_amount }]
                        .span(),
                    config.forge_amount.into(),
                    config.max_forge_fee_pct.into(),
                );

            // Try to end_rite on the new trove — assert_trove_owner passes
            // (rite is the owner), but transient_trove_id is set → PANIC
            archabbot.end_rite(new_trove_id);
        }
    }

    fn RITE_ID() -> ByteArray {
        "TROVE_OPENING_RITE"
    }
}
