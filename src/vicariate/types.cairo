use ekubo::interfaces::router::Swap;
use opus::types::AssetBalance;
use starknet::ContractAddress;
use wadray::{Ray, Wad};

#[derive(Copy, Drop, Serde)]
pub enum Action {
    Forge: Wad,
    Melt: Wad,
    Deposit: AssetBalance,
    Withdraw: AssetBalance,
}

#[derive(Copy, Drop, Default, PartialEq, Serde, starknet::Store)]
pub struct SmartTroveConfig {
    pub relative_threshold: Ray,
    pub max_forge_fee_pct: Wad,
}

// Lever

#[derive(Serde, Drop)]
pub struct ModifyLeverParams {
    pub user: ContractAddress,
    pub action: ModifyLeverAction,
}

#[derive(Serde, Drop)]
pub enum ModifyLeverAction {
    LeverUp: LeverUpParams,
    LeverDown: LeverDownParams,
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
