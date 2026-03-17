#[starknet::interface]
pub trait IRite<TContractState> {
    // Returns whether the rite can be executed based on the rite's conditions
    fn is_ready(self: @TContractState, trove_id: u64) -> bool;
    // Must include a callback to `prior.on_execute_rite(...)`
    fn perform(ref self: TContractState, trove_id: u64);
    // TODO: Do we need a function to stop rites that last beyond a function call e.g. DCA order?
}

