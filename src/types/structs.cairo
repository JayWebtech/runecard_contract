use starknet::ContractAddress;

#[derive(Drop, Serde, starknet::Store, Debug)]
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

#[derive(Drop, Serde)]
pub struct GlobalStats {
    pub total_cards_created: u64,
    pub total_cards_redeemed: u64,
    pub total_cards_unredeemed: u64,
    pub unique_creators: u64,
    pub total_tokens_supported: u64,
}

#[derive(Drop, Serde)]
pub struct TokenStats {
    pub token: ContractAddress,
    pub total_value_locked: u256,
    pub total_value_redeemed: u256,
    pub total_value_unredeemed: u256,
    pub total_cards: u64,
    pub fees_collected: u256,
    pub fees_withdrawn: u256,
    pub fees_available: u256, 
}

#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct WithdrawalRecord {
    pub id: u64,
    pub token: ContractAddress,
    pub amount: u256,
    pub recipient: ContractAddress,
    pub withdrawn_by: ContractAddress,
    pub timestamp: u64,
}

