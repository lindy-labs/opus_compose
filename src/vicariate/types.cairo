use opus::types::AssetBalance;
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

