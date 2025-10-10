use starknet::ContractAddress;
use starknet::class_hash::ClassHash;
use crate::types::structs::{Cards};

#[starknet::interface]
pub trait IRunesCard<TContractState> {
    fn create_card(ref self: TContractState, token: ContractAddress, amount: u256, redeem_code_hash: felt252, description: ByteArray, link: felt252, card_type: u16);
    fn redeem_card(ref self: TContractState, redeem_code: felt252, id: u64);
    fn get_card_balance(self: @TContractState, id: u64) -> u256;
    fn get_card_by_id(self: @TContractState, id: u64) -> Cards;
    fn get_users_cards(self: @TContractState) -> Array<Cards>;
    fn get_users_cards_paginated(self: @TContractState, page: u64, page_size: u64) -> (Array<Cards>, u64);
    fn get_user_card_count(self: @TContractState, user: ContractAddress) -> u64;
    fn get_users_redeemed_cards_paginated(self: @TContractState, page: u64, page_size: u64) -> (Array<Cards>, u64);
    fn get_user_redeemed_card_count(self: @TContractState, user: ContractAddress) -> u64;
    fn get_owner(self: @TContractState) -> ContractAddress;
    fn change_owner(ref self: TContractState, new_owner: ContractAddress);
    fn upgrade(ref self: TContractState, impl_hash: ClassHash, new_version: u8);
    fn get_version(self: @TContractState) -> u8;
    fn pause(ref self: TContractState);
    fn unpause(ref self: TContractState);
    fn get_contract_status(self: @TContractState) -> bool;
    fn get_protocol_fee(self: @TContractState) -> u256;
    fn set_protocol_fee(ref self: TContractState, new_fee: u256);
    fn withdraw_fees(ref self: TContractState, token: ContractAddress, amount: u256, recipient: ContractAddress);
    fn get_contract_token_balance(self: @TContractState, token: ContractAddress) -> u256;
}   

