use ekubo::interfaces::extensions::twamm::{OrderInfo, OrderKey};
use opus_compose::vicariate::contracts::rites::types::EkuboPoolParams;
use starknet::ContractAddress;
use starknet::storage_access::StorePacking;
use wadray::Wad;

// PriceDcaDurations packing shifts and masks (packed into u128)
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

// PriceConditions packing shifts and masks (each side packed into felt252)
// Layout per felt252: amount (lower 128 bits) | price (upper 123 bits) = 251 bits
const MASK_123_U128: u128 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

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
#[derive(Copy, Drop, Debug, PartialEq, Serde, starknet::Store)]
pub enum DcaOrderDuration {
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
    /// Returns the duration in seconds for the given DcaOrderDuration variant.
    fn to_seconds(self: DcaOrderDuration) -> u64 {
        const HOUR: u64 = 60 * 60;
        const DAY: u64 = 24 * HOUR;
        const WEEK: u64 = 7 * DAY;
        const MONTH: u64 = 30 * DAY;

        match self {
            DcaOrderDuration::ThreeHours(()) => 3 * HOUR,
            DcaOrderDuration::SixHours(()) => 6 * HOUR,
            DcaOrderDuration::TwelveHours(()) => 12 * HOUR,
            DcaOrderDuration::TwentyFourHours(()) => DAY,
            DcaOrderDuration::ThreeDays(()) => 3 * DAY,
            DcaOrderDuration::OneWeek(()) => WEEK,
            DcaOrderDuration::TwoWeeks(()) => 2 * WEEK,
            DcaOrderDuration::OneMonth(()) => MONTH,
            DcaOrderDuration::ThreeMonths(()) => 3 * MONTH,
            DcaOrderDuration::SixMonths(()) => 6 * MONTH,
        }
    }

    // Returns the Ekubo time step size for the given duration.
    // Ekubo requires end timestamps to be multiples of a step size
    // that depends on the duration from now.
    fn get_step_size(self: DcaOrderDuration) -> u64 {
        match self {
            DcaOrderDuration::ThreeHours | DcaOrderDuration::SixHours | DcaOrderDuration::TwelveHours => 4096,
            DcaOrderDuration::TwentyFourHours | DcaOrderDuration::ThreeDays | DcaOrderDuration::OneWeek => 65536,
            DcaOrderDuration::TwoWeeks | DcaOrderDuration::OneMonth | DcaOrderDuration::ThreeMonths |
            DcaOrderDuration::SixMonths => 1048576,
        }
    }

    // Calculates a valid Ekubo end timestamp for this duration.
    // Rounds (now + period) up to the next step boundary to ensure
    // the end_time is both in the future and aligned to a multiple of the step size.
    fn to_valid_end_time(self: DcaOrderDuration, now: u64) -> u64 {
        let period = self.to_seconds();
        let step = self.get_step_size();
        let target = now + period;
        target + (step - target % step) % step
    }

}

// Packs twap_duration (u64) and order_duration (DcaOrderDuration, 4 bits) into a single u128.
// Layout: [order_duration (4 bits) | twap_duration (64 bits)] = 68 bits
#[derive(Copy, Drop, Debug, PartialEq, Serde)]
pub struct PriceDcaDurations {
    pub twap_duration: u64,
    pub order_duration: DcaOrderDuration,
}

impl PriceDcaDurationsPacking of StorePacking<PriceDcaDurations, u128> {
    fn pack(value: PriceDcaDurations) -> u128 {
        value.twap_duration.into() + (value.order_duration.into_index().into() * TWO_POW_64_U128)
    }

    fn unpack(value: u128) -> PriceDcaDurations {
        let twap_duration = value & MASK_64_U128;
        let order_index = (value / TWO_POW_64_U128) & MASK_4_U128;

        PriceDcaDurations {
            twap_duration: twap_duration.try_into().unwrap(),
            order_duration: IndexedEnum::<DcaOrderDuration>::from_index(order_index.try_into().unwrap()),
        }
    }
}

