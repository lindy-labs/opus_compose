use opus_compose::archabbot::types::{Action, TroveConfig};
use starknet::ContractAddress;

#[starknet::interface]
pub trait ICelebrant<TContractState> {
    // Config functions
    fn set_trove_config(ref self: TContractState, trove_id: u64, config: TroveConfig);
    fn get_trove_config(self: @TContractState, trove_id: u64) -> TroveConfig;
    // Rite functions
    fn get_rite(self: @TContractState, trove_id: u64) -> ContractAddress;
    fn set_rite(ref self: TContractState, trove_id: u64, rite: ContractAddress);
    fn can_execute_rite(self: @TContractState, trove_id: u64) -> bool;
    fn execute_rite(ref self: TContractState, trove_id: u64);
    fn end_rite(ref self: TContractState, trove_id: u64);
    fn on_rite_actions(ref self: TContractState, trove_id: u64, actions: Span<Action>);
}

