use core::integer::{u512, u512_safe_div_rem_by_u256};
use core::num::traits::WideMul;

const X128_PRECISION_MUL: u256 = 0x100000000000000000000000000000000; // 2^128

// Calculate the yin per liquidity delta by taking `yin` of wad precision
// and scaling it by 2 ** 128, before dividing it by `liquidity` (a 128-bit value).
pub fn get_cumulative_delta(yin: u256, total_liquidity: u128) -> u256 {
    // It is safe to assume that `yin` will fit within a `u128`, so scaling
    // it by 2 ** 128 would not overflow a `u256`.
    let product: u256 = yin * X128_PRECISION_MUL;
    let total_liquidity: u256 = total_liquidity.into();
    let (res, _) = DivRem::div_rem(product, total_liquidity.try_into().unwrap());
    res
}

// Calculate the amount of accrued yin by multiplying `liquidity` (a 128-bit value)
// with the accumulator (yin per liquidity) value before scaling it down by 2 ** 128
pub fn get_accumulated_yin(liquidity: u128, yin_per_liquidity: u256) -> u256 {
    let liquidity: u256 = liquidity.into();
    // `yin_per_liquidity` is not guaranteed to fit within a `u128`, and liquidity is a
    // 128-bit value so wide multiplication is used to guarantee that no overflow occurs.
    let product: u512 = WideMul::wide_mul(liquidity, yin_per_liquidity);
    let (res, _) = u512_safe_div_rem_by_u256(product, X128_PRECISION_MUL.try_into().unwrap());
    res.try_into().unwrap()
}
