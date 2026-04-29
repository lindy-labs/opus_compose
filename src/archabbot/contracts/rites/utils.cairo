pub mod rites_utils {
    use starknet::ContractAddress;

    pub fn assert_caller_is_archabbot(
        caller: ContractAddress, archabbot: ContractAddress, rite_id: ByteArray,
    ) {
        assert!(caller == archabbot, "{}: Caller is not Archabbot", rite_id);
    }
}