// Storage representation of PriceConditions — 2 felt252s = 2 storage slots
// (down from 4 slots when fields were stored individually).
#[derive(Copy, Drop, starknet::Store)]
pub struct PackedPriceConditions {
    pub buy: felt252,
    pub sell: felt252,
}

// Groups buy/sell price and amount conditions for price-triggered DCA.
// Packs into PackedPriceConditions (2 felt252s) via StorePacking:
//   each felt252 layout: amount (lower 128 bits) | price (upper 123 bits)
#[derive(Copy, Drop, Debug, PartialEq, Serde)]
pub struct PriceConditions {
    pub buy_price: Wad,
    // Set `buy_amount` to zero to disable buy orders
    // Denominated in CASH
    pub buy_amount: Wad,
    pub sell_price: Wad,
    // Set `sell_amount` to zero to disable sell orders
    // Denominated in asset
    pub sell_amount: u128,
}

impl PriceConditionsPacking of StorePacking<PriceConditions, PackedPriceConditions> {
    fn pack(value: PriceConditions) -> PackedPriceConditions {
        let buy_price_u128: u128 = value.buy_price.into();
        let buy_price_masked: u128 = buy_price_u128 & MASK_123_U128;
        let buy_amount_u128: u128 = value.buy_amount.into();
        let buy_packed: u256 = buy_amount_u128.into()
            + (buy_price_masked.into() * TWO_POW_128_U256);

        let sell_price_u128: u128 = value.sell_price.into();
        let sell_price_masked: u128 = sell_price_u128 & MASK_123_U128;
        let sell_packed: u256 = value.sell_amount.into()
            + (sell_price_masked.into() * TWO_POW_128_U256);

        PackedPriceConditions {
            buy: buy_packed.try_into().unwrap(), sell: sell_packed.try_into().unwrap(),
        }
    }

    fn unpack(value: PackedPriceConditions) -> PriceConditions {
        let buy_u256: u256 = value.buy.into();
        let sell_u256: u256 = value.sell.into();

        let buy_amount: u128 = (buy_u256 & MASK_128_U256).try_into().unwrap();
        let buy_price: u128 = ((buy_u256 / TWO_POW_128_U256) & MASK_123_U128.into())
            .try_into()
            .unwrap();
        let sell_amount: u128 = (sell_u256 & MASK_128_U256).try_into().unwrap();
        let sell_price: u128 = ((sell_u256 / TWO_POW_128_U256) & MASK_123_U128.into())
            .try_into()
            .unwrap();

        PriceConditions {
            buy_price: buy_price.into(),
            buy_amount: buy_amount.into(),
            sell_price: sell_price.into(),
            sell_amount,
        }
    }
}

#[derive(Copy, Drop, PartialEq, Serde, starknet::Store)]
pub struct PriceDcaConfig {
    pub asset: ContractAddress,
    pub pool_params: EkuboPoolParams,
    pub price_conditions: PriceConditions,
    // Duration used to check the TWAP for asset, and duration of DCA order
    pub durations: PriceDcaDurations,
}

#[derive(Copy, Drop, PartialEq, Serde, starknet::Store)]
pub struct TimeDcaConfig {
    pub asset: ContractAddress,
    pub pool_params: EkuboPoolParams,
    pub frequency: u64,
    pub durations: TimeDcaDurations,
}

// Packs twap_duration (u64) and order_duration (DcaOrderDuration, 4 bits) into a single u128.
// Layout: [order_duration (4 bits) | twap_duration (64 bits)] = 68 bits
#[derive(Copy, Drop, Debug, PartialEq, Serde)]
pub struct TimeDcaDurations {
    pub order_frequency: u64,
    pub order_duration: DcaOrderDuration,
}

