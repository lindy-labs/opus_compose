use ekubo::interfaces::extensions::twamm::{OrderInfo, OrderKey};
use opus_compose::vicariate::contracts::rites::types::EkuboPoolParams;
use starknet::ContractAddress;
use starknet::storage_access::StorePacking;
use wadray::Wad;

// DcaDurations packing shifts and masks (packed into u128)
const TWO_POW_64_U128: u128 = 0x10000000000000000;
const MASK_64_U128: u128 = 0xFFFFFFFFFFFFFFFF;
const MASK_4_U128: u128 = 0xF;

// DcaOrder packing shifts and masks (packed into u256)
const MASK_128_U256: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
const TWO_POW_128_U256: u256 = 0x100000000000000000000000000000000;
const MASK_64_U256: u256 = 0xFFFFFFFFFFFFFFFF;
const TWO_POW_192_U256: u256 = 0x1000000000000000000000000000000000000000000000000;
const MASK_62_U256: u256 = 0x3FFFFFFFFFFFFFFF;
const TWO_POW_62_U256: u256 = 0x4000000000000000;

#[derive(Copy, Drop, Debug, Default, PartialEq, Serde, starknet::Store)]
pub enum OrderType {
    BuyAsset,
    SellAsset,
    #[default]
    None,
}

#[derive(Copy, Drop, Default, PartialEq, Serde, starknet::Store)]
pub enum OrderStatus {
    #[default]
    None,
    CompletedAndWithdrawn,
    CompletedNotWithdrawn,
    Ongoing,
}

// Predefined DCA duration options with Ekubo-compatible end times.
// Each variant maps to a specific duration in seconds and step size
// for valid timestamp calculation.
#[derive(Copy, Drop, Debug, PartialEq, Serde)]
pub enum DcaDuration {
    ThreeHours,
    SixHours,
    TwelveHours,
    TwentyFourHours,
    #[default]
    ThreeDays,
    OneWeek,
    TwoWeeks,
    OneMonth,
    ThreeMonths,
    SixMonths,
}

#[generate_trait]
pub impl DcaDurationImpl of DcaDurationTrait {
    /// Returns the duration in seconds for the given DcaDuration variant.
    fn to_seconds(self: DcaDuration) -> u64 {
        const HOUR: u64 = 60 * 60;
        const DAY: u64 = 24 * HOUR;
        const WEEK: u64 = 7 * DAY;
        const MONTH: u64 = 30 * DAY;

        match self {
            DcaDuration::ThreeHours(()) => 3 * HOUR,
            DcaDuration::SixHours(()) => 6 * HOUR,
            DcaDuration::TwelveHours(()) => 12 * HOUR,
            DcaDuration::TwentyFourHours(()) => DAY,
            DcaDuration::ThreeDays(()) => 3 * DAY,
            DcaDuration::OneWeek(()) => WEEK,
            DcaDuration::TwoWeeks(()) => 2 * WEEK,
            DcaDuration::OneMonth(()) => MONTH,
            DcaDuration::ThreeMonths(()) => 3 * MONTH,
            DcaDuration::SixMonths(()) => 6 * MONTH,
        }
    }

    // Returns the Ekubo time step size for the given duration.
    // Ekubo requires end timestamps to be multiples of a step size
    // that depends on the duration from now.
    fn get_step_size(self: DcaDuration) -> u64 {
        match self {
            DcaDuration::ThreeHours | DcaDuration::SixHours | DcaDuration::TwelveHours => 4096,
            DcaDuration::TwentyFourHours | DcaDuration::ThreeDays | DcaDuration::OneWeek => 65536,
            DcaDuration::TwoWeeks | DcaDuration::OneMonth | DcaDuration::ThreeMonths |
            DcaDuration::SixMonths => 1048576,
        }
    }

    // Calculates a valid Ekubo end timestamp for this duration.
    // Formula: end_time = ts + period - ts % step
    // This rounds the start time down to a step boundary, then adds the period.
    fn to_valid_end_time(self: DcaDuration, now: u64) -> u64 {
        let period = self.to_seconds();
        let step = self.get_step_size();
        now + period - now % step
    }

    /// Returns the variant index (0-9) for storage packing.
    fn into_index(self: DcaDuration) -> u8 {
        match self {
            DcaDuration::ThreeHours => 0,
            DcaDuration::SixHours => 1,
            DcaDuration::TwelveHours => 2,
            DcaDuration::TwentyFourHours => 3,
            DcaDuration::ThreeDays => 4,
            DcaDuration::OneWeek => 5,
            DcaDuration::TwoWeeks => 6,
            DcaDuration::OneMonth => 7,
            DcaDuration::ThreeMonths => 8,
            DcaDuration::SixMonths => 9,
        }
    }

