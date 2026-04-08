#[starknet::component]
pub mod EkuboOracleComponent {
    use ekubo::extensions::oracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use opus_compose::constants::CASH_DECIMALS;
    use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::ContractAddress;
    use wadray::Wad;

    #[storage]
    pub struct Storage {
        pub ekubo_oracle: IOracleDispatcher,
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {}

    #[generate_trait]
    pub impl InternalImpl<
        TContractState, +HasComponent<TContractState>,
    > of InternalTrait<TContractState> {
        fn get_asset_price(
            self: @ComponentState<TContractState>,
            asset: ContractAddress,
            yin_address: ContractAddress,
            twap_duration: u64,
        ) -> Wad {
            let oracle = self.ekubo_oracle.read();
            let price_x128: u256 = oracle
                .get_price_x128_over_last(asset, yin_address, twap_duration);

            opus::utils::math::convert_ekubo_oracle_price_to_wad(
                price_x128,
                IERC20Dispatcher { contract_address: asset }.decimals(),
                CASH_DECIMALS,
            )
        }

        fn set_ekubo_oracle(ref self: ComponentState<TContractState>, oracle: ContractAddress) {
            self.ekubo_oracle.write(IOracleDispatcher { contract_address: oracle });
        }
    }
}
