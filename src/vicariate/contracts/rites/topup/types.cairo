use ekubo::interfaces::router::{RouteNode, TokenAmount};
use opus_compose::vicariate::contracts::rites::types::EkuboPoolParams;
use starknet::ContractAddress;
use starknet::storage_access::StorePacking;
use wadray::{Ray, Wad};

// Packing constants for TopupAmounts — 125 bits per member, 250 bits total in u256
const TWO_POW_125: u256 = 0x20000000000000000000000000;
const MASK_125: u256 = 0x1FFFFFFFFFFFFFFFFFFFFFFF;

#[derive(Copy, Drop, Serde)]
pub struct SwapParams {
    pub forge_amount: Wad,
    pub swap_data: Option<(RouteNode, TokenAmount)>,
}

// Packs min_asset_balance and topup_amount into a felt252 at 125 bits each.
// Layout: [topup_amount (bits 125–249) | min_asset_balance (bits 0–124)]
// Max value per member: 2^125 - 1
#[derive(Copy, Drop, Debug, PartialEq, Serde)]
pub struct TopupAmounts {
    pub min_asset_balance: u128,
    // Topup amount is denominated in the tracked asset
    // Set to zero to disable auto-topup
    pub topup_amount: u128,
}

impl TopupAmountsPacking of StorePacking<TopupAmounts, felt252> {
    fn pack(value: TopupAmounts) -> felt252 {
        let min_asset_balance: u256 = value.min_asset_balance.into();
        let topup_amount: u256 = value.topup_amount.into();
        assert!(min_asset_balance <= MASK_125, "min_asset_balance exceeds 125 bits");
        assert!(topup_amount <= MASK_125, "topup_amount exceeds 125 bits");
        (min_asset_balance + (topup_amount * TWO_POW_125)).try_into().unwrap()
    }

    fn unpack(value: felt252) -> TopupAmounts {
        let value: u256 = value.into();
        TopupAmounts {
            min_asset_balance: (value & MASK_125).try_into().unwrap(),
            topup_amount: ((value / TWO_POW_125) & MASK_125).try_into().unwrap(),
        }
    }
}

#[derive(Copy, Drop, PartialEq, Serde, starknet::Store)]
pub struct TopupConfig {
    pub asset: ContractAddress,
    pub pool_params: EkuboPoolParams,
    pub amounts: TopupAmounts,
    pub destination: ContractAddress,
    pub slippage: Ray,
}