    /// Reconstructs a DcaDuration from its variant index (0-9).
    fn from_index(index: u8) -> DcaDuration {
        match index {
            0 => DcaDuration::ThreeHours,
            1 => DcaDuration::SixHours,
            2 => DcaDuration::TwelveHours,
            3 => DcaDuration::TwentyFourHours,
            4 => DcaDuration::ThreeDays,
            5 => DcaDuration::OneWeek,
            6 => DcaDuration::TwoWeeks,
            7 => DcaDuration::OneMonth,
            8 => DcaDuration::ThreeMonths,
            9 => DcaDuration::SixMonths,
            _ => panic!("Invalid DcaDuration index"),
        }
    }
}

/// Packs twap_duration (u64) and order_duration (DcaDuration, 4 bits) into a single u128.
/// Layout: [order_duration (4 bits) | twap_duration (64 bits)] = 68 bits
#[derive(Copy, Drop, Debug, PartialEq, Serde)]
pub struct DcaDurations {
    pub twap_duration: u64,
    pub order_duration: DcaDuration,
}

impl DcaDurationsPacking of StorePacking<DcaDurations, u128> {
    fn pack(value: DcaDurations) -> u128 {
        value.twap_duration.into()
            + (value.order_duration.into_index().into() * TWO_POW_64_U128)
    }

    fn unpack(value: u128) -> DcaDurations {
        let twap_duration = value & MASK_64_U128;
        let order_index = (value / TWO_POW_64_U128) & MASK_4_U128;

        DcaDurations {
            twap_duration: twap_duration.try_into().unwrap(),
            order_duration: DcaDurationTrait::from_index(order_index.try_into().unwrap()),
        }
    }
}

#[derive(Copy, Drop, PartialEq, Serde, starknet::Store)]
pub struct PriceDcaConfig {
    pub asset: ContractAddress,
    pub pool_params: EkuboPoolParams,
    pub buy_price: Wad,
    // Set `buy_amount` to zero to disable buy orders
    // Denominated in CASH
    pub buy_amount: Wad,
    pub sell_price: Wad,
    // Set `sell_amount` to zero to disable sell orders
    // Denominated in asset
    pub sell_amount: u128,
    // Duration used to check the TWAP for asset, and duration of DCA order
    pub durations: DcaDurations,
}

/// Packs DcaOrder into a u256 (2 storage slots instead of 4).
/// Layout (as u256):
///   low  128 bits : fee
///   next 64 bits  : position_id
///   next 62 bits  : end_time (top 2 bits of u64 are always zero for timestamps)
///   top   2 bits  : order_type
#[derive(Copy, Drop, Debug, Default, PartialEq, Serde)]
pub struct DcaOrder {
    pub position_id: u64,
    pub fee: u128,
    pub end_time: u64,
    pub order_type: OrderType,
}

fn order_type_into_index(order_type: OrderType) -> u64 {
    match order_type {
        OrderType::None => 0,
        OrderType::BuyAsset => 1,
        OrderType::SellAsset => 2,
    }
}

fn order_type_from_index(index: u64) -> OrderType {
    match index {
        0 => OrderType::None,
        1 => OrderType::BuyAsset,
        2 => OrderType::SellAsset,
        _ => panic!("Invalid OrderType index"),
    }
}

impl DcaOrderPacking of StorePacking<DcaOrder, u256> {
    fn pack(value: DcaOrder) -> u256 {
        let end_time_and_type: u256 = value.end_time.into()
            + (order_type_into_index(value.order_type).into() * TWO_POW_62_U256);
        value.fee.into()
            + (value.position_id.into() * TWO_POW_128_U256)
            + (end_time_and_type * TWO_POW_192_U256)
    }

    fn unpack(value: u256) -> DcaOrder {
        let end_time_and_type = value / TWO_POW_192_U256;
        DcaOrder {
            fee: (value & MASK_128_U256).try_into().unwrap(),
            position_id: ((value / TWO_POW_128_U256) & MASK_64_U256).try_into().unwrap(),
            end_time: (end_time_and_type & MASK_62_U256).try_into().unwrap(),
            order_type: order_type_from_index((end_time_and_type / TWO_POW_62_U256).try_into().unwrap()),
        }
    }
}

#[derive(Copy, Drop, Serde)]
pub struct ConsolidatedOrderData {
    pub order_key: Option<OrderKey>,
    pub order_status: OrderStatus,
    pub order_info: Option<OrderInfo>,
}
