/// A contract that implements SRC5 but does NOT register the IRite interface.
/// Used to test that `set_rite` correctly rejects contracts that support SRC5
/// but do not implement the IRite interface.
#[starknet::contract]
pub mod fake_src5_rite {
    use opus_compose::shared::components::src5::SRC5Component;

    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;

    impl SRC5InternalImpl = SRC5Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        src5: SRC5Component::Storage,
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        SRC5Event: SRC5Component::Event,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        // Intentionally do NOT register IRITE_ID.
        // This contract supports SRC5 but claims no rite interface.
    }
}
