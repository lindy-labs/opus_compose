use opus_compose::archabbot::contracts::rites::topup::types::TopupConditions;
use opus_compose::archabbot::contracts::rites::types::EkuboPoolParams;
use opus_compose::archabbot::types::TroveConfig;
use starknet::storage_access::StorePacking;
use wadray::{RAY_ONE, RAY_PERCENT, Ray, WAD_ONE, Wad};

// --- EkuboPoolParams packing tests ---

#[test]
fn test_ekubo_pool_params_packing() {
    let pool_params = EkuboPoolParams {
        fee: 0xffffffffffffffffffffffffffffffff_u128,
        tick_spacing: 354892_u128,
        extension: 0x123.try_into().unwrap(),
    };
    let unpacked: EkuboPoolParams = StorePacking::unpack(StorePacking::pack(pool_params));
    assert_eq!(pool_params, unpacked, "ekubo pool params packing failed");
}

#[test]
fn test_ekubo_pool_params_packing_zero() {
    let pool_params = EkuboPoolParams {
        fee: 0_u128, tick_spacing: 0_u128, extension: 0.try_into().unwrap(),
    };
    let unpacked: EkuboPoolParams = StorePacking::unpack(StorePacking::pack(pool_params));
    assert_eq!(pool_params, unpacked, "ekubo pool params zero packing failed");
}

// --- TroveConfig packing tests ---

fn assert_trove_config_roundtrip(relative_threshold: Ray, max_forge_fee_pct: Wad, incentive: Wad) {
    let config = TroveConfig { relative_threshold, max_forge_fee_pct, incentive };
    let unpacked: TroveConfig = StorePacking::unpack(StorePacking::pack(config));
    assert_eq!(config, unpacked, "trove config roundtrip failed");
}

#[test]
fn test_trove_config_packing_zero() {
    assert_trove_config_roundtrip(0_u128.into(), 0_u128.into(), 0_u128.into());
}

#[test]
fn test_trove_config_packing_max_threshold() {
    // relative_threshold capped at RAY_ONE (90 bits)
    assert_trove_config_roundtrip(RAY_ONE.into(), 0_u128.into(), 0_u128.into());
}

#[test]
fn test_trove_config_packing_max_fee_pct() {
    // max_forge_fee_pct capped at 4 * WAD_ONE (62 bits)
    assert_trove_config_roundtrip(0_u128.into(), (4 * WAD_ONE).into(), 0_u128.into());
}

#[test]
fn test_trove_config_packing_max_incentive() {
    // incentive capped at 2^99 - 1 (99 bits) — the maximum that fits in the packing layout
    // Note: archabbot.cairo MAX_INCENTIVE = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFF (2^111-1) exceeds
    // the 99-bit allocation and would not roundtrip correctly through packing.
    let max_incentive: u128 = 0x7FFFFFFFFFFFFFFFFFFFFFFFF; // 2^99 - 1
    assert_trove_config_roundtrip(0_u128.into(), 0_u128.into(), max_incentive.into());
}

#[test]
fn test_trove_config_packing_typical() {
    assert_trove_config_roundtrip(
        (RAY_PERCENT * 80).into(), // 0.8 relative threshold
        (WAD_ONE / 100).into(), // 1% max forge fee
        (WAD_ONE * 5).into() // 5 CASH incentive
    );
}

// --- TopupConditions packing tests ---

fn assert_topup_conditions_roundtrip(min_asset_balance: u128, slippage: Ray) {
    let conditions = TopupConditions { min_asset_balance, slippage };
    let unpacked: TopupConditions = StorePacking::unpack(StorePacking::pack(conditions));
    assert_eq!(conditions, unpacked, "topup conditions roundtrip failed");
}

#[test]
fn test_topup_conditions_packing_zero() {
    assert_topup_conditions_roundtrip(0, 0_u128.into());
}

#[test]
fn test_topup_conditions_packing_max_balance() {
    // min_asset_balance: full u128 range
    assert_topup_conditions_roundtrip(0xffffffffffffffffffffffffffffffff_u128, 0_u128.into());
}

#[test]
fn test_topup_conditions_packing_max_slippage() {
    // Max slippage = 20% = 20 * RAY_PERCENT = 20 * 10^16
    // which is well within the upper 123 bits
    let max_slippage: u128 = 200000000000000000_u128; // 20 * 10^16 = 20 * RAY_PERCENT
    assert_topup_conditions_roundtrip(0, max_slippage.into());
}

#[test]
fn test_topup_conditions_packing_typical() {
    assert_topup_conditions_roundtrip((100 * WAD_ONE), (5 * RAY_PERCENT).into());
}

