use starknet::ContractAddress;
use wadray::Wad;

// Prices and amounts are denominated in CASH
#[derive(Copy, Drop, PartialEq, Serde, starknet::Store)]
pub struct PriceDcaConfig {
    pub asset: ContractAddress,
    pub buy_price: Wad,
    // Set `buy_amount` to zero to disable buy orders
    pub buy_amount: Wad,
    pub sell_price: Wad,
    // Set `sell_amount` to zero to disable sell orders
    pub sell_amount: Wad,
    // Duration of DCA order
    pub dca_duration: u64,
    // Period to check the TWAP for asset
    pub period: u64,
}

