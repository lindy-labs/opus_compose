use ekubo::types::keys::PoolKey;
use starknet::ContractAddress;

#[starknet::interface]
pub trait IPoolKeyManager<TContractState> {
    fn set_pool_key(ref self: TContractState, asset: ContractAddress, pool_key: PoolKey);
    fn get_pool_key(self: @TContractState, asset: ContractAddress) -> PoolKey;
    fn clear_pool_key(ref self: TContractState, asset: ContractAddress);
}

#[starknet::component]
pub mod pool_key_manager_component {
    use core::cmp::minmax;
    use core::num::traits::Zero;
    use ekubo::types::keys::PoolKey;
    use opus_compose::stabilizer::types::StoragePoolKey;
    use starknet::ContractAddress;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};

    #[storage]
    pub struct Storage {
        pool_keys: Map<ContractAddress, StoragePoolKey>,
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        PoolKeySet: PoolKeySet,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct PoolKeySet {
        #[key]
        pub asset: ContractAddress,
        pub pool_key: PoolKey,
    }

    #[generate_trait]
    pub impl PoolKeyManagerHelpers<
        TContractState, +HasComponent<TContractState>,
    > of PoolKeyManagerHelpersTrait<TContractState> {
        fn set_pool_key_helper(
            ref self: ComponentState<TContractState>,
            cash: ContractAddress,
            asset: ContractAddress,
            pool_key: PoolKey,
        ) {
            assert!(
                minmax(pool_key.token0, pool_key.token1) == minmax(asset, cash),
                "Invalid pool key assets",
            );
            self.pool_keys.write(asset, pool_key.into());
            self.emit(PoolKeySet { asset, pool_key });
        }

        fn get_pool_key_helper(
            self: @ComponentState<TContractState>, asset: ContractAddress,
        ) -> PoolKey {
            self.pool_keys.read(asset).into()
        }

        fn clear_pool_key_helper(ref self: ComponentState<TContractState>, asset: ContractAddress) {
            let zero_key = StoragePoolKey {
                token0: Zero::zero(),
                token1: Zero::zero(),
                fee: 0,
                tick_spacing: 0,
                extension: Zero::zero(),
            };
            self.pool_keys.write(asset, zero_key);
            self.emit(PoolKeySet { asset, pool_key: zero_key.into() });
        }
    }
}
