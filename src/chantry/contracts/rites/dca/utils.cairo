pub mod dca_utils {
    use core::num::traits::Zero;
    use ekubo::interfaces::extensions::twamm::OrderKey;
    use opus_compose::chantry::contracts::rites::dca::types::{DcaOrder, OrderType};
    use starknet::ContractAddress;

    pub fn get_order_key_from_order(
        order: DcaOrder, yin: ContractAddress, asset: ContractAddress,
    ) -> OrderKey {
        let DcaOrder { fee, end_time, order_type, .. } = order;
        let mut sell_token: ContractAddress = Zero::zero();
        let mut buy_token: ContractAddress = Zero::zero();
        match order_type {
            OrderType::BuyAsset => {
                sell_token = yin;
                buy_token = asset;
            },
            OrderType::SellAsset => {
                sell_token = asset;
                buy_token = yin;
            },
            OrderType::None => { panic!("Invalid order type"); },
        }

        OrderKey { sell_token, buy_token, fee, start_time: 0, end_time }
    }
}
