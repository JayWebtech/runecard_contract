#[cfg(test)]
mod tests {
    use starknet::{ContractAddress, contract_address_const};
    use core::hash::HashStateTrait;
    use core::poseidon::PoseidonTrait;
    use snforge_std::{declare, ContractClassTrait, DeclareResultTrait, start_cheat_caller_address, stop_cheat_caller_address};
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use runecard_contract::interface::IRunesCard::{IRunesCardDispatcher, IRunesCardDispatcherTrait};
    //use runecard_contract::types::structs::Cards;

    // Constants for testing
    const INITIAL_SUPPLY: u256 = 1000000_000000;
    const PROTOCOL_FEE_BPS: u256 = 100; // 1% = 100 basis points
    const CARD_AMOUNT: u256 = 1000_000000;

    // Helper function to deploy mock ERC20
    fn deploy_mock_erc20(recipient: ContractAddress, owner: ContractAddress) -> ContractAddress {
        let contract = declare("MockERC20").unwrap().contract_class();
        let mut calldata = ArrayTrait::new();
        recipient.serialize(ref calldata);
        owner.serialize(ref calldata);
        6_u8.serialize(ref calldata); // decimals

        let (address, _) = contract.deploy(@calldata).unwrap();
        address
    }

    // Helper function to deploy RunesCard
    fn deploy_runes_card(owner: ContractAddress, initial_fee: u256) -> ContractAddress {
        let contract = declare("RunesCardV1").unwrap().contract_class();
        let mut calldata = ArrayTrait::new();
        owner.serialize(ref calldata);
        initial_fee.serialize(ref calldata);

        let (address, _) = contract.deploy(@calldata).unwrap();
        address
    }

    // Helper function to hash redeem code using Poseidon
    fn hash_redeem_code(code: felt252) -> felt252 {
        PoseidonTrait::new().update(code).finalize()
    }

    // Setup function that returns all necessary test addresses and contracts
    fn setup() -> (
        ContractAddress, ContractAddress, ContractAddress, ContractAddress, ContractAddress
    ) {
        let owner: ContractAddress = contract_address_const::<'owner'>();
        let user1: ContractAddress = contract_address_const::<'user1'>();
        let user2: ContractAddress = contract_address_const::<'user2'>();

        // Deploy mock ERC20 token
        let token = deploy_mock_erc20(user1, owner);

        // Deploy RunesCard contract with 1% fee
        let runes_card = deploy_runes_card(owner, PROTOCOL_FEE_BPS);

        (owner, user1, user2, token, runes_card)
    }

    // ============================================
    // Constructor Tests
    // ============================================

    #[test]
    fn test_constructor_success() {
        let owner: ContractAddress = contract_address_const::<'owner'>();
        let runes_card = deploy_runes_card(owner, PROTOCOL_FEE_BPS);
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        assert(dispatcher.get_owner() == owner, 'Wrong owner');
        assert(dispatcher.get_version() == 1, 'Wrong version');
        assert(dispatcher.get_protocol_fee() == PROTOCOL_FEE_BPS, 'Wrong protocol fee');
        assert(!dispatcher.get_contract_status(), 'Should not be paused');
    }

    #[test]
    fn test_constructor_zero_fee() {
        let owner: ContractAddress = contract_address_const::<'owner'>();
        let runes_card = deploy_runes_card(owner, 0);
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        assert(dispatcher.get_protocol_fee() == 0, 'Fee should be zero');
    }

    // ============================================
    // Card Creation Tests
    // ============================================

    #[test]
    fn test_create_card_success() {
        let (_, user1, _, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };
        let token_dispatcher = IERC20Dispatcher { contract_address: token };

        let redeem_code: felt252 = 'SECRET123';
        let code_hash = hash_redeem_code(redeem_code);

        // User1 approves and creates card
        start_cheat_caller_address(token, user1);
        token_dispatcher.approve(runes_card, CARD_AMOUNT);
        stop_cheat_caller_address(token);

        start_cheat_caller_address(runes_card, user1);

        dispatcher
            .create_card(
                token, CARD_AMOUNT, code_hash, "Birthday gift for Alice", 'https://card.link'
            );
        
        // Verify card was created correctly
        let card = dispatcher.get_card_by_id(1);
        assert(card.id == 1, 'Wrong card id');
        assert(card.creator == user1, 'Wrong creator');
        assert(card.token == token, 'Wrong token');
        assert(card.amount == CARD_AMOUNT, 'Wrong amount');
        assert(card.redeem_code_hash == code_hash, 'Wrong hash');
        assert(card.description == "Birthday gift for Alice", 'Wrong description');
        assert(card.link == 'https://card.link', 'Wrong link');
        assert(!card.is_redeemed, 'Should not be redeemed');
        assert(card.redeemed_at == 0, 'Redeemed_at should be 0');

        // Verify user card count
        assert(dispatcher.get_user_card_count(user1) == 1, 'Wrong card count');

        // Verify card balance
        let balance = dispatcher.get_card_balance(1);
        assert(balance == CARD_AMOUNT, 'Wrong balance');

        // Verify token was transferred
        let contract_balance = token_dispatcher.balance_of(runes_card);
        assert(contract_balance == CARD_AMOUNT, 'Wrong contract balance');
    }

