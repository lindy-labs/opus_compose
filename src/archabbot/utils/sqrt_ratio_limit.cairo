use core::num::traits::Sqrt;
use wadray::{RAY_ONE, Ray};

pub fn calculate_sqrt_ratio_limit(
    sqrt_ratio: u256, slippage: Ray, is_selling_token0: bool,
) -> u256 {
    let inner: Ray = if is_selling_token0 {
        RAY_ONE.into() - slippage
    } else {
        RAY_ONE.into() + slippage
    };

    let sqrt_factor: Ray = Sqrt::sqrt(inner);

    // Scale back to Ekubo's fixed point
    sqrt_ratio * sqrt_factor.into() / RAY_ONE.into()
}
