#[starknet::contract]
pub mod RunesCardV1 {
    use core::num::traits::Zero;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::class_hash::ClassHash;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};
    use crate::interface::IRunesCard::IRunesCard;
    use crate::types::errors::{
        AMOUNT_MUST_BE_GREATER_THAN_ZERO, CLASS_HASH_CANNOT_BE_ZERO, CONTRACT_IS_ACTIVE_ALREADY,
        CONTRACT_IS_PAUSED, CONTRACT_IS_PAUSED_ALREADY, INSUFFICIENT_ALLOWANCE,
        INVALID_TOKEN_ADDRESS, UNAUTHORIZED_CALLER, ZERO_ADDRESS_NOT_ALLOWED, OWNER_CANNOT_BE_ZERO, INVALID_REDEEM_CODE, TOKEN_TRANSFER_FAILED, INVALID_CARD_ID, CARD_ALREADY_REDEEMED, PAGE_SIZE_MUST_BE_GREATER_THAN_ZERO, PAGE_SIZE_TOO_LARGE, INVALID_RECIPIENT_ADDRESS, INSUFFICIENT_BALANCE
    };
    use crate::types::structs::{Cards};
    use core::hash::{HashStateTrait};
    use core::poseidon::PoseidonTrait;


    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        CardCreated: CardCreated,
        CardRedeemed: CardRedeemed,
        OwnerChanged: OwnerChanged,
        Upgraded: Upgraded,
        Paused: Paused,
        Unpaused: Unpaused,
        ProtocolFeeChanged: ProtocolFeeChanged,
        FeesWithdrawn: FeesWithdrawn,  
    }
    

    #[derive(Drop, starknet::Event)]
    pub struct CardCreated {
        pub id: u64,
        pub creator: ContractAddress,
        pub token: ContractAddress,
        pub amount: u256,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct CardRedeemed {
        pub id: u64,
        pub redeemer: ContractAddress,
        pub amount: u256,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct OwnerChanged {
        pub old_owner: ContractAddress,
        pub new_owner: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Upgraded {
        pub new_version: u8,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Paused {
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Unpaused {
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ProtocolFeeChanged {
        pub old_fee: u256,
        pub new_fee: u256,
    }

    #[derive(Drop, starknet::Event)]
        pub struct FeesWithdrawn {
        pub token: ContractAddress,
        pub amount: u256,
        pub recipient: ContractAddress,
        pub timestamp: u64,
    }

    #[storage]
    struct Storage {
        owner: ContractAddress,
        is_paused: bool,
        version: u8,
        protocol_fee: u256,
        cards: Map<u64, Cards>,
        card_counter: u64,
        user_cards: Map<
            (ContractAddress, u64), u64,
        >, // (user, user_sequence) -> global_txn_id
        user_card_count: Map<ContractAddress, u64>
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        initial_fee: u256,
    ) {
        assert(!owner.is_zero(), OWNER_CANNOT_BE_ZERO);
        self.owner.write(owner);
        self.version.write(1);
        self.card_counter.write(0);
        self.protocol_fee.write(initial_fee);
    }

    #[abi(embed_v0)]
    impl RunesCardV1Impl of IRunesCard<ContractState> {
        fn create_card(
            ref self: ContractState,
            token: ContractAddress,
            amount: u256,
            redeem_code_hash: felt252,
            description: ByteArray,
            link: felt252
        ) {
            assert(!self.is_paused.read(), CONTRACT_IS_PAUSED);
            assert(!token.is_zero(), INVALID_TOKEN_ADDRESS);
            assert(amount > 0, AMOUNT_MUST_BE_GREATER_THAN_ZERO);
            assert(redeem_code_hash != 0, INVALID_REDEEM_CODE);

            let caller = get_caller_address();
            let contract_address = get_contract_address();
            let current_id = self.card_counter.read();
            let new_id = current_id + 1;

            // check if the caller has enough allowance
            let token_dispatcher = IERC20Dispatcher { contract_address: token };
            let allowance = token_dispatcher.allowance(caller, contract_address);
            assert(allowance >= amount, INSUFFICIENT_ALLOWANCE);

            // Transfer tokens from creator to contract
            let token_dispatcher = IERC20Dispatcher { contract_address: token };
            let success = token_dispatcher.transfer_from(caller, contract_address, amount);
            assert(success, TOKEN_TRANSFER_FAILED);

            // Create the card
            let card = Cards {
                id: new_id,
                creator: caller,
                token: token,
                amount: amount,
                redeem_code_hash: redeem_code_hash,
                description: description,
                link: link,
                is_redeemed: false,
                created_at: get_block_timestamp(),
                redeemed_at: 0,
                redeemed_by: Zero::zero(),
            };

            // Store the card
            self.cards.write(new_id, card);
            self.card_counter.write(new_id);

            // Add to user's card list
            let user_count = self.user_card_count.read(caller);
            self.user_cards.write((caller, user_count), new_id);
            self.user_card_count.write(caller, user_count + 1);

            // Emit event
            self.emit(CardCreated {
                id: new_id,
                creator: caller,
                token: token,
                amount: amount,
                timestamp: get_block_timestamp(),
            });
        }

        fn redeem_card(ref self: ContractState, redeem_code: felt252, id: u64) {
            assert(!self.is_paused.read(), CONTRACT_IS_PAUSED);
            assert(id > 0 && id <= self.card_counter.read(), INVALID_CARD_ID);

            let caller = get_caller_address();
            let mut card = self.cards.read(id);

            assert(!card.is_redeemed, CARD_ALREADY_REDEEMED);

            // Hash the provided redeem code using Poseidon
            let computed_hash = PoseidonTrait::new().update(redeem_code).finalize();
            assert(computed_hash == card.redeem_code_hash, INVALID_REDEEM_CODE);

            // Calculate protocol fee
            let fee_amount = (card.amount * self.protocol_fee.read()) / 10000;
            let redeem_amount = card.amount - fee_amount;

            // Transfer tokens to redeemer
            let token_dispatcher = IERC20Dispatcher { contract_address: card.token };
            let success = token_dispatcher.transfer(caller, redeem_amount);
            assert(success, TOKEN_TRANSFER_FAILED);

            // Transfer fee to owner if fee > 0
            if fee_amount > 0 {
                let fee_success = token_dispatcher.transfer(self.owner.read(), fee_amount);
                assert(fee_success, TOKEN_TRANSFER_FAILED);
            }

            // Update card status
            card.is_redeemed = true;
            card.redeemed_by = caller;
            card.redeemed_at = get_block_timestamp();
            self.cards.write(id, card);

            // Add to redeemer's card list
            let user_count = self.user_card_count.read(caller);
            self.user_cards.write((caller, user_count), id);
            self.user_card_count.write(caller, user_count + 1);

            // Emit event
            self.emit(CardRedeemed {
                id: id,
                redeemer: caller,
                amount: redeem_amount,
                timestamp: get_block_timestamp(),
            });
        }

        fn get_card_balance(self: @ContractState, id: u64) -> u256 {
            let card = self.cards.read(id);
            if card.is_redeemed {
                0
            } else {
                card.amount
            }
        }

        fn get_card_by_id(self: @ContractState, id: u64) -> Cards {
            assert(id > 0 && id <= self.card_counter.read(), INVALID_CARD_ID);
            self.cards.read(id)
        }

        fn get_users_cards(self: @ContractState) -> Array<Cards> {
            let caller = get_caller_address();
            let count = self.user_card_count.read(caller);
            let mut cards = ArrayTrait::new();
            let mut i: u64 = 0;

            while i < count {
                let card_id = self.user_cards.read((caller, i));
                let card = self.cards.read(card_id);
                cards.append(card);
                i += 1;
            }

            cards
        }

        fn get_users_cards_paginated(
            self: @ContractState, 
            page: u64, 
            page_size: u64
        ) -> (Array<Cards>, u64) {
            let caller = get_caller_address();
            let total_count = self.user_card_count.read(caller);
            
            assert(page_size > 0, PAGE_SIZE_MUST_BE_GREATER_THAN_ZERO);
            assert(page_size <= 50, PAGE_SIZE_TOO_LARGE);
            
            let start_index = page * page_size;
            
            // Return empty if start is beyond total
            if start_index >= total_count {
                return (ArrayTrait::new(), total_count);
            }
            
            let mut cards = ArrayTrait::new();
            let mut i = start_index;
            let end_index = core::cmp::min(start_index + page_size, total_count);
            
            while i < end_index {
                let card_id = self.user_cards.read((caller, i));
                let card = self.cards.read(card_id);
                cards.append(card);
                i += 1;
            }
            
            (cards, total_count)
        }
        
        fn get_user_card_count(self: @ContractState, user: ContractAddress) -> u64 {
            self.user_card_count.read(user)
        }

        fn get_owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }

        fn change_owner(ref self: ContractState, new_owner: ContractAddress) {
            self._only_owner();
            let old_owner = self.owner.read();
            self.owner.write(new_owner);
            self.emit(OwnerChanged { old_owner, new_owner });
        }

        fn upgrade(ref self: ContractState, impl_hash: ClassHash, new_version: u8) {
            self._only_owner();
            assert(impl_hash.is_non_zero(), CLASS_HASH_CANNOT_BE_ZERO);
            starknet::syscalls::replace_class_syscall(impl_hash).unwrap();
            self.version.write(new_version);
            self.emit(Upgraded { new_version: new_version });
        }

        fn get_version(self: @ContractState) -> u8 {
            self.version.read()
        }

        fn pause(ref self: ContractState) {
            self._only_owner();
            let status = self.is_paused.read();
            assert(!status, CONTRACT_IS_PAUSED_ALREADY);
            self.is_paused.write(true);
            self.emit(Paused { timestamp: get_block_timestamp() });
        }

        fn unpause(ref self: ContractState) {
            self._only_owner();
            let status = self.is_paused.read();
            assert(status, CONTRACT_IS_ACTIVE_ALREADY);
            self.is_paused.write(false);
            self.emit(Unpaused { timestamp: get_block_timestamp() });
        }

        fn get_contract_status(self: @ContractState) -> bool {
            self.is_paused.read()
        }
        fn get_protocol_fee(self: @ContractState) -> u256 {
            self.protocol_fee.read()
        }
        fn set_protocol_fee(ref self: ContractState, new_fee: u256) {
            self._only_owner();
            let old_fee = self.protocol_fee.read();
            self.protocol_fee.write(new_fee);
            self.emit(ProtocolFeeChanged { old_fee, new_fee });
        }

        fn withdraw_fees(
            ref self: ContractState, 
            token: ContractAddress, 
            amount: u256,
            recipient: ContractAddress
        ) {
            self._only_owner();
            assert(!token.is_zero(), INVALID_TOKEN_ADDRESS);
            assert(!recipient.is_zero(), INVALID_RECIPIENT_ADDRESS);
            assert(amount > 0, AMOUNT_MUST_BE_GREATER_THAN_ZERO);
        
            // Get contract's token balance
            let token_dispatcher = IERC20Dispatcher { contract_address: token };
            let contract_balance = token_dispatcher.balance_of(get_contract_address());
            
            assert(contract_balance >= amount, INSUFFICIENT_BALANCE);
        
            // Transfer tokens to recipient
            let success = token_dispatcher.transfer(recipient, amount);
            assert(success, TOKEN_TRANSFER_FAILED);
        
            // Emit event
            self.emit(FeesWithdrawn {
                token: token,
                amount: amount,
                recipient: recipient,
                timestamp: get_block_timestamp(),
            });
        }
        
        fn get_contract_token_balance(self: @ContractState, token: ContractAddress) -> u256 {
            assert(!token.is_zero(), INVALID_TOKEN_ADDRESS);
            let token_dispatcher = IERC20Dispatcher { contract_address: token };
            token_dispatcher.balance_of(get_contract_address())
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _only_owner(ref self: ContractState) {
            let caller = get_caller_address();
            assert(caller.is_non_zero(), ZERO_ADDRESS_NOT_ALLOWED);

            let owner = self.owner.read();
            assert(owner == caller, UNAUTHORIZED_CALLER);
        }
    }
}
