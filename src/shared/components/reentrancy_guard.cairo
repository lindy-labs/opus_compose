#[starknet::component]
pub mod reentrancy_guard_component {
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};

    #[storage]
    pub struct Storage {
        entered: bool,
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {}

    #[generate_trait]
    pub impl ReentrancyGuardHelpers<
        TContractState, +HasComponent<TContractState>,
    > of ReentrancyGuardHelpersTrait<TContractState> {
        fn start(ref self: ComponentState<TContractState>) {
            assert(!self.entered.read(), 'RG: reentrant call');
            self.entered.write(true);
        }

        fn end(ref self: ComponentState<TContractState>) {
            self.entered.write(false);
        }
    }
}
