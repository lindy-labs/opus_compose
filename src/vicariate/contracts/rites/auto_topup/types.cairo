use starknet::ContractAddress;

#[derive(Copy, Drop, PartialEq, Serde, starknet::Store)]
pub struct AutoTopupConfig {
    pub tracked_asset: ContractAddress,
    pub min_tracked_asset_balance: u128,
    // Topup amount is denominated in the trackd asset
    // Set to zero to disable auto-topup
    pub topup_amount: u128,
    pub destination: ContractAddress,
}

#[derive(Copy, Drop, Serde)]
pub struct SwapParams {
    borrow_amount: Wad,
    swap_data: Option<(RouteNode, TokenAmount)>,
}
