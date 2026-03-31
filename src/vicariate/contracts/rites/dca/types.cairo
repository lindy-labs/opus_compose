use ekubo::interfaces::extensions::twamm::{OrderInfo, OrderKey};
use opus_compose::vicariate::contracts::rites::types::EkuboPoolParams;
use starknet::ContractAddress;
use wadray::Wad;

#[derive(Copy, Drop, Default, PartialEq, Serde, starknet::Store)]
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
#[derive(Copy, Drop, PartialEq, Serde, starknet::Store)]
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
    // Duration used to check the TWAP for asset
    pub twap_duration: u64,
    // Duration of DCA order
    pub order_duration: DcaDuration,
}

#[derive(Copy, Drop, Default, PartialEq, Serde, starknet::Store)]
pub struct DcaOrder {
    pub position_id: u64,
    pub fee: u128,
    pub end_time: u64,
    pub order_type: OrderType,
}


#[derive(Copy, Drop, Serde)]
pub struct ConsolidatedOrderData {
    pub order_key: Option<OrderKey>,
    pub order_status: OrderStatus,
    pub order_info: Option<OrderInfo>,
}
