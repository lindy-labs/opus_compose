use ekubo::router_lite::Swap;
use starknet::ContractAddress;
use wadray::Wad;

#[derive(Serde, Drop)]
pub enum ModifyLeverAction {
    LeverUp: LeverUpParams,
    LeverDown: LeverDownParams
}

#[derive(Serde, Drop)]
pub struct ModifyLeverParams {
    pub caller: ContractAddress,
    pub action: ModifyLeverAction
}

#[derive(Serde, Drop)]
pub struct LeverUpParams {
    pub trove_id: u64,
    pub yang: ContractAddress,
    pub max_forge_fee_pct: Wad,
    pub swaps: Array<Swap>
}

#[derive(Serde, Drop)]
pub struct LeverDownParams {
    pub trove_id: u64,
    pub yang: ContractAddress,
    pub yang_amt: Wad,
    pub swaps: Array<Swap>
}
