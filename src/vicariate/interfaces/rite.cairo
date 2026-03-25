#[starknet::interface]
pub trait IRite<TContractState> {
    // Returns whether the rite can be executed based on the rite's conditions
    fn is_ready(self: @TContractState, trove_id: u64) -> bool;
    // Must include a callback to `prior.on_execute_rite(...)`
    fn perform(ref self: TContractState, trove_id: u64);
    // TODO: does this require a callback to Prior?
    // Ends a rite that runs for longer than the initial `perform` call e.g. DCA orders.
    // Does not do anything for one-off rites.
    fn end(ref self: TContractState, trove_id: u64);
}

