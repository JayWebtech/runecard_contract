#[starknet::contract]
pub mod RunesCardV2 {
    use core::hash::HashStateTrait;
    use core::num::traits::Zero;
    use core::poseidon::PoseidonTrait;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::class_hash::ClassHash;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};
    use crate::interface::IRunesCard::IRunesCard;
    use crate::types::errors::{
        AMOUNT_MUST_BE_GREATER_THAN_ZERO, CARD_ALREADY_REDEEMED, CLASS_HASH_CANNOT_BE_ZERO,
        CONTRACT_IS_ACTIVE_ALREADY, CONTRACT_IS_PAUSED, CONTRACT_IS_PAUSED_ALREADY,
        INSUFFICIENT_ALLOWANCE, INSUFFICIENT_BALANCE, INVALID_CARD_ID, INVALID_CARD_TYPE,
        INVALID_DESCRIPTION, INVALID_LINK, INVALID_RECIPIENT_ADDRESS, INVALID_REDEEM_CODE,
        INVALID_TOKEN_ADDRESS, OWNER_CANNOT_BE_ZERO, PAGE_SIZE_MUST_BE_GREATER_THAN_ZERO,
        PAGE_SIZE_TOO_LARGE, TOKEN_TRANSFER_FAILED, UNAUTHORIZED_CALLER, ZERO_ADDRESS_NOT_ALLOWED,
    };
    use crate::types::structs::{Cards, GlobalStats, TokenStats};


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
        user_cards: Map<(ContractAddress, u64), u64>,
        user_card_count: Map<ContractAddress, u64>,
        redeemed_cards: Map<(ContractAddress, u64), u64>,
        redeemed_card_count: Map<ContractAddress, u64>,
        total_fees_collected: Map<ContractAddress, u256>,
        unique_creators: Map<ContractAddress, bool>,
        unique_creator_count: u64,
        total_cards_redeemed: u64,
        total_value_locked: Map<ContractAddress, u256>,
        total_value_redeemed: Map<ContractAddress, u256>,
        token_list: Map<u64, ContractAddress>,
        token_list_count: u64,
        is_token_registered: Map<ContractAddress, bool>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, initial_fee: u256) {
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
            link: felt252,
            card_type: u16,
        ) {
            assert(!self.is_paused.read(), CONTRACT_IS_PAUSED);
            assert(!token.is_zero(), INVALID_TOKEN_ADDRESS);
            assert(amount > 0, AMOUNT_MUST_BE_GREATER_THAN_ZERO);
            assert(redeem_code_hash != 0, INVALID_REDEEM_CODE);
            assert(description.len() > 0, INVALID_DESCRIPTION);
            assert(link != 0, INVALID_LINK);
            assert(card_type > 0, INVALID_CARD_TYPE);

            let caller = get_caller_address();
            let contract_address = get_contract_address();
            let current_id = self.card_counter.read();
            let new_id = current_id + 1;

            let token_dispatcher = IERC20Dispatcher { contract_address: token };
            let allowance = token_dispatcher.allowance(caller, contract_address);
            assert(allowance >= amount, INSUFFICIENT_ALLOWANCE);

            let success = token_dispatcher.transfer_from(caller, contract_address, amount);
            assert(success, TOKEN_TRANSFER_FAILED);

            let card = Cards {
                id: new_id,
                creator: caller,
                token: token,
                amount: amount,
                redeem_code_hash: redeem_code_hash,
                description: description,
                link: link,
                card_type: card_type,
                is_redeemed: false,
                created_at: get_block_timestamp(),
                redeemed_at: 0,
                redeemed_by: Zero::zero(),
            };

            self.cards.write(new_id, card);
            self.card_counter.write(new_id);

            let user_count = self.user_card_count.read(caller);
            self.user_cards.write((caller, user_count), new_id);
            self.user_card_count.write(caller, user_count + 1);

            if !self.unique_creators.read(caller) {
                self.unique_creators.write(caller, true);
                let creator_count = self.unique_creator_count.read();
                self.unique_creator_count.write(creator_count + 1);
            }

            if !self.is_token_registered.read(token) {
                let token_count = self.token_list_count.read();
                self.token_list.write(token_count, token);
                self.token_list_count.write(token_count + 1);
                self.is_token_registered.write(token, true);
            }

            let current_tvl = self.total_value_locked.read(token);
            self.total_value_locked.write(token, current_tvl + amount);

            self
                .emit(
                    CardCreated {
                        id: new_id,
                        creator: caller,
                        token: token,
                        amount: amount,
                        timestamp: get_block_timestamp(),
                    },
                );
        }

        // MODIFY redeem_card to track statistics
        fn redeem_card(ref self: ContractState, redeem_code: felt252, id: u64) {
            assert(!self.is_paused.read(), CONTRACT_IS_PAUSED);
            assert(id > 0 && id <= self.card_counter.read(), INVALID_CARD_ID);

            let caller = get_caller_address();
            let mut card = self.cards.read(id);

            assert(!card.is_redeemed, CARD_ALREADY_REDEEMED);

            let computed_hash = PoseidonTrait::new().update(redeem_code).finalize();
            assert(computed_hash == card.redeem_code_hash, INVALID_REDEEM_CODE);

            let fee_amount = (card.amount * self.protocol_fee.read()) / 10000;
            let redeem_amount = card.amount - fee_amount;

            let token_dispatcher = IERC20Dispatcher { contract_address: card.token };
            let success = token_dispatcher.transfer(caller, redeem_amount);
            assert(success, TOKEN_TRANSFER_FAILED);

            if fee_amount > 0 {
                let fee_success = token_dispatcher.transfer(self.owner.read(), fee_amount);
                assert(fee_success, TOKEN_TRANSFER_FAILED);

                let current_fees = self.total_fees_collected.read(card.token);
                self.total_fees_collected.write(card.token, current_fees + fee_amount);
            }

            let card_token = card.token;
            let card_amount = card.amount;

            card.is_redeemed = true;
            card.redeemed_by = caller;
            card.redeemed_at = get_block_timestamp();
            self.cards.write(id, card);

            let redeemed_count = self.redeemed_card_count.read(caller);
            self.redeemed_cards.write((caller, redeemed_count), id);
            self.redeemed_card_count.write(caller, redeemed_count + 1);

            let total_redeemed = self.total_cards_redeemed.read();
            self.total_cards_redeemed.write(total_redeemed + 1);

            let current_redeemed = self.total_value_redeemed.read(card_token);
            self.total_value_redeemed.write(card_token, current_redeemed + card_amount);

            self
                .emit(
                    CardRedeemed {
                        id: id,
                        redeemer: caller,
                        amount: redeem_amount,
                        timestamp: get_block_timestamp(),
                    },
                );
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

        fn get_users_cards(self: @ContractState, user: ContractAddress) -> Array<Cards> {
            let count = self.user_card_count.read(user);
            let mut cards = ArrayTrait::new();
            let mut i: u64 = 0;

            while i < count {
                let card_id = self.user_cards.read((user, i));
                let card = self.cards.read(card_id);
                cards.append(card);
                i += 1;
            }

            cards
        }

        fn get_users_cards_paginated(
            self: @ContractState, page: u64, page_size: u64, user: ContractAddress,
        ) -> (Array<Cards>, u64) {
            let total_count = self.user_card_count.read(user);

            assert(page_size > 0, PAGE_SIZE_MUST_BE_GREATER_THAN_ZERO);
            assert(page_size <= 50, PAGE_SIZE_TOO_LARGE);

            let start_index = page * page_size;

            if start_index >= total_count {
                return (ArrayTrait::new(), total_count);
            }

            let mut cards = ArrayTrait::new();
            let mut i = start_index;
            let end_index = core::cmp::min(start_index + page_size, total_count);

            while i < end_index {
                let card_id = self.user_cards.read((user, i));
                let card = self.cards.read(card_id);
                cards.append(card);
                i += 1;
            }

            (cards, total_count)
        }

        fn get_users_redeemed_cards_paginated(
            self: @ContractState, page: u64, page_size: u64, user: ContractAddress,
        ) -> (Array<Cards>, u64) {
            let total_count = self.redeemed_card_count.read(user);

            assert(page_size > 0, PAGE_SIZE_MUST_BE_GREATER_THAN_ZERO);
            assert(page_size <= 50, PAGE_SIZE_TOO_LARGE);

            let start_index = page * page_size;

            if start_index >= total_count {
                return (ArrayTrait::new(), total_count);
            }

            let mut cards = ArrayTrait::new();
            let mut i = start_index;
            let end_index = core::cmp::min(start_index + page_size, total_count);

            while i < end_index {
                let card_id = self.redeemed_cards.read((user, i));
                let card = self.cards.read(card_id);
                cards.append(card);
                i += 1;
            }

            (cards, total_count)
        }

        fn get_user_redeemed_card_count(self: @ContractState, user: ContractAddress) -> u64 {
            self.redeemed_card_count.read(user)
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
            recipient: ContractAddress,
        ) {
            self._only_owner();
            assert(!token.is_zero(), INVALID_TOKEN_ADDRESS);
            assert(!recipient.is_zero(), INVALID_RECIPIENT_ADDRESS);
            assert(amount > 0, AMOUNT_MUST_BE_GREATER_THAN_ZERO);

            let token_dispatcher = IERC20Dispatcher { contract_address: token };
            let contract_balance = token_dispatcher.balance_of(get_contract_address());

            assert(contract_balance >= amount, INSUFFICIENT_BALANCE);

            let success = token_dispatcher.transfer(recipient, amount);
            assert(success, TOKEN_TRANSFER_FAILED);

            self
                .emit(
                    FeesWithdrawn {
                        token: token,
                        amount: amount,
                        recipient: recipient,
                        timestamp: get_block_timestamp(),
                    },
                );
        }

        fn get_contract_token_balance(self: @ContractState, token: ContractAddress) -> u256 {
            assert(!token.is_zero(), INVALID_TOKEN_ADDRESS);
            let token_dispatcher = IERC20Dispatcher { contract_address: token };
            token_dispatcher.balance_of(get_contract_address())
        }

        fn get_total_fees_collected(self: @ContractState, token: ContractAddress) -> u256 {
            self.total_fees_collected.read(token)
        }

        fn get_global_stats(self: @ContractState) -> GlobalStats {
            let total_cards = self.card_counter.read();
            let total_redeemed = self.total_cards_redeemed.read();

            GlobalStats {
                total_cards_created: total_cards,
                total_cards_redeemed: total_redeemed,
                total_cards_unredeemed: total_cards - total_redeemed,
                unique_creators: self.unique_creator_count.read(),
                total_tokens_supported: self.token_list_count.read(),
            }
        }

        fn get_token_stats(self: @ContractState, token: ContractAddress) -> TokenStats {
            assert(!token.is_zero(), INVALID_TOKEN_ADDRESS);

            let total_locked = self.total_value_locked.read(token);
            let total_redeemed = self.total_value_redeemed.read(token);

            let mut card_count: u64 = 0;
            let total_cards = self.card_counter.read();
            let mut i: u64 = 1;

            while i <= total_cards {
                let card = self.cards.read(i);
                if card.token == token {
                    card_count += 1;
                }
                i += 1;
            }

            TokenStats {
                token: token,
                total_value_locked: total_locked,
                total_value_redeemed: total_redeemed,
                total_value_unredeemed: total_locked - total_redeemed,
                total_cards: card_count,
                fees_collected: self.total_fees_collected.read(token),
            }
        }

        fn get_all_tokens(self: @ContractState) -> Array<ContractAddress> {
            let count = self.token_list_count.read();
            let mut tokens = ArrayTrait::new();
            let mut i: u64 = 0;

            while i < count {
                let token = self.token_list.read(i);
                tokens.append(token);
                i += 1;
            }

            tokens
        }

        fn get_token_list_paginated(
            self: @ContractState, page: u64, page_size: u64,
        ) -> (Array<ContractAddress>, u64) {
            let total_count = self.token_list_count.read();

            assert(page_size > 0, PAGE_SIZE_MUST_BE_GREATER_THAN_ZERO);
            assert(page_size <= 50, PAGE_SIZE_TOO_LARGE);

            let start_index = page * page_size;

            if start_index >= total_count {
                return (ArrayTrait::new(), total_count);
            }

            let mut tokens = ArrayTrait::new();
            let mut i = start_index;
            let end_index = core::cmp::min(start_index + page_size, total_count);

            while i < end_index {
                let token = self.token_list.read(i);
                tokens.append(token);
                i += 1;
            }

            (tokens, total_count)
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