impl TimeDcaDurationsPacking of StorePacking<TimeDcaDurations, u128> {
    fn pack(value: TimeDcaDurations) -> u128 {
        value.order_frequency.into() + (value.order_duration.into_index().into() * TWO_POW_64_U128)
    }

    fn unpack(value: u128) -> TimeDcaDurations {
        let order_frequency = value & MASK_64_U128;
        let order_index = (value / TWO_POW_64_U128) & MASK_4_U128;

        TimeDcaDurations {
            order_frequency: order_frequency.try_into().unwrap(),
            order_duration: IndexedEnum::<DcaOrderDuration>::from_index(order_index.try_into().unwrap()),
        }
    }
}

// Packs DcaOrder into a u256 (2 storage slots instead of 4).
// Layout (as u256):
//   low  128 bits : fee
//   next 64 bits  : position_id
//   next 62 bits  : end_time (top 2 bits of u64 are always zero for timestamps)
//   top   2 bits  : order_type
#[derive(Copy, Drop, Debug, Default, PartialEq, Serde)]
pub struct DcaOrder {
    pub position_id: u64,
    pub fee: u128,
    pub end_time: u64,
    pub order_type: OrderType,
}

pub trait IndexedEnum<T> {
    fn into_index(self: T) -> u64;
    fn from_index(index: u64) -> T;
}

pub impl DcaDurationIndexedImpl of IndexedEnum<DcaOrderDuration> {
    fn into_index(self: DcaOrderDuration) -> u64 {
        match self {
            DcaOrderDuration::ThreeHours => 0,
            DcaOrderDuration::SixHours => 1,
            DcaOrderDuration::TwelveHours => 2,
            DcaOrderDuration::TwentyFourHours => 3,
            DcaOrderDuration::ThreeDays => 4,
            DcaOrderDuration::OneWeek => 5,
            DcaOrderDuration::TwoWeeks => 6,
            DcaOrderDuration::OneMonth => 7,
            DcaOrderDuration::ThreeMonths => 8,
            DcaOrderDuration::SixMonths => 9,
        }
    }

    fn from_index(index: u64) -> DcaOrderDuration {
        match index {
            0 => DcaOrderDuration::ThreeHours,
            1 => DcaOrderDuration::SixHours,
            2 => DcaOrderDuration::TwelveHours,
            3 => DcaOrderDuration::TwentyFourHours,
            4 => DcaOrderDuration::ThreeDays,
            5 => DcaOrderDuration::OneWeek,
            6 => DcaOrderDuration::TwoWeeks,
            7 => DcaOrderDuration::OneMonth,
            8 => DcaOrderDuration::ThreeMonths,
            9 => DcaOrderDuration::SixMonths,
            _ => panic!("Invalid DcaOrderDuration index"),
        }
    }
}

pub impl OrderTypeIndexedImpl of IndexedEnum<OrderType> {
    fn into_index(self: OrderType) -> u64 {
        match self {
            OrderType::None => 0,
            OrderType::BuyAsset => 1,
            OrderType::SellAsset => 2,
        }
    }

    fn from_index(index: u64) -> OrderType {
        match index {
            0 => OrderType::None,
            1 => OrderType::BuyAsset,
            2 => OrderType::SellAsset,
            _ => panic!("Invalid OrderType index"),
        }
    }
}

impl DcaOrderPacking of StorePacking<DcaOrder, u256> {
    fn pack(value: DcaOrder) -> u256 {
        let end_time_and_type: u256 = value.end_time.into()
            + (value.order_type.into_index().into() * TWO_POW_62_U256);
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
            order_type: IndexedEnum::<OrderType>::from_index(
                (end_time_and_type / TWO_POW_62_U256).try_into().unwrap(),
            ),
        }
    }
}

#[derive(Copy, Drop, Serde)]
pub struct ConsolidatedOrderData {
    pub order_key: Option<OrderKey>,
    pub order_status: OrderStatus,
    pub order_info: Option<OrderInfo>,
}