    #[test]
    fn test_create_multiple_cards() {
        let (_, user1, _, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };
        let token_dispatcher = IERC20Dispatcher { contract_address: token };

        start_cheat_caller_address(token, user1);
        token_dispatcher.approve(runes_card, CARD_AMOUNT * 3);
        stop_cheat_caller_address(token);

        start_cheat_caller_address(runes_card, user1);

        // Create 3 cards
        let mut i: u64 = 0;
        while i < 3 {
            let code: felt252 = (i + 1000).into();
            let code_hash = hash_redeem_code(code);
            dispatcher.create_card(token, CARD_AMOUNT, code_hash, "Gift", 'link');
            i += 1;
        }

        // Verify all cards created
        assert(dispatcher.get_user_card_count(user1) == 3, 'Wrong card count');

        let cards = dispatcher.get_users_cards();
        assert(cards.len() == 3, 'Should have 3 cards');

        // Verify contract holds all tokens
        let contract_balance = token_dispatcher.balance_of(runes_card);
        assert(contract_balance == CARD_AMOUNT * 3, 'Wrong total balance');
    }

    #[test]
    #[should_panic(expected: ('Contract is paused',))]
    fn test_create_card_when_paused_fails() {
        let (owner, user1, _, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };
        let token_dispatcher = IERC20Dispatcher { contract_address: token };

        // Owner pauses contract
        start_cheat_caller_address(dispatcher.contract_address,owner);
        dispatcher.pause();

        // Try to create card
        start_cheat_caller_address(dispatcher.contract_address, user1);
        token_dispatcher.approve(runes_card, CARD_AMOUNT);
        let code_hash = hash_redeem_code('CODE');
        dispatcher.create_card(token, CARD_AMOUNT, code_hash, "Test", 'link');
    }

