use opus_compose::vicariate::contracts::rites::types::EkuboPoolParams;
use opus_compose::vicariate::contracts::rites::dca::types::{
    DcaDuration, DcaDurations, DcaOrder, OrderType,
};
use starknet::storage_access::StorePacking;

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
        fee: 0_u128,
        tick_spacing: 0_u128,
        extension: 0.try_into().unwrap(),
    };
    let unpacked: EkuboPoolParams = StorePacking::unpack(StorePacking::pack(pool_params));
    assert_eq!(pool_params, unpacked, "ekubo pool params zero packing failed");
}

// --- DcaDurations packing tests ---

fn assert_dca_durations_roundtrip(twap: u64, order_duration: DcaDuration) {
    let d = DcaDurations { twap_duration: twap, order_duration };
    let u: DcaDurations = StorePacking::unpack(StorePacking::pack(d));
    assert_eq!(d, u, "dca durations roundtrip failed");
}

#[test]
fn test_dca_durations_packing_max_twap() {
    assert_dca_durations_roundtrip(0xffffffffffffffff_u64, DcaDuration::SixMonths);
}

#[test]
fn test_dca_durations_packing_zero_twap() {
    assert_dca_durations_roundtrip(0_u64, DcaDuration::ThreeHours);
}

#[test]
fn test_dca_durations_packing_all_variants() {
    let twap: u64 = 0x8000040000000000;
    assert_dca_durations_roundtrip(twap, DcaDuration::ThreeHours);
    assert_dca_durations_roundtrip(twap, DcaDuration::SixHours);
    assert_dca_durations_roundtrip(twap, DcaDuration::TwelveHours);
    assert_dca_durations_roundtrip(twap, DcaDuration::TwentyFourHours);
    assert_dca_durations_roundtrip(twap, DcaDuration::ThreeDays);
    assert_dca_durations_roundtrip(twap, DcaDuration::OneWeek);
    assert_dca_durations_roundtrip(twap, DcaDuration::TwoWeeks);
    assert_dca_durations_roundtrip(twap, DcaDuration::OneMonth);
    assert_dca_durations_roundtrip(twap, DcaDuration::ThreeMonths);
    assert_dca_durations_roundtrip(twap, DcaDuration::SixMonths);
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
