use ekubo::types::keys::PoolKey;
use opus::types::AssetBalance;
use opus_compose::atu_abbot::types::AtuTroveConfig;
use starknet::ContractAddress;
use wadray::Ray;

#[starknet::interface]
pub trait IAtuAbbot<TContractState> {
    fn get_trove_id_by_index(self: @TContractState, index: u64) -> u64;
    fn get_trove_config(self: @TContractState, trove_id: u64) -> Option<AtuTroveConfig>;
    fn set_pool_key(ref self: TContractState, asset: ContractAddress, pool_key: PoolKey);
    fn set_trove_config(
        ref self: TContractState,
        trove_id: u64,
        tracked_asset: ContractAddress,
        min_tracked_asset_balance: u128,
        topup_amount: u128,
        destination: ContractAddress,
        relative_threshold: Option<Ray>,
    );
    fn should_topup(self: @TContractState, trove_id: u64) -> bool;
    fn execute_topup(ref self: TContractState, trove_id: u64);
    // Mirror Caretaker's release
    fn release(ref self: TContractState, trove_id: u64) -> Span<AssetBalance>;
}
