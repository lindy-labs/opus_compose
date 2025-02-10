use opus_compose::lever::types::{LeverUpParams, LeverDownParams};
use wadray::Wad;

#[starknet::interface]
pub trait IMaliciousLever<TContractState> {
    // external
    fn up(ref self: TContractState, amount: Wad, lever_up_params: LeverUpParams);
    fn down(ref self: TContractState, amount: Wad, lever_down_params: LeverDownParams);
}


#[starknet::contract]
pub mod malicious_lever {
    use opus::interfaces::{IFlashMintDispatcher, IFlashMintDispatcherTrait};
    use opus_compose::lever::types::{
        LeverDownParams, LeverUpParams, ModifyLeverAction, ModifyLeverParams,
    };
    use starknet::{ContractAddress, get_caller_address};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use super::IMaliciousLever;
    use wadray::Wad;

    //
    // Storage
    //

    #[storage]
    struct Storage {
        shrine: ContractAddress,
        flash_mint: IFlashMintDispatcher,
        lever: ContractAddress,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event)]
    pub enum Event {
        LeverDeposit: LeverDeposit,
        LeverWithdraw: LeverWithdraw,
    }

    // This mirrors `Deposit` event in Abbot
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct LeverDeposit {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub trove_id: u64,
        #[key]
        pub yang: ContractAddress,
        pub yang_amt: Wad,
        pub asset_amt: u128,
    }

    // This mirrors `Withdraw` event in Abbot
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct LeverWithdraw {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub trove_id: u64,
        #[key]
        pub yang: ContractAddress,
        pub yang_amt: Wad,
        pub asset_amt: u128,
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        ref self: ContractState,
        shrine: ContractAddress,
        flash_mint: ContractAddress,
        lever: ContractAddress,
    ) {
        self.shrine.write(shrine);
        self.flash_mint.write(IFlashMintDispatcher { contract_address: flash_mint });
        self.lever.write(lever);
    }

    //
    // External Lever functions
    //

    #[abi(embed_v0)]
    impl IMaliciousLeverImpl of IMaliciousLever<ContractState> {
        // Does not perform trove owner check
        fn up(ref self: ContractState, amount: Wad, lever_up_params: LeverUpParams) {
            let user: ContractAddress = get_caller_address();
            let mut call_data: Array<felt252> = array![];
            let modify_lever_params = ModifyLeverParams {
                user, action: ModifyLeverAction::LeverUp(lever_up_params),
            };
            modify_lever_params.serialize(ref call_data);

            self
                .flash_mint
                .read()
                .flash_loan(
                    self.lever.read(), // receiver
                    self.shrine.read(), // token
                    amount.into(),
                    call_data.span(),
                );
        }

        // Does not perform trove owner check
        fn down(ref self: ContractState, amount: Wad, lever_down_params: LeverDownParams) {
            let user: ContractAddress = get_caller_address();
            let modify_lever_params = ModifyLeverParams {
                user, action: ModifyLeverAction::LeverDown(lever_down_params),
            };
            let mut call_data: Array<felt252> = array![];
            modify_lever_params.serialize(ref call_data);

            self
                .flash_mint
                .read()
                .flash_loan(
                    self.lever.read(), // receiver
                    self.shrine.read(), // token
                    amount.into(),
                    call_data.span(),
                );
        }
    }
}
