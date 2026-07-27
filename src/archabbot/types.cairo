use core::num::traits::DivRem;
use ekubo::interfaces::router::Swap;
use opus::types::AssetBalance;
use starknet::ContractAddress;
use starknet::storage_access::StorePacking;
use wadray::{Ray, Wad};

#[derive(Copy, Drop, Serde)]
pub enum Action {
    None,
    Forge: Wad,
    Melt: Wad,
    Deposit: AssetBalance,
    Withdraw: AssetBalance,
}

// Packing constants for TroveConfig
const TWO_POW_90: u256 = 0x40000000000000000000000;
const TWO_POW_62: u256 = 0x4000000000000000;
const TWO_POW_152: u256 = 0x100000000000000000000000000000000000000;

// Packs relative_threshold, max_forge_fee_pct, and incentive into a single felt252.
// Layout: [incentive_amount (bits 152–250, 99 bits) | max_forge_fee_pct (bits 90–151, 62 bits)
// | relative_threshold (bits 0–89, 90 bits)]
// Archabbot caps the following values:
// `relative_threshold`: RAY_ONE (10^27)
// `max_forge_fee_pct`: 4 * WAD_ONE (4 * 10^18)
// `incentive`: 2^99 - 1
#[derive(Copy, Drop, Debug, Default, PartialEq, Serde)]
pub struct TroveConfig {
    // Maximum LTV = relative threshold * threshold
    pub relative_threshold: Ray,
    pub max_forge_fee_pct: Wad,
    // Amount of CASH to be minted to keeper
    pub incentive: Wad,
}

impl TroveConfigPacking of StorePacking<TroveConfig, felt252> {
    fn pack(value: TroveConfig) -> felt252 {
        let relative_threshold: u256 = value.relative_threshold.into();
        let max_forge_fee_pct: u256 = value.max_forge_fee_pct.into();
        let incentive: u256 = value.incentive.into();
        (relative_threshold + (max_forge_fee_pct * TWO_POW_90) + (incentive * TWO_POW_152))
            .try_into()
            .unwrap()
    }

    fn unpack(value: felt252) -> TroveConfig {
        let value: u256 = value.into();
        let (rest, relative_threshold) = DivRem::div_rem(value, TWO_POW_90.try_into().unwrap());
        let (incentive, max_forge_fee_pct) = DivRem::div_rem(rest, TWO_POW_62.try_into().unwrap());
        let relative_threshold: u128 = relative_threshold.try_into().unwrap();
        TroveConfig {
            relative_threshold: relative_threshold.into(),
            max_forge_fee_pct: max_forge_fee_pct.try_into().unwrap(),
            incentive: incentive.try_into().unwrap(),
        }
    }
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
    pub min_asset_amount: u128,
    pub swaps: Array<Swap>,
}

#[derive(Serde, Drop)]
pub struct LeverDownParams {
    pub trove_id: u64,
    // Revert if LTV exceeds this value at the end
    pub max_ltv: Ray,
    pub yang: ContractAddress,
    pub yang_amt: Wad,
    pub swaps: Array<Swap>,
}
