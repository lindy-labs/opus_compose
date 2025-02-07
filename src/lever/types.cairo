use ekubo::router_lite::Swap;
use starknet::ContractAddress;
use wadray::{Ray, Wad};

#[derive(Serde, Drop)]
pub enum ModifyLeverAction {
    LeverUp: LeverUpParams,
    LeverDown: LeverDownParams,
}

#[derive(Serde, Drop)]
pub struct ModifyLeverParams {
    pub user: ContractAddress,
    pub action: ModifyLeverAction,
}

#[derive(Serde, Drop)]
pub struct LeverUpParams {
    pub trove_id: u64,
    // Revert if LTV exceeds this value at the end
    pub max_ltv: Ray,
    pub yang: ContractAddress,
    pub max_forge_fee_pct: Wad,
    pub swaps: Array<Swap>,
}

#[derive(Serde, Drop)]
pub struct LeverDownParams {
    pub trove_id: u64,
    // Revert if LTV exceeds this value at the end
    pub max_ltv: Ray,
    pub yang: ContractAddress,
    pub yang_amt: Wad, // Amount of yang to withdraw
    pub swaps: Array<Swap>,
}
