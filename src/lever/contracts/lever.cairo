#[starknet::contract]
pub mod lever {
    use core::num::traits::Zero;
    use ekubo::components::clear::{IClearDispatcher, IClearDispatcherTrait};
    use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use ekubo::router_lite::{IRouterLiteDispatcher, IRouterLiteDispatcherTrait};
    use opus::interfaces::{
        IAbbotDispatcher, IAbbotDispatcherTrait, IFlashBorrower, IFlashMintDispatcher,
        IFlashMintDispatcherTrait, ISentinelDispatcher, ISentinelDispatcherTrait, IShrineDispatcher,
        IShrineDispatcherTrait,
    };
    use opus::types::Health;
    use opus_compose::lever::interfaces::lever::ILever;
    use opus_compose::lever::types::{
        LeverDownParams, LeverUpParams, ModifyLeverAction, ModifyLeverParams,
    };
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use wadray::{Ray, Wad};

    //
    // Constants
    //

    // The value of keccak256("ERC3156FlashBorrower.onFlashLoan") as per EIP3156
    // it is supposed to be returned from the onFlashLoan function by the receiver
    const ON_FLASH_MINT_SUCCESS: u256 =
        0x439148f0bbc682ca079e46d6e2c2f0c1e3b820f1a291b069d8882abf8cf18dd9_u256;

    //
    // Storage
    //

    #[storage]
    struct Storage {
        shrine: IShrineDispatcher,
        sentinel: ISentinelDispatcher,
        abbot: IAbbotDispatcher,
        flash_mint: IFlashMintDispatcher,
        ekubo_router: IRouterLiteDispatcher,
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
        sentinel: ContractAddress,
        abbot: ContractAddress,
        flash_mint: ContractAddress,
        ekubo_router: ContractAddress,
    ) {
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.sentinel.write(ISentinelDispatcher { contract_address: sentinel });
        self.abbot.write(IAbbotDispatcher { contract_address: abbot });
        self.flash_mint.write(IFlashMintDispatcher { contract_address: flash_mint });
        self.ekubo_router.write(IRouterLiteDispatcher { contract_address: ekubo_router });
    }

    //
    // External Lever functions
    //

    #[abi(embed_v0)]
    impl ILeverImpl of ILever<ContractState> {
        // Take on leverage to acquire a specific collateral for a Trove
        // 1. Flash mint yin to this contract
        // 2. Purchase collateral asset with flash-minted yin via Ekubo
        // 3. Deposit purchased collateral asset to caller's trove
        // 4. Borrow yin from caller's trove and mint to this contract
        fn up(ref self: ContractState, amount: Wad, lever_up_params: LeverUpParams) {
            let user: ContractAddress = get_caller_address();
            assert!(
                user == self
                    .abbot
                    .read()
                    .get_trove_owner(lever_up_params.trove_id)
                    .expect('Non-existent trove'),
                "LEV: Not trove owner",
            );

            let mut call_data: Array<felt252> = array![];
            let modify_lever_params = ModifyLeverParams {
                user, action: ModifyLeverAction::LeverUp(lever_up_params),
            };
            modify_lever_params.serialize(ref call_data);

            self
                .flash_mint
                .read()
                .flash_loan(
                    get_contract_address(), // receiver
                    self.shrine.read().contract_address, // token
                    amount.into(),
                    call_data.span(),
                );
        }

        // Unwind a position for a specific collateral for a Trove
        // 1. Flash mint yin to this contract
        // 2. Repay yin for trove
        // 3. Withdraw collateral asset from trove
        // 4. Purchase yin with withdrawn collateral asset via Ekubo
        // 5. Transfer remainder collateral asset to user
        fn down(ref self: ContractState, amount: Wad, lever_down_params: LeverDownParams) {
            let user: ContractAddress = get_caller_address();
            assert!(
                user == self
                    .abbot
                    .read()
                    .get_trove_owner(lever_down_params.trove_id)
                    .expect('Non-existent trove'),
                "LEV: Not trove owner",
            );
            let modify_lever_params = ModifyLeverParams {
                user, action: ModifyLeverAction::LeverDown(lever_down_params),
            };
            let mut call_data: Array<felt252> = array![];
            modify_lever_params.serialize(ref call_data);

            self
                .flash_mint
                .read()
                .flash_loan(
                    get_contract_address(), // receiver
                    self.shrine.read().contract_address, // token
                    amount.into(),
                    call_data.span(),
                );
        }
    }

