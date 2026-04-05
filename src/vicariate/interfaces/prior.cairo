use opus::types::AssetBalance;
use opus_compose::vicariate::types::{Action, SmartTroveConfig};
use starknet::ContractAddress;
use wadray::Wad;

#[starknet::interface]
pub trait IPrior<TContractState> {
    // Config functions
    fn set_trove_config(ref self: TContractState, trove_id: u64, config: SmartTroveConfig);
    fn get_trove_config(self: @TContractState, trove_id: u64) -> SmartTroveConfig;
    fn get_trove_id_by_index(self: @TContractState, index: u64) -> u64;
    // Rite functions
    fn get_rite(self: @TContractState, trove_id: u64) -> ContractAddress;
    fn set_rite(ref self: TContractState, trove_id: u64, rite: ContractAddress);
    fn can_execute_rite(self: @TContractState, trove_id: u64) -> bool;
    fn execute_rite(ref self: TContractState, trove_id: u64);
    fn end_rite(ref self: TContractState, trove_id: u64);
    fn on_rite_actions(ref self: TContractState, trove_id: u64, actions: Span<Action>);
    // Flashmint functions
    // Mirror Caretaker's release
    fn release(ref self: TContractState, trove_id: u64) -> Span<AssetBalance>;
}

