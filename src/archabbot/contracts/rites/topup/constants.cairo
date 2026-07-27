use wadray::RAY_PERCENT;

pub const MAX_SLIPPAGE: u128 = RAY_PERCENT * 20;

// TWAP period in seconds for Ekubo oracle price used in sqrt_ratio_limit calculation.
pub const TWAP_PERIOD: u64 = 60;
