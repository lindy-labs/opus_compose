use ekubo::types::i129::i129;
use wadray::WAD_DECIMALS;

pub const CASH_DECIMALS: u8 = WAD_DECIMALS;

pub const EKUBO_TWAMM_TICK_SPACING: u128 = 354892;
pub const EKUBO_TWAMM_LOWER_BOUND: i129 = i129 { mag: 88368108, sign: true };
pub const EKUBO_TWAMM_UPPER_BOUND: i129 = i129 { mag: 88368108, sign: false };
