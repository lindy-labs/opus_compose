use ekubo::interfaces::router::{RouteNode, TokenAmount};
use opus_compose::vicariate::contracts::rites::types::EkuboPoolParams;
use starknet::ContractAddress;
use starknet::storage_access::StorePacking;
use wadray::{Ray, Wad};

const TWO_POW_128: felt252 = 0x100000000000000000000000000000000;
const MASK_128: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

#[derive(Copy, Drop, Serde)]
pub struct SwapParams {
    pub forge_amount: Wad,
    pub swap_data: Option<(RouteNode, TokenAmount)>,
}

// Packs min_asset_balance and slippage into a felt252.
// Layout: [slippage (bits 128–250) | min_asset_balance (bits 0–127)]
// Max min_asset_balance: 2^128 - 1 (full u128)
// Max slippage: 2^123 - 1
#[derive(Copy, Drop, Debug, PartialEq, Serde)]
pub struct TopupConditions {
    pub min_asset_balance: u128,
    pub slippage: Ray,
}

impl TopupConditionsPacking of StorePacking<TopupConditions, felt252> {
    fn pack(value: TopupConditions) -> felt252 {
        let slippage: u128 = value.slippage.into();
        value.min_asset_balance.into() + (slippage.into() * TWO_POW_128)
    }

    fn unpack(value: felt252) -> TopupConditions {
        let value: u256 = value.into();
        let slippage: u128 = (value / TWO_POW_128.into()).try_into().unwrap();
        TopupConditions {
            min_asset_balance: (value & MASK_128).try_into().unwrap(),
            slippage: slippage.into()
        }
    }
}

#[derive(Copy, Drop, PartialEq, Serde, starknet::Store)]
pub struct TopupConfig {
    pub asset: ContractAddress,
    pub pool_params: EkuboPoolParams,
    pub conditions: TopupConditions,
    // Topup amount is denominated in the tracked asset
    // Set to zero to disable auto-topup
    pub topup_amount: u128,
    pub destination: ContractAddress,
}
