use opus_compose::lever::types::{LeverDownParams, LeverUpParams};
use wadray::Wad;

#[starknet::interface]
pub trait ILever<TContractState> {
    // external
    fn up(ref self: TContractState, amount: Wad, lever_up_params: LeverUpParams);
    fn down(ref self: TContractState, amount: Wad, lever_down_params: LeverDownParams);
}
