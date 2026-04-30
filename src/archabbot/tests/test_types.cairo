use opus_compose::archabbot::contracts::rites::dca::types::{
    DcaOrder, DcaOrderDuration, OrderType, PriceConditions, PriceDcaDurations, TimeDcaConditions,
};
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

// --- PriceDcaDurations packing tests ---

fn assert_price_dca_durations_roundtrip(twap: u64, order_duration: DcaOrderDuration) {
    let d = PriceDcaDurations { twap_duration: twap, order_duration };
    let u: PriceDcaDurations = StorePacking::unpack(StorePacking::pack(d));
    assert_eq!(d, u, "price dca durations roundtrip failed");
}

#[test]
fn test_price_dca_durations_packing_max_twap() {
    assert_price_dca_durations_roundtrip(0xffffffffffffffff_u64, DcaOrderDuration::SixMonths);
}

#[test]
fn test_price_dca_durations_packing_zero_twap() {
    assert_price_dca_durations_roundtrip(0_u64, DcaOrderDuration::ThreeHours);
}

#[test]
fn test_price_dca_durations_packing_all_variants() {
    let twap: u64 = 0x8000040000000000;
    assert_price_dca_durations_roundtrip(twap, DcaOrderDuration::ThreeHours);
    assert_price_dca_durations_roundtrip(twap, DcaOrderDuration::SixHours);
    assert_price_dca_durations_roundtrip(twap, DcaOrderDuration::TwelveHours);
    assert_price_dca_durations_roundtrip(twap, DcaOrderDuration::TwentyFourHours);
    assert_price_dca_durations_roundtrip(twap, DcaOrderDuration::ThreeDays);
    assert_price_dca_durations_roundtrip(twap, DcaOrderDuration::OneWeek);
    assert_price_dca_durations_roundtrip(twap, DcaOrderDuration::TwoWeeks);
    assert_price_dca_durations_roundtrip(twap, DcaOrderDuration::OneMonth);
    assert_price_dca_durations_roundtrip(twap, DcaOrderDuration::ThreeMonths);
    assert_price_dca_durations_roundtrip(twap, DcaOrderDuration::SixMonths);
}

// --- DcaOrder packing tests ---

fn assert_dca_order_roundtrip(position_id: u64, fee: u128, end_time: u64, order_type: OrderType) {
    let o = DcaOrder { position_id, fee, end_time, order_type };
    let u: DcaOrder = StorePacking::unpack(StorePacking::pack(o));
    assert_eq!(o, u, "dca order roundtrip failed");
}

#[test]
fn test_dca_order_packing_max_values() {
    assert_dca_order_roundtrip(
        0xffffffffffffffff_u64,
        0xffffffffffffffffffffffffffffffff_u128,
        0x3fffffffffffffff_u64,
        OrderType::BuyAsset,
    );
}

#[test]
fn test_dca_order_packing_zero() {
    assert_dca_order_roundtrip(0_u64, 0_u128, 0_u64, OrderType::None);
}

#[test]
fn test_dca_order_packing_all_types() {
    assert_dca_order_roundtrip(0x8000040000000000_u64, 1_u128, 100_u64, OrderType::None);
    assert_dca_order_roundtrip(0x8000040000000000_u64, 1_u128, 100_u64, OrderType::BuyAsset);
    assert_dca_order_roundtrip(0x8000040000000000_u64, 1_u128, 100_u64, OrderType::SellAsset);
}

// --- TroveConfig packing tests ---

