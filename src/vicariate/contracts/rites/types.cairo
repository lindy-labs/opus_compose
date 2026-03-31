use core::cmp::minmax;
use ekubo::types::keys::PoolKey;
use starknet::ContractAddress;
use starknet::storage_access::StorePacking;

const TWO_POW_128: felt252 = 0x100000000000000000000000000000000;

// Ekubo pool parameters for constructing a PoolKey.
// token0 and token1 are derived from (asset, cash) via minmax at call time.
#[derive(Copy, Drop, PartialEq, Serde, starknet::Store)]
pub struct EkuboPoolParams {
    pub fee: u128,
    pub tick_spacing: u128,
    pub extension: ContractAddress,
}

#[derive(Copy, Drop, PartialEq, Serde)]
pub struct PackedEkuboPoolParams {
    // Max tick spacing is 354892, which is guaranteed to fit 
    // into the upper 123 bits
    pub fee_and_tick_spacing: felt252,
    pub extension: ContractAddress,
}

#[generate_trait]
pub impl EkuboPoolParamsImpl of EkuboPoolParamsTrait {
    fn into_pool_key(self: EkuboPoolParams, asset: ContractAddress, cash: ContractAddress) -> PoolKey {
        let (token0, token1) = minmax(asset, cash);
        PoolKey {
            token0,
            token1,
            fee: self.fee,
            tick_spacing: self.tick_spacing,
            extension: self.extension,
        }
    }
}

impl EkuboPoolParamsPacking of StorePacking<EkuboPoolParams, PackedEkuboPoolParams> {
    fn pack(value: EkuboPoolParams) -> PackedEkuboPoolParams {
        PackedEkuboPoolParams { fee_and_tick_spacing: value.fee.into() + (value.tick_spacing.into() * TWO_POW_128), extension: value.extension }
    }

    fn unpack(value: PackedEkuboPoolParams) -> EkuboPoolParams {
        let shift: u256 = TWO_POW_128.into();
        let shift: NonZero<u256> = shift.try_into().unwrap();
        let (fee, tick_spacing) = DivRem::div_rem(value.fee_and_tick_spacing.into(), shift);

        EkuboPoolParams {
            fee: fee.try_into().unwrap(),
            tick_spacing: tick_spacing.try_into().unwrap(),
            extension: value.extension       
        }
    }
}

