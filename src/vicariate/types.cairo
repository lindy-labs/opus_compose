use ekubo::interfaces::router::Swap;
use opus::types::AssetBalance;
use starknet::ContractAddress;
use starknet::storage_access::StorePacking;
use wadray::{Ray, Wad};

// Packing constants for SmartTroveConfig — relative_threshold in lower 128 bits,
// max_forge_fee_pct in upper 123 bits
const TWO_POW_128: u256 = 0x100000000000000000000000000000000;
const MASK_128: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
const MASK_123: u256 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

#[derive(Copy, Drop, Serde)]
pub enum Action {
    None,
    Forge: Wad,
    Melt: Wad,
    Deposit: AssetBalance,
    Withdraw: AssetBalance,
}

// Packs relative_threshold and max_forge_fee_pct into a single felt252.
// Layout: [max_forge_fee_pct (bits 128–250) | relative_threshold (bits 0–127)]
// `relative_threshold` is capped at RAY_ONE
// `max_forge_fee_pct` is capped at 4 * WAD_ONE
#[derive(Copy, Drop, Default, PartialEq, Serde)]
pub struct SmartTroveConfig {
    // Maximum LTV = relative threshold * threshold
    pub relative_threshold: Ray,
    pub max_forge_fee_pct: Wad,
}

impl SmartTroveConfigPacking of StorePacking<SmartTroveConfig, felt252> {
    fn pack(value: SmartTroveConfig) -> felt252 {
        let relative_threshold: u256 = value.relative_threshold.into();
        let max_forge_fee_pct: u256 = value.max_forge_fee_pct.into();
        (relative_threshold + (max_forge_fee_pct * TWO_POW_128)).try_into().unwrap()
    }

    fn unpack(value: felt252) -> SmartTroveConfig {
        let value: u256 = value.into();
        let relative_threshold: u128 = (value & MASK_128).try_into().unwrap();
        let max_forge_fee_pct: u128 = ((value / TWO_POW_128) & MASK_123).try_into().unwrap();
        SmartTroveConfig {
            relative_threshold: relative_threshold.into(),
            max_forge_fee_pct: max_forge_fee_pct.into(),
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