fn assert_trove_config_roundtrip(
    relative_threshold: Ray, max_forge_fee_pct: Wad, incentive: Wad,
) {
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

// --- PriceConditions packing tests ---

fn assert_price_conditions_roundtrip(
    buy_price: Wad, buy_amount: Wad, sell_price: Wad, sell_amount: u128,
) {
    let conditions = PriceConditions { buy_price, buy_amount, sell_price, sell_amount };
    let unpacked: PriceConditions = StorePacking::unpack(StorePacking::pack(conditions));
    assert_eq!(conditions, unpacked, "price conditions roundtrip failed");
}

#[test]
fn test_price_conditions_packing_zero() {
    assert_price_conditions_roundtrip(0_u128.into(), 0_u128.into(), 0_u128.into(), 0);
}

#[test]
fn test_price_conditions_packing_max_amounts() {
    // amounts use full u128 (lower 128 bits), prices masked to 123 bits
    let max_price: u128 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFF; // 123-bit max
    assert_price_conditions_roundtrip(
        max_price.into(),
        0xffffffffffffffffffffffffffffffff_u128.into(), // max buy amount
        max_price.into(),
        0xffffffffffffffffffffffffffffffff_u128 // max sell amount
    );
}

#[test]
fn test_price_conditions_packing_typical() {
    assert_price_conditions_roundtrip(
        (2000 * WAD_ONE).into(), // buy at $2000
        (100 * WAD_ONE).into(), // buy 100 CASH worth
        (2500 * WAD_ONE).into(), // sell at $2500
        50_u128 // sell 50 tokens
    );
}

#[test]
fn test_price_conditions_packing_only_buy() {
    // Only buy enabled (sell_amount = 0 disables sell side)
    assert_price_conditions_roundtrip(
        (1500 * WAD_ONE).into(), (50 * WAD_ONE).into(), 0_u128.into(), 0,
    );
}

#[test]
fn test_price_conditions_packing_only_sell() {
    // Only sell enabled (buy_amount = 0 disables buy side)
    assert_price_conditions_roundtrip(
        0_u128.into(), 0_u128.into(), (3000 * WAD_ONE).into(), 100_u128,
    );
}

// --- TimeDcaConditions packing tests ---

fn assert_time_dca_conditions_roundtrip(
    amount: u128, order_frequency: u64, order_duration: DcaOrderDuration, order_type: OrderType,
) {
    let conditions = TimeDcaConditions { amount, order_frequency, order_duration, order_type };
    let unpacked: TimeDcaConditions = StorePacking::unpack(StorePacking::pack(conditions));
    assert_eq!(conditions, unpacked, "time dca conditions roundtrip failed");
}

#[test]
fn test_time_dca_conditions_packing_zero() {
    assert_time_dca_conditions_roundtrip(0, 0, DcaOrderDuration::ThreeHours, OrderType::None);
}

#[test]
fn test_time_dca_conditions_packing_max_values() {
    assert_time_dca_conditions_roundtrip(
        0xffffffffffffffffffffffffffffffff_u128,
        0xffffffffffffffff_u64,
        DcaOrderDuration::SixMonths,
        OrderType::SellAsset,
    );
}

#[test]
fn test_time_dca_conditions_packing_all_order_types() {
    let amount = 100_u128;
    let frequency = 86400_u64; // 1 day
    assert_time_dca_conditions_roundtrip(
        amount, frequency, DcaOrderDuration::OneWeek, OrderType::None,
    );
    assert_time_dca_conditions_roundtrip(
        amount, frequency, DcaOrderDuration::OneWeek, OrderType::BuyAsset,
    );
    assert_time_dca_conditions_roundtrip(
        amount, frequency, DcaOrderDuration::OneWeek, OrderType::SellAsset,
    );
}

#[test]
fn test_time_dca_conditions_packing_all_durations() {
    let amount = 500_u128;
    let frequency = 604800_u64; // 1 week
    assert_time_dca_conditions_roundtrip(
        amount, frequency, DcaOrderDuration::ThreeHours, OrderType::BuyAsset,
    );
    assert_time_dca_conditions_roundtrip(
        amount, frequency, DcaOrderDuration::SixHours, OrderType::BuyAsset,
    );
    assert_time_dca_conditions_roundtrip(
        amount, frequency, DcaOrderDuration::TwelveHours, OrderType::BuyAsset,
    );
    assert_time_dca_conditions_roundtrip(
        amount, frequency, DcaOrderDuration::TwentyFourHours, OrderType::BuyAsset,
    );
    assert_time_dca_conditions_roundtrip(
        amount, frequency, DcaOrderDuration::ThreeDays, OrderType::BuyAsset,
    );
    assert_time_dca_conditions_roundtrip(
        amount, frequency, DcaOrderDuration::OneWeek, OrderType::BuyAsset,
    );
    assert_time_dca_conditions_roundtrip(
        amount, frequency, DcaOrderDuration::TwoWeeks, OrderType::BuyAsset,
    );
    assert_time_dca_conditions_roundtrip(
        amount, frequency, DcaOrderDuration::OneMonth, OrderType::BuyAsset,
    );
    assert_time_dca_conditions_roundtrip(
        amount, frequency, DcaOrderDuration::ThreeMonths, OrderType::BuyAsset,
    );
    assert_time_dca_conditions_roundtrip(
        amount, frequency, DcaOrderDuration::SixMonths, OrderType::BuyAsset,
    );
}

#[test]
fn test_time_dca_conditions_packing_typical() {
    // Typical: 1000 CASH buy, daily, 1-week orders
    assert_time_dca_conditions_roundtrip(
        1000_u128, 86400_u64, DcaOrderDuration::OneWeek, OrderType::BuyAsset,
    );
}
