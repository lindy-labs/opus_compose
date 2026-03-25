use starknet::ContractAddress;
use wadray::Wad;

// Prices and amounts are denominated in CASH
#[derive(Copy, Drop, PartialEq, Serde, starknet::Store)]
pub struct AutoDcaConfig {
    pub asset: ContractAddress,
    // Set to zero to disable
    pub buy_price: Wad,
    pub buy_amount: Wad,
    pub sell_price: Wad,
    pub sell_amount: Wad,
    pub dca_duration: u64,
}

