use core::num::traits::Zero;
use ekubo::types::bounds::Bounds;
use ekubo::types::i129::i129;
use ekubo::types::keys::PoolKey;
use opus_compose::addresses::mainnet;

pub const POOL_FEE: u128 = 34028236692093847977029636859101184; // 0.01%
pub const POOL_TICK_SPACING: u128 = 200; // 0.02%

pub const LOWER_TICK_MAG: u128 = 27641600; // 0.989491
pub const UPPER_TICK_MAG: u128 = 27626000; // 1.00505

pub fn POOL_KEY() -> PoolKey {
    PoolKey {
        token0: mainnet::shrine(),
        token1: mainnet::usdc(),
        fee: POOL_FEE,
        tick_spacing: POOL_TICK_SPACING,
        extension: Zero::zero(),
    }
}

pub fn BOUNDS() -> Bounds {
    Bounds {
        lower: i129 { mag: LOWER_TICK_MAG, sign: true },
        upper: i129 { mag: UPPER_TICK_MAG, sign: true },
    }
}