    #[test]
    #[should_panic(expected: ('Invalid token address',))]
    fn test_create_card_zero_token_fails() {
        let (_, user1, _, _, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        start_cheat_caller_address(dispatcher.contract_address, user1);
        let zero_address: ContractAddress = contract_address_const::<0>();
        let code_hash = hash_redeem_code('CODE');
        dispatcher.create_card(zero_address, CARD_AMOUNT, code_hash, "Test", 'link');
    }

    #[test]
    #[should_panic(expected: ('Amount must be greater than 0',))]
    fn test_create_card_zero_amount_fails() {
        let (_, user1, _, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        start_cheat_caller_address(dispatcher.contract_address, user1);
        let code_hash = hash_redeem_code('CODE');
        dispatcher.create_card(token, 0, code_hash, "Test", 'link');
    }

    #[test]
    #[should_panic(expected: ('Invalid redeem code',))]
    fn test_create_card_zero_hash_fails() {
        let (_, user1, _, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };
        let token_dispatcher = IERC20Dispatcher { contract_address: token };

        start_cheat_caller_address(dispatcher.contract_address, user1);
        token_dispatcher.approve(runes_card, CARD_AMOUNT);
        dispatcher.create_card(token, CARD_AMOUNT, 0, "Test", 'link');
    }

    #[test]
    #[should_panic(expected: ('Insufficient allowance',))]
    fn test_create_card_insufficient_allowance_fails() {
        let (_, user1, _, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        start_cheat_caller_address(dispatcher.contract_address, user1);
        let code_hash = hash_redeem_code('CODE');
        // No approval given
        dispatcher.create_card(token, CARD_AMOUNT, code_hash, "Test", 'link');
    }

    #[test]
    #[should_panic(expected: ('Insufficient allowance',))]
    fn test_create_card_partial_allowance_fails() {
        let (_, user1, _, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };
        let token_dispatcher = IERC20Dispatcher { contract_address: token };

        start_cheat_caller_address(dispatcher.contract_address, user1);
        // Only approve half the amount needed
        token_dispatcher.approve(runes_card, CARD_AMOUNT / 2);
        let code_hash = hash_redeem_code('CODE');
        dispatcher.create_card(token, CARD_AMOUNT, code_hash, "Test", 'link');
    }

    // ============================================
    // Card Redemption Tests
    // ============================================

    #[test]
    fn test_redeem_card_success() {
        let (owner, user1, user2, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };
        let token_dispatcher = IERC20Dispatcher { contract_address: token };

        // Create card
        let redeem_code: felt252 = 'SECRET123';
        let code_hash = hash_redeem_code(redeem_code);

        start_cheat_caller_address(token, user1);
        token_dispatcher.approve(runes_card, CARD_AMOUNT);
        stop_cheat_caller_address(token);

        start_cheat_caller_address(runes_card, user1);
        dispatcher.create_card(token, CARD_AMOUNT, code_hash, "Gift", 'link');
        stop_cheat_caller_address(runes_card);

        // Get balances before redemption
        let user2_balance_before = token_dispatcher.balance_of(user2);
        let owner_balance_before = token_dispatcher.balance_of(owner);

        // User2 redeems card
        start_cheat_caller_address(runes_card, user2);
        dispatcher.redeem_card(redeem_code, 1);

        // Calculate expected amounts (1% fee)
        let fee_amount = (CARD_AMOUNT * PROTOCOL_FEE_BPS) / 10000;
        let redeem_amount = CARD_AMOUNT - fee_amount;

        // Verify card status
        let card = dispatcher.get_card_by_id(1);
        assert(card.is_redeemed, 'Should be redeemed');
        assert(card.redeemed_by == user2, 'Wrong redeemer');
       // assert(card.redeemed_at > 0, 'Redeemed_at should be set');

        // Verify user2 received correct amount
        let user2_balance_after = token_dispatcher.balance_of(user2);
        assert(
            user2_balance_after == user2_balance_before + redeem_amount, 'Wrong user2 balance'
        );

        // Verify owner received fee
        let owner_balance_after = token_dispatcher.balance_of(owner);
        assert(owner_balance_after == owner_balance_before + fee_amount, 'Wrong owner fee');

        // Verify card balance is now 0
        assert(dispatcher.get_card_balance(1) == 0, 'Balance should be 0');

        // Verify user2 has card in their list
        assert(dispatcher.get_user_card_count(user2) == 1, 'User2 should have 1 card');
    }

    #[test]
    fn test_redeem_card_with_zero_fee() {
        let owner: ContractAddress = contract_address_const::<'owner'>();
        let user1: ContractAddress = contract_address_const::<'user1'>();
        let user2: ContractAddress = contract_address_const::<'user2'>();

        // Deploy with 0% fee
        let token = deploy_mock_erc20(user1, owner);
        let runes_card = deploy_runes_card(owner, 0);
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };
        let token_dispatcher = IERC20Dispatcher { contract_address: token };

        // Create and redeem card
        let redeem_code: felt252 = 'SECRET123';
        let code_hash = hash_redeem_code(redeem_code);

        start_cheat_caller_address(token, user1);
        token_dispatcher.approve(runes_card, CARD_AMOUNT);
        stop_cheat_caller_address(token);

        start_cheat_caller_address(runes_card, user1);

        dispatcher.create_card(token, CARD_AMOUNT, code_hash, "Gift", 'link');
        stop_cheat_caller_address(runes_card);

        let user2_balance_before = token_dispatcher.balance_of(user2);
        let owner_balance_before = token_dispatcher.balance_of(owner);

        start_cheat_caller_address(runes_card, user2);
        dispatcher.redeem_card(redeem_code, 1);
        stop_cheat_caller_address(runes_card);

        // Verify user2 received full amount (no fee)
        let user2_balance_after = token_dispatcher.balance_of(user2);
        assert(user2_balance_after == user2_balance_before + CARD_AMOUNT, 'Should get full amount');

        // Verify owner received no fee
        let owner_balance_after = token_dispatcher.balance_of(owner);
        assert(owner_balance_after == owner_balance_before, 'Owner should get no fee');
    }

    #[test]
    fn test_redeem_card_high_fee() {
        let owner: ContractAddress = contract_address_const::<'owner'>();
        let user1: ContractAddress = contract_address_const::<'user1'>();
        let user2: ContractAddress = contract_address_const::<'user2'>();

        // Deploy with 10% fee (1000 basis points)
        let token = deploy_mock_erc20(user1, owner);
        let runes_card = deploy_runes_card(owner, 1000);
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };
        let token_dispatcher = IERC20Dispatcher { contract_address: token };

        // Create and redeem card
        let redeem_code: felt252 = 'SECRET123';
        let code_hash = hash_redeem_code(redeem_code);

        start_cheat_caller_address(token, user1);
        token_dispatcher.approve(runes_card, CARD_AMOUNT);
        stop_cheat_caller_address(token);

        start_cheat_caller_address(runes_card, user1);
        dispatcher.create_card(token, CARD_AMOUNT, code_hash, "Gift", 'link');
        stop_cheat_caller_address(runes_card);

        let user2_balance_before = token_dispatcher.balance_of(user2);

        start_cheat_caller_address(runes_card, user2);
        dispatcher.redeem_card(redeem_code, 1);
        stop_cheat_caller_address(runes_card);

        // Calculate 10% fee
        let fee_amount = (CARD_AMOUNT * 1000) / 10000; // 10%
        let redeem_amount = CARD_AMOUNT - fee_amount;

        let user2_balance_after = token_dispatcher.balance_of(user2);
        assert(user2_balance_after == user2_balance_before + redeem_amount, 'Wrong amount after fee');
    }

    #[test]
    #[should_panic(expected: ('Contract is paused',))]
    fn test_redeem_card_when_paused_fails() {
        let (owner, user1, user2, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };
        let token_dispatcher = IERC20Dispatcher { contract_address: token };

        // Create card
        let redeem_code: felt252 = 'SECRET123';
        let code_hash = hash_redeem_code(redeem_code);

        start_cheat_caller_address(token, user1);
        token_dispatcher.approve(runes_card, CARD_AMOUNT);
        stop_cheat_caller_address(token);

        start_cheat_caller_address(runes_card, user1);
        dispatcher.create_card(token, CARD_AMOUNT, code_hash, "Gift", 'link');
        stop_cheat_caller_address(runes_card);

        start_cheat_caller_address(runes_card, owner);
        // Pause contract
        dispatcher.pause();
        stop_cheat_caller_address(runes_card);


        // Try to redeem
        start_cheat_caller_address(runes_card, user2);
        dispatcher.redeem_card(redeem_code, 1);
        stop_cheat_caller_address(runes_card);
    }

    #[test]
    #[should_panic(expected: ('Card already redeemed',))]
    fn test_redeem_card_twice_fails() {
        let (_, user1, user2, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };
        let token_dispatcher = IERC20Dispatcher { contract_address: token };

        // Create card
        let redeem_code: felt252 = 'SECRET123';
        let code_hash = hash_redeem_code(redeem_code);

        start_cheat_caller_address(token, user1);
        token_dispatcher.approve(runes_card, CARD_AMOUNT);
        stop_cheat_caller_address(token);

        start_cheat_caller_address(runes_card, user1);
        dispatcher.create_card(token, CARD_AMOUNT, code_hash, "Gift", 'link');
        stop_cheat_caller_address(runes_card);

        // User2 redeems (first time)
        start_cheat_caller_address(runes_card, user2);
        dispatcher.redeem_card(redeem_code, 1);
        
        // Verify card is marked as redeemed
        let card = dispatcher.get_card_by_id(1);
        assert(card.is_redeemed, 'Card should be redeemed');
        
        stop_cheat_caller_address(runes_card);

        // User2 tries again (should fail)
        start_cheat_caller_address(runes_card, user2);
        dispatcher.redeem_card(redeem_code, 1);
        stop_cheat_caller_address(runes_card);
    }

    #[test]
    #[should_panic(expected: ('Invalid redeem code',))]
    fn test_redeem_card_wrong_code_fails() {
        let (_, user1, user2, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };
        let token_dispatcher = IERC20Dispatcher { contract_address: token };

        // Create card
        let redeem_code: felt252 = 'SECRET123';
        let code_hash = hash_redeem_code(redeem_code);

        start_cheat_caller_address(token, user1);
        token_dispatcher.approve(runes_card, CARD_AMOUNT);
        stop_cheat_caller_address(token);

        start_cheat_caller_address(runes_card, user1);

        dispatcher.create_card(token, CARD_AMOUNT, code_hash, "Gift", 'link');

        stop_cheat_caller_address(runes_card);

        // Try to redeem with wrong code
        start_cheat_caller_address(runes_card, user2);
        dispatcher.redeem_card('WRONGCODE', 1);
        stop_cheat_caller_address(runes_card);
    }

    #[test]
    #[should_panic(expected: ('Invalid card ID',))]
    fn test_redeem_nonexistent_card_fails() {
        let (_, _, user2, _, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        start_cheat_caller_address(runes_card, user2);
        dispatcher.redeem_card('CODE', 999);
        stop_cheat_caller_address(runes_card);
    }

    #[test]
    #[should_panic(expected: ('Invalid card ID',))]
    fn test_redeem_card_id_zero_fails() {
        let (_, _, user2, _, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        start_cheat_caller_address(runes_card, user2);
        dispatcher.redeem_card('CODE', 0);
        stop_cheat_caller_address(runes_card);
    }

    // ============================================
    // Card Query Tests
    // ============================================

    #[test]
    fn test_get_card_by_id() {
        let (_, user1, _, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };
        let token_dispatcher = IERC20Dispatcher { contract_address: token };

        let redeem_code: felt252 = 'SECRET123';
        let code_hash = hash_redeem_code(redeem_code);

        start_cheat_caller_address(token, user1);
        token_dispatcher.approve(runes_card, CARD_AMOUNT);
        stop_cheat_caller_address(token);

        start_cheat_caller_address(runes_card, user1);

        dispatcher.create_card(token, CARD_AMOUNT, code_hash, "Test Card", 'mylink');
        stop_cheat_caller_address(runes_card);

        let card = dispatcher.get_card_by_id(1);
        assert(card.id == 1, 'Wrong id');
        assert(card.creator == user1, 'Wrong creator');
        assert(card.description == "Test Card", 'Wrong description');
    }

    #[test]
    #[should_panic(expected: ('Invalid card ID',))]
    fn test_get_card_by_invalid_id_fails() {
        let (_, _, _, _, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        dispatcher.get_card_by_id(999);
    }

    #[test]
    fn test_get_card_balance() {
        let (_, user1, user2, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };
        let token_dispatcher = IERC20Dispatcher { contract_address: token };

        let redeem_code: felt252 = 'SECRET123';
        let code_hash = hash_redeem_code(redeem_code);

        start_cheat_caller_address(token, user1);
        token_dispatcher.approve(runes_card, CARD_AMOUNT);
        stop_cheat_caller_address(token);

        start_cheat_caller_address(runes_card, user1);

        dispatcher.create_card(token, CARD_AMOUNT, code_hash, "Gift", 'link');

        // Before redemption
        assert(dispatcher.get_card_balance(1) == CARD_AMOUNT, 'Wrong balance before');

        // Redeem card
        start_cheat_caller_address(runes_card, user2);
        dispatcher.redeem_card(redeem_code, 1);

        // After redemption
        assert(dispatcher.get_card_balance(1) == 0, 'Balance should be 0');
    }

    #[test]
    fn test_get_users_cards() {
        let (_, user1, _, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };
        let token_dispatcher = IERC20Dispatcher { contract_address: token };

        // User1 creates 3 cards
        start_cheat_caller_address(token, user1);
        token_dispatcher.approve(runes_card, CARD_AMOUNT * 3);
        stop_cheat_caller_address(token);

        start_cheat_caller_address(runes_card, user1);

        let mut i: u64 = 0;
        while i < 3 {
            let code: felt252 = (i + 1000).into();
            let code_hash = hash_redeem_code(code);
            dispatcher.create_card(token, CARD_AMOUNT, code_hash, "Gift", 'link');
            i += 1;
        }

        // Get user1's cards
        let cards = dispatcher.get_users_cards();
        assert(cards.len() == 3, 'Should have 3 cards');

        // Verify first card
        let first_card = cards.at(0);
        assert(*first_card.id == 1, 'First card wrong id');
        assert(*first_card.creator == user1, 'First card wrong creator');
    }

    #[test]
    fn test_get_users_cards_empty() {
        let (_, _, user2, _, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        // User2 has no cards
        start_cheat_caller_address(dispatcher.contract_address, user2);
        let cards = dispatcher.get_users_cards();
        assert(cards.len() == 0, 'Should have no cards');
    }

    #[test]
    fn test_get_users_cards_includes_redeemed() {
        let (_, user1, user2, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };
        let token_dispatcher = IERC20Dispatcher { contract_address: token };

        // User1 creates card
        let redeem_code: felt252 = 'SECRET123';
        let code_hash = hash_redeem_code(redeem_code);

        start_cheat_caller_address(token, user1);
        token_dispatcher.approve(runes_card, CARD_AMOUNT);
        stop_cheat_caller_address(token);

        start_cheat_caller_address(runes_card, user1);
        dispatcher.create_card(token, CARD_AMOUNT, code_hash, "Gift", 'link');
        stop_cheat_caller_address(runes_card);

        // User2 redeems
        start_cheat_caller_address(runes_card, user2);
        dispatcher.redeem_card(redeem_code, 1);

        // User2 should now have the card in their list
        let user2_cards = dispatcher.get_users_cards();
        assert(user2_cards.len() == 1, 'User2 should have 1 card');
        let card_0 = user2_cards.at(0);
        assert(*card_0.is_redeemed, 'Card should be redeemed');
    }

    // ============================================
    // Pagination Tests
    // ============================================

    #[test]
    fn test_pagination_basic() {
        let (_, user1, _, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };
        let token_dispatcher = IERC20Dispatcher { contract_address: token };

        // Create 10 cards
        start_cheat_caller_address(token, user1);
        token_dispatcher.approve(runes_card, CARD_AMOUNT * 10);
        stop_cheat_caller_address(token);

        start_cheat_caller_address(runes_card, user1);

        let mut i: u64 = 0;
        while i < 10 {
            let code: felt252 = (i + 1000).into();
            let code_hash = hash_redeem_code(code);
            dispatcher.create_card(token, CARD_AMOUNT, code_hash, "Gift", 'link');
            i += 1;
        }

        // Test first page
        let (page1, total) = dispatcher.get_users_cards_paginated(0, 5);
        assert(page1.len() == 5, 'Page 1 should have 5');
        assert(total == 10, 'Total should be 10');

        // Test second page
        let (page2, _) = dispatcher.get_users_cards_paginated(1, 5);
        assert(page2.len() == 5, 'Page 2 should have 5');

        // Test third page (empty)
        let (page3, _) = dispatcher.get_users_cards_paginated(2, 5);
        assert(page3.len() == 0, 'Page 3 should be empty');
    }

    #[test]
    fn test_pagination_partial_last_page() {
        let (_, user1, _, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };
        let token_dispatcher = IERC20Dispatcher { contract_address: token };

        // Create 7 cards
        start_cheat_caller_address(token, user1);
        token_dispatcher.approve(runes_card, CARD_AMOUNT * 7);
        stop_cheat_caller_address(token);

        start_cheat_caller_address(runes_card, user1);

        let mut i: u64 = 0;
        while i < 7 {
            let code: felt252 = (i + 1000).into();
            let code_hash = hash_redeem_code(code);
            dispatcher.create_card(token, CARD_AMOUNT, code_hash, "Gift", 'link');
            i += 1;
        }

        // First page
        let (page1, total) = dispatcher.get_users_cards_paginated(0, 5);
        assert(page1.len() == 5, 'Page 1 should have 5');
        assert(total == 7, 'Total should be 7');

        // Second page (partial)
        let (page2, _) = dispatcher.get_users_cards_paginated(1, 5);
        assert(page2.len() == 2, 'Page 2 should have 2');
    }

    #[test]
    fn test_pagination_single_item_pages() {
        let (_, user1, _, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };
        let token_dispatcher = IERC20Dispatcher { contract_address: token };

        // Create 3 cards
        start_cheat_caller_address(token, user1);
        token_dispatcher.approve(runes_card, CARD_AMOUNT * 3);
        stop_cheat_caller_address(token);

        start_cheat_caller_address(runes_card, user1);
        let mut i: u64 = 0;
        while i < 3 {
            let code: felt252 = (i + 1000).into();
            let code_hash = hash_redeem_code(code);
            dispatcher.create_card(token, CARD_AMOUNT, code_hash, "Gift", 'link');
            i += 1;
        }
     
        // Get one card at a time
        let (page1, total) = dispatcher.get_users_cards_paginated(0, 1);
        assert(page1.len() == 1, 'Page should have 1');
        let card_1 = page1.at(0);
        assert(*card_1.id == 1, 'Should be card 1');
        assert(total == 3, 'Total should be 3');

        let (page2, _) = dispatcher.get_users_cards_paginated(1, 1);
        let card_2 = page2.at(0);
        assert(*card_2.id == 2, 'Should be card 2');

        let (page3, _) = dispatcher.get_users_cards_paginated(2, 1);
        let card_3 = page3.at(0);
        assert(*card_3.id == 3, 'Should be card 3');
    }

    #[test]
    #[should_panic(expected: ('Page size must be > than zero',))]
    fn test_pagination_zero_page_size_fails() {
        let (_, user1, _, _, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        start_cheat_caller_address(runes_card, user1);
        dispatcher.get_users_cards_paginated(0, 0);
    }

    #[test]
    #[should_panic(expected: ('Page size too large',))]
    fn test_pagination_too_large_fails() {
        let (_, user1, _, _, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        start_cheat_caller_address(dispatcher.contract_address, user1);
        dispatcher.get_users_cards_paginated(0, 51);
    }

    #[test]
    fn test_pagination_max_page_size() {
        let (_, user1, _, _, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        start_cheat_caller_address(dispatcher.contract_address, user1);
        // Should accept page size of 50 (max)
        let (cards, total) = dispatcher.get_users_cards_paginated(0, 50);
        assert(cards.len() == 0, 'Should have 0 cards');
        assert(total == 0, 'Total should be 0');
    }

    // ============================================
    // Owner Management Tests
    // ============================================

    #[test]
    fn test_change_owner() {
        let (owner, user1, _, _, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        start_cheat_caller_address(dispatcher.contract_address,owner);
        dispatcher.change_owner(user1);

        assert(dispatcher.get_owner() == user1, 'Owner not changed');
    }

    #[test]
    #[should_panic(expected: ('Unauthorized caller',))]
    fn test_change_owner_unauthorized_fails() {
        let (_, user1, user2, _, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        start_cheat_caller_address(dispatcher.contract_address, user1);
        dispatcher.change_owner(user2);
    }

    #[test]
    #[should_panic(expected: ('Zero address not allowed',))]
    fn test_change_owner_from_zero_fails() {
        let (_, user1, _, _, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        let zero_address: ContractAddress = contract_address_const::<0>();
        start_cheat_caller_address(dispatcher.contract_address,zero_address);
        dispatcher.change_owner(user1);
    }

    #[test]
    fn test_new_owner_can_perform_admin_actions() {
        let (owner, user1, _, _, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        // Transfer ownership
        start_cheat_caller_address(dispatcher.contract_address,owner);
        dispatcher.change_owner(user1);

        // New owner can pause
        start_cheat_caller_address(dispatcher.contract_address, user1);
        dispatcher.pause();
        assert(dispatcher.get_contract_status(), 'Should be paused');
    }

    // ============================================
    // Pause/Unpause Tests
    // ============================================

    #[test]
    fn test_pause() {
        let (owner, _, _, _, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        start_cheat_caller_address(dispatcher.contract_address,owner);
        dispatcher.pause();

        assert(dispatcher.get_contract_status(), 'Should be paused');
    }

    #[test]
    fn test_unpause() {
        let (owner, _, _, _, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        start_cheat_caller_address(dispatcher.contract_address,owner);
        dispatcher.pause();
        dispatcher.unpause();

        assert(!dispatcher.get_contract_status(), 'Should not be paused');
    }

    #[test]
    #[should_panic(expected: ('Contract is paused already',))]
    fn test_pause_twice_fails() {
        let (owner, _, _, _, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        start_cheat_caller_address(dispatcher.contract_address,owner);
        dispatcher.pause();
        dispatcher.pause();
    }

    #[test]
    #[should_panic(expected: ('Contract is already active',))]
    fn test_unpause_when_not_paused_fails() {
        let (owner, _, _, _, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        start_cheat_caller_address(dispatcher.contract_address,owner);
        dispatcher.unpause();
    }

    #[test]
    #[should_panic(expected: ('Unauthorized caller',))]
    fn test_pause_unauthorized_fails() {
        let (_, user1, _, _, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        start_cheat_caller_address(dispatcher.contract_address, user1);
        dispatcher.pause();
    }

    #[test]
    #[should_panic(expected: ('Unauthorized caller',))]
    fn test_unpause_unauthorized_fails() {
        let (owner, user1, _, _, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        start_cheat_caller_address(dispatcher.contract_address,owner);
        dispatcher.pause();

        start_cheat_caller_address(dispatcher.contract_address, user1);
        dispatcher.unpause();
    }

    // ============================================
    // Protocol Fee Tests
    // ============================================

    #[test]
    fn test_set_protocol_fee() {
        let (owner, _, _, _, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        start_cheat_caller_address(dispatcher.contract_address,owner);
        dispatcher.set_protocol_fee(200);

        assert(dispatcher.get_protocol_fee() == 200, 'Fee not updated');
    }

    #[test]
    fn test_set_protocol_fee_to_zero() {
        let (owner, _, _, _, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        start_cheat_caller_address(dispatcher.contract_address,owner);
        dispatcher.set_protocol_fee(0);

        assert(dispatcher.get_protocol_fee() == 0, 'Fee should be 0');
    }

    #[test]
    #[should_panic(expected: ('Unauthorized caller',))]
    fn test_set_protocol_fee_unauthorized_fails() {
        let (_, user1, _, _, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        start_cheat_caller_address(dispatcher.contract_address, user1);
        dispatcher.set_protocol_fee(200);
    }

    // ============================================
    // Fee Withdrawal Tests
    // ============================================

    #[test]
    fn test_withdraw_fees() {
        let (owner, user1, user2, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };
        let token_dispatcher = IERC20Dispatcher { contract_address: token };

        // Create and redeem card to generate fees
        let redeem_code: felt252 = 'SECRET123';
        let code_hash = hash_redeem_code(redeem_code);

        start_cheat_caller_address(token, user1);
        token_dispatcher.approve(runes_card, CARD_AMOUNT);
        stop_cheat_caller_address(token);

        start_cheat_caller_address(runes_card, user1);
        dispatcher.create_card(token, CARD_AMOUNT, code_hash, "Gift", 'link');
        stop_cheat_caller_address(runes_card);

        start_cheat_caller_address(runes_card, user2);
        dispatcher.redeem_card(redeem_code, 1);
        stop_cheat_caller_address(runes_card);

        // Calculate fee (1%)
        //let fee_amount = (CARD_AMOUNT * PROTOCOL_FEE_BPS) / 10000;

        // Owner already received fees during redemption
        // But contract still holds the card amount initially
        let user3: ContractAddress = contract_address_const::<'user3'>();
        let user3_balance_before = token_dispatcher.balance_of(user3);

        start_cheat_caller_address(runes_card,owner);
        let owner_fee_balance = token_dispatcher.balance_of(owner);
        dispatcher.withdraw_fees(token, owner_fee_balance, user3);

        let user3_balance_after = token_dispatcher.balance_of(user3);
        assert(user3_balance_after == user3_balance_before + owner_fee_balance, 'Wrong withdrawal');
    }

    #[test]
    #[should_panic(expected: ('Insufficient balance',))]
    fn test_withdraw_fees_insufficient_balance_fails() {
        let (owner, _, _, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        start_cheat_caller_address(runes_card,owner);
        dispatcher.withdraw_fees(token, 999999_000000, owner);
    }

    #[test]
    #[should_panic(expected: ('Unauthorized caller',))]
    fn test_withdraw_fees_unauthorized_fails() {
        let (owner, user1, _, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        start_cheat_caller_address(dispatcher.contract_address, user1);
        dispatcher.withdraw_fees(token, 1000, owner);
    }

    #[test]
    #[should_panic(expected: ('Invalid token address',))]
    fn test_withdraw_fees_zero_token_fails() {
        let (owner, _, _, _, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        let zero_address: ContractAddress = contract_address_const::<0>();
        start_cheat_caller_address(dispatcher.contract_address,owner);
        dispatcher.withdraw_fees(zero_address, 1000, owner);
    }

    #[test]
    #[should_panic(expected: ('Invalid recipient address',))]
    fn test_withdraw_fees_zero_recipient_fails() {
        let (owner, _, _, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        let zero_address: ContractAddress = contract_address_const::<0>();
        start_cheat_caller_address(dispatcher.contract_address,owner);
        dispatcher.withdraw_fees(token, 1000, zero_address);
    }

    #[test]
    #[should_panic(expected: ('Amount must be greater than 0',))]
    fn test_withdraw_fees_zero_amount_fails() {
        let (owner, _, _, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        start_cheat_caller_address(dispatcher.contract_address,owner);
        dispatcher.withdraw_fees(token, 0, owner);
    }

    // ============================================
    // Contract Token Balance Tests
    // ============================================

    #[test]
    fn test_get_contract_token_balance() {
        let (_, user1, _, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };
        let token_dispatcher = IERC20Dispatcher { contract_address: token };

        // Initial balance should be 0
        let initial_balance = dispatcher.get_contract_token_balance(token);
        assert(initial_balance == 0, 'Initial balance should be 0');

        // Create card
        let redeem_code: felt252 = 'SECRET123';
        let code_hash = hash_redeem_code(redeem_code);

        start_cheat_caller_address(token, user1);
        token_dispatcher.approve(runes_card, CARD_AMOUNT);
        stop_cheat_caller_address(token);

        start_cheat_caller_address(runes_card, user1);
        dispatcher.create_card(token, CARD_AMOUNT, code_hash, "Gift", 'link');

        // Balance should now equal card amount
        let balance = dispatcher.get_contract_token_balance(token);
        assert(balance == CARD_AMOUNT, 'Wrong contract balance');
    }

    #[test]
    #[should_panic(expected: ('Invalid token address',))]
    fn test_get_contract_token_balance_zero_token_fails() {
        let (_, _, _, _, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        let zero_address: ContractAddress = contract_address_const::<0>();
        dispatcher.get_contract_token_balance(zero_address);
    }

    // ============================================
    // Version and Upgrade Tests
    // ============================================

    #[test]
    fn test_get_version() {
        let (_, _, _, _, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };

        assert(dispatcher.get_version() == 1, 'Version should be 1');
    }

    // ============================================
    // User Card Count Tests
    // ============================================

    #[test]
    fn test_get_user_card_count() {
        let (_, user1, _, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };
        let token_dispatcher = IERC20Dispatcher { contract_address: token };

        // Initially 0
        assert(dispatcher.get_user_card_count(user1) == 0, 'Should be 0');

        // Create cards
        start_cheat_caller_address(token, user1);
        token_dispatcher.approve(runes_card, CARD_AMOUNT * 3);
        stop_cheat_caller_address(token);

        start_cheat_caller_address(runes_card, user1);
        let mut i: u64 = 0;
        while i < 3 {
            let code: felt252 = (i + 1000).into();
            let code_hash = hash_redeem_code(code);
            dispatcher.create_card(token, CARD_AMOUNT, code_hash, "Gift", 'link');
            i += 1;
        }

        assert(dispatcher.get_user_card_count(user1) == 3, 'Should be 3');
    }

    #[test]
    fn test_user_card_count_after_redemption() {
        let (_, user1, user2, token, runes_card) = setup();
        let dispatcher = IRunesCardDispatcher { contract_address: runes_card };
        let token_dispatcher = IERC20Dispatcher { contract_address: token };

        // User1 creates card
        let redeem_code: felt252 = 'SECRET123';
        let code_hash = hash_redeem_code(redeem_code);

        start_cheat_caller_address(token, user1);
        token_dispatcher.approve(runes_card, CARD_AMOUNT);
        stop_cheat_caller_address(token);

        start_cheat_caller_address(runes_card, user1);
        dispatcher.create_card(token, CARD_AMOUNT, code_hash, "Gift", 'link');
        stop_cheat_caller_address(runes_card);

        // User2 redeems
        start_cheat_caller_address(runes_card, user2);
        dispatcher.redeem_card(redeem_code, 1);
        stop_cheat_caller_address(runes_card);

        // Both users should have count of 1
        assert(dispatcher.get_user_card_count(user1) == 1, 'User1 should have 1');
        assert(dispatcher.get_user_card_count(user2) == 1, 'User2 should have 1');
    }
}

