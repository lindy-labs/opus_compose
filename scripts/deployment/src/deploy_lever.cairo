use opus_compose::addresses::mainnet;
use sncast_std::{
    DeclareResultTrait, DisplayContractAddress, EthFeeSettings, FeeSettings, declare, deploy,
};

fn main() {
    let declare_lever = declare(
        "lever", FeeSettings::Eth(EthFeeSettings { max_fee: Option::None }), Option::None,
    )
        .expect('failed lever declare');

    let lever_calldata: Array<felt252> = array![
        mainnet::SHRINE.into(),
        mainnet::SENTINEL.into(),
        mainnet::ABBOT.into(),
        mainnet::FLASH_MINT.into(),
        mainnet::EKUBO_ROUTER.into(),
    ];
    let deploy_lever = deploy(
        *declare_lever.class_hash(),
        lever_calldata,
        Option::None,
        true,
        FeeSettings::Eth(EthFeeSettings { max_fee: Option::None }),
        Option::None,
    )
        .expect('failed lever deploy');

    let lever_addr = deploy_lever.contract_address;

    // Print summary table of deployed contracts
    println!("-------------------------------------------------\n");
    println!("Deployed addresses");
    println!("Lever: {}", lever_addr);
}
