use starknet::ContractAddress;
use wadray::Ray;

#[derive(Copy, Drop, PartialEq, Serde, starknet::Store)]
pub struct AutoTopupConfig {
    pub asset: ContractAddress,
    pub min_asset_balance: u128,
    // Topup amount is denominated in the tracked asset
    // Set to zero to disable auto-topup
    pub topup_amount: u128,
    pub destination: ContractAddress,
    pub slippage: Ray,
}

