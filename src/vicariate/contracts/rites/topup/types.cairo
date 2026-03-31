use ekubo::interfaces::router::{RouteNode, TokenAmount};
use opus_compose::vicariate::contracts::rites::types::EkuboPoolParams;
use starknet::ContractAddress;
use wadray::{Ray, Wad};

#[derive(Copy, Drop, Serde)]
pub struct SwapParams {
    pub forge_amount: Wad,
    pub swap_data: Option<(RouteNode, TokenAmount)>,
}

#[derive(Copy, Drop, PartialEq, Serde, starknet::Store)]
pub struct TopupConfig {
    pub asset: ContractAddress,
    pub pool_params: EkuboPoolParams,
    pub min_asset_balance: u128,
    // Topup amount is denominated in the tracked asset
    // Set to zero to disable auto-topup
    pub topup_amount: u128,
    pub destination: ContractAddress,
    pub slippage: Ray,
}
