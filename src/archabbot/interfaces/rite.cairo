pub const IRITE_ID: felt252 = 0x2fdb21d0b67fac4101b0c452fbb4164ada08cf00bbb51432b66a323698d2c6a;

#[starknet::interface]
pub trait IRite<TContractState> {
    fn get_rite_id(self: @TContractState) -> ByteArray;
    fn get_trove_config(self: @TContractState, trove_id: u64) -> Span<felt252>;
    fn set_trove_config(ref self: TContractState, trove_id: u64, config: Span<felt252>);
    // Returns whether the rite can be executed based on the rite's conditions
    // For long-running rites, this takes into account whether the rite has ended.
    // An ongoing long-running rite must be ended before it may be performed again.
    fn is_ready(self: @TContractState, trove_id: u64) -> bool;
    // Returns whether the rite has ended
    // Always returns true for rites that end within a single call
    fn has_ended(self: @TContractState, trove_id: u64) -> bool;
    // Must include a callback to `archabbot.on_rite_actions(...)`
    fn perform(ref self: TContractState, trove_id: u64);
    // Ends a rite that runs for longer than the initial `perform` call e.g. DCA orders.
    // This may include stopping a long-running rite before it is completed.
    // It also takes the post-completion actions for long-running rites.
    // Does not do anything for one-off rites.
    fn end(ref self: TContractState, trove_id: u64);
}

