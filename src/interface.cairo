use wadray::Wad;
use starknet::ContractAddress;

#[starknet::interface]
pub trait ILever<TContractState> {
    // external
    fn up(
        ref self: TContractState,
        trove_id: u64,
        amount: Wad,
        yang: ContractAddress,
        max_forge_fee_pct: Wad
    );
    fn down(
        ref self: TContractState, trove_id: u64, amount: Wad, yang: ContractAddress, yang_amt: Wad
    );
}