    #[abi(embed_v0)]
    impl IFlashBorrowerImpl of IFlashBorrower<ContractState> {
        // This contract needs to call `shrine.forge` and `shrine.deposit` directly to get around
        // the checks in Abbot that the caller of Abbot is the trove owner.
        fn on_flash_loan(
            ref self: ContractState,
            initiator: ContractAddress, // this contract
            token: ContractAddress, // yin
            amount: u256,
            fee: u256,
            mut call_data: Span<felt252>,
        ) -> u256 {
            let ModifyLeverParams {
                user, action,
            } = Serde::<ModifyLeverParams>::deserialize(ref call_data).unwrap();

            let shrine = self.shrine.read();
            let yin = IERC20Dispatcher { contract_address: token };
            let sentinel = self.sentinel.read();
            let router = self.ekubo_router.read();
            let router_clear = IClearDispatcher { contract_address: router.contract_address };

            match action {
                ModifyLeverAction::LeverUp(params) => {
                    let LeverUpParams {
                        trove_id, max_ltv, yang, max_forge_fee_pct, swaps,
                    } = params;
                    let yang_erc20 = IERC20Dispatcher { contract_address: yang };

                    // Catch invalid yangs properly
                    let gate = get_valid_gate(sentinel, yang);

                    // Transfer yin to EKubo's router and swap for collateral
                    yin.transfer(router.contract_address, amount);
                    router.multi_multihop_swap(swaps);

                    // Withdraw the collateral asset from Ekubo's router to this contract.
                    let asset_amt: u256 = router_clear.clear_minimum(yang_erc20, 1);

                    // Deposit purchased collateral to trove
                    yang_erc20.approve(gate, asset_amt);
                    let asset_amt: u128 = asset_amt.try_into().unwrap();
                    let yang_amt: Wad = sentinel.enter(yang, initiator, asset_amt);
                    shrine.deposit(yang, trove_id, yang_amt);

                    // Borrow yin from trove and send to this contract to repay the flash mint
                    shrine
                        .forge(initiator, trove_id, amount.try_into().unwrap(), max_forge_fee_pct);

                    self.assert_below_max_ltv(trove_id, max_ltv);

                    self.emit(LeverDeposit { user, trove_id, yang, yang_amt, asset_amt });
                },
                ModifyLeverAction::LeverDown(params) => {
                    let LeverDownParams { trove_id, max_ltv, yang, yang_amt, swaps } = params;
                    let yang_erc20 = IERC20Dispatcher { contract_address: yang };

                    // Catch invalid yangs properly
                    get_valid_gate(sentinel, yang);

                    // Use the flash minted yin to repay the trove's debt
                    self.abbot.read().melt(trove_id, amount.try_into().unwrap());

                    // Withdraw collateral to this contract
                    let asset_amt: u128 = sentinel.exit(yang, initiator, yang_amt);
                    shrine.withdraw(yang, trove_id, yang_amt);

                    // Transfer collateral to Ekubo's router and swap for yin
                    yang_erc20.transfer(router.contract_address, asset_amt.into());
                    router.multi_multihop_swap(swaps);

                    // Sanity check to ensure the amount of yin flash minted has been purchased
                    // and can be withdrawn
                    router_clear.clear_minimum(yin, amount);
                    let yin_amount = yin.balanceOf(initiator);

                    // Transfer any excess yin back to the user.
                    if yin_amount > amount {
                        yin.transfer(user, yin_amount - amount);
                    }
                    // Transfer any remainder collateral to the user
                    router_clear.clear_minimum_to_recipient(yang_erc20, 1, user);

                    self.assert_below_max_ltv(trove_id, max_ltv);

                    self.emit(LeverWithdraw { user, trove_id, yang, yang_amt, asset_amt });
                },
            };

            ON_FLASH_MINT_SUCCESS
        }
    }

    #[generate_trait]
    impl LeverHelpers of LeverHelpersTrait {
        fn assert_below_max_ltv(self: @ContractState, trove_id: u64, max_ltv: Ray) {
            let trove_health: Health = self.shrine.read().get_trove_health(trove_id);
            assert!(trove_health.ltv <= max_ltv, "LEV: Exceeds max LTV");
        }
    }

    // Helper function to fetch the gate address for a yang, or otherwise throw.
    fn get_valid_gate(sentinel: ISentinelDispatcher, yang: ContractAddress) -> ContractAddress {
        let gate = sentinel.get_gate_address(yang);
        assert!(gate.is_non_zero(), "LEV: Invalid yang");
        gate
    }
}
