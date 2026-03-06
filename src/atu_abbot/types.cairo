use starknet::ContractAddress;
use wadray::{Ray, Wad};

#[derive(Copy, Drop, PartialEq, Serde, starknet::Store)]
pub struct AtuTroveConfig {
    pub tracked_asset: ContractAddress,
    pub min_tracked_asset_balance: u128,
    // Topup amount is denominated in the trackd asset
    // Set to zero to disable auto-topup
    pub topup_amount: u128,
    pub destination: ContractAddress,
    pub relative_threshold: Ray,
    pub max_forge_fee_pct: Wad,
}
