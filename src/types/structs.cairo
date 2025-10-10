use starknet::ContractAddress;

#[derive(Drop, Serde, starknet::Store)]
pub struct Cards {
    pub id: u64,
    pub redeem_code_hash: felt252,
    pub creator: ContractAddress,
    pub token: ContractAddress,
    pub amount: u256,
    pub description: ByteArray,
    pub link: felt252,
    pub card_type: u16,
    pub is_redeemed: bool,
    pub redeemed_by: ContractAddress,
    pub redeemed_at: u64,
    pub created_at: u64,
}