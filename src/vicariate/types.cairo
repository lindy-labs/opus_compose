use ekubo::interfaces::router::Swap;
use opus::types::AssetBalance;
use starknet::ContractAddress;
use starknet::storage_access::StorePacking;
use wadray::{Ray, Wad};

// Packing constants for SmartTroveConfig
// Layout: [incentive_amount (bits 152–250, 99 bits) | max_forge_fee_pct (bits 90–151, 62 bits)
// | relative_threshold (bits 0–89, 90 bits)]
// `relative_threshold` is capped at RAY_ONE (10^27, requires 90 bits)
// `max_forge_fee_pct` is capped at 4 * WAD_ONE (4 * 10^18, requires 62 bits)
// `incentive_amount` is capped at 2^99 - 1 (99 bits)
// Total: 90 + 62 + 99 = 251 bits ≤ felt252
const TWO_POW_90: u256 = 0x4000000000000000000000000000;
const TWO_POW_152: u256 = 0x100000000000000000000000000000000;
const MASK_90: u256 = 0x3FFFFFFFFFFFFFFFFFFFFFFFFF;
const MASK_62: u256 = 0x3FFFFFFFFFFFFFFF;
const MASK_99: u256 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFF;

#[derive(Copy, Drop, Serde)]
pub enum Action {
    None,
    Forge: Wad,
    Melt: Wad,
    Deposit: AssetBalance,
    Withdraw: AssetBalance,
}

// Packs relative_threshold, max_forge_fee_pct, and incentive into a single felt252.
// Layout: [incentive_amount (bits 152–250, 99 bits) | max_forge_fee_pct (bits 90–151, 62 bits)
// | relative_threshold (bits 0–89, 90 bits)]
// `relative_threshold` is capped at RAY_ONE (10^27)
// `max_forge_fee_pct` is capped at 4 * WAD_ONE (4 * 10^18)
// `incentive` is capped at 2^99 - 1
#[derive(Copy, Drop, Default, PartialEq, Serde)]
pub struct SmartTroveConfig {
    // Maximum LTV = relative threshold * threshold
    pub relative_threshold: Ray,
    pub max_forge_fee_pct: Wad,
    // Amount of CASH to be minted to keeper
    pub incentive: Wad,
}

impl SmartTroveConfigPacking of StorePacking<SmartTroveConfig, felt252> {
    fn pack(value: SmartTroveConfig) -> felt252 {
        let relative_threshold: u256 = value.relative_threshold.into();
        let max_forge_fee_pct: u256 = value.max_forge_fee_pct.into();
        let incentive: u256 = value.incentive.into();
        (relative_threshold + (max_forge_fee_pct * TWO_POW_90) + (incentive * TWO_POW_152))
            .try_into()
            .unwrap()
    }

    fn unpack(value: felt252) -> SmartTroveConfig {
        let value: u256 = value.into();
        let relative_threshold: u128 = (value & MASK_90).try_into().unwrap();
        let max_forge_fee_pct: u128 = ((value / TWO_POW_90) & MASK_62).try_into().unwrap();
        let incentive: u128 = ((value / TWO_POW_152) & MASK_99).try_into().unwrap();
        SmartTroveConfig {
            relative_threshold: relative_threshold.into(),
            max_forge_fee_pct: max_forge_fee_pct.into(),
            incentive: incentive.into(),
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
    pub yang: ContractAddress,
    pub swaps: Array<Swap>,
}

#[derive(Serde, Drop)]
pub struct LeverDownParams {
    pub trove_id: u64,
    pub yang_asset: AssetBalance,
    pub swaps: Array<Swap>,
}
