use ekubo::types::bounds::Bounds;
use ekubo::types::i129::i129;
use ekubo::types::keys::PoolKey;
use starknet::ContractAddress;

// A wrapper of Ekubo's PoolKey struct to enable storage
#[derive(Copy, Drop, Serde, PartialEq, Hash, starknet::Store)]
pub struct StoragePoolKey {
    pub token0: ContractAddress,
    pub token1: ContractAddress,
    pub fee: u128,
    pub tick_spacing: u128,
    pub extension: ContractAddress,
}

pub impl StoragePoolKeyIntoPoolKey of Into<StoragePoolKey, PoolKey> {
    fn into(self: StoragePoolKey) -> PoolKey {
        PoolKey {
            token0: self.token0,
            token1: self.token1,
            fee: self.fee,
            tick_spacing: self.tick_spacing,
            extension: self.extension,
        }
    }
}

pub impl PoolKeyIntoStoragePoolKey of Into<PoolKey, StoragePoolKey> {
    fn into(self: PoolKey) -> StoragePoolKey {
        StoragePoolKey {
            token0: self.token0,
            token1: self.token1,
            fee: self.fee,
            tick_spacing: self.tick_spacing,
            extension: self.extension,
        }
    }
}

// A wrapper of Ekubo's Bounds struct to enable storage
#[derive(Copy, Drop, Serde, PartialEq, Hash, starknet::Store)]
pub struct StorageBounds {
    pub lower: i129,
    pub upper: i129,
}

pub impl StorageBoundsIntoBounds of Into<StorageBounds, Bounds> {
    fn into(self: StorageBounds) -> Bounds {
        Bounds { lower: self.lower, upper: self.upper }
    }
}

pub impl BoundsIntoStorageBounds of Into<Bounds, StorageBounds> {
    fn into(self: Bounds) -> StorageBounds {
        StorageBounds { lower: self.lower, upper: self.upper }
    }
}


#[derive(Copy, Drop, Serde, Debug, PartialEq, starknet::Store)]
pub struct Stake {
    // A 128-bit value from Ekubo representing amount of liquidity
    // provided by a position. This value should remain unchanged
    // while a position NFT is staked.
    pub liquidity: u128,
    // Snapshot of the accumulator value for yield at the time the
    // user last took an action
    pub yin_per_liquidity_snapshot: u256,
}

#[derive(Copy, Drop, Serde, Debug, PartialEq, starknet::Store)]
pub struct YieldState {
    // Yin balance of this contract at the time that
    // this contract was last called
    pub yin_balance_snapshot: u256,
    // Accumulator value for amount of yield (yin) per unit of liquidity
    // This value is obtained by scaling yin (wad precision) up by 2 ** 128
    // before dividing by total liquidity. Since total liquidity could be a
    // small `u128` value, 256 bits are used to prevent overflows.
    pub yin_per_liquidity: u256,
}
