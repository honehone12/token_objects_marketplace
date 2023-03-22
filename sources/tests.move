#[test_only]
module token_objects_marketplace::tests {
    use std::signer;
    use std::option;
    use std::vector;
    use std::string::utf8;
    use aptos_framework::timestamp;
    use aptos_framework::account;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::coin::{Self, FakeMoney};
    use token_objects::token;
    use token_objects::collection;
    use token_objects::royalty;
    use token_objects_marketplace::markets;
    use token_objects_marketplace::bids;

    struct ListMe has key {}

    fun setup_test(
        lister: &signer, 
        bidder_1: &signer, 
        bidder_2: &signer, 
        market_host: &signer,
        creator: &signer, 
        framework: &signer
    ) {
        account::create_account_for_test(@0x1);
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(@0x123);
        account::create_account_for_test(@0x234);
        account::create_account_for_test(@0x235);
        account::create_account_for_test(@0x345);
        account::create_account_for_test(@0x456);
        coin::register<FakeMoney>(lister);
        coin::register<FakeMoney>(bidder_1);
        coin::register<FakeMoney>(bidder_2);
        coin::register<FakeMoney>(creator);
        coin::register<FakeMoney>(market_host);
        coin::create_fake_money(framework, market_host, 500);
        coin::transfer<FakeMoney>(framework, @0x123, 100);
        coin::transfer<FakeMoney>(framework, @0x234, 100);
        coin::transfer<FakeMoney>(framework, @0x235, 100);
        coin::transfer<FakeMoney>(framework, @0x345, 100);
        coin::transfer<FakeMoney>(framework, @0x456, 100);
    }

    fun create_test_object(account: &signer): Object<ListMe> {
        _ = collection::create_untracked_collection(
            account,
            utf8(b"collection description"),
            utf8(b"collection"),
            option::none(),
            utf8(b"collection uri"),
        );
        let cctor = token::create(
            account,
            utf8(b"collection"),
            utf8(b"description"),
            utf8(b"name"),
            option::some(royalty::create(10, 100, signer::address_of(account))),
            utf8(b"uri")
        );
        move_to(&object::generate_signer(&cctor), ListMe{});
        object::object_from_constructor_ref<ListMe>(&cctor)
    }

    #[test(
        lister = @0x123, 
        bidder_1 = @0x234, 
        bidder_2 = @0x235, 
        market_host = @0x345, 
        creator = @0x456,
        framework = @0x1
    )]
    fun test_instant_sale_happy_path(
        lister: &signer, 
        bidder_1: &signer, 
        bidder_2: &signer, 
        market_host: &signer,
        creator: &signer, 
        framework: &signer
    ) {
        setup_test(lister, bidder_1, bidder_2, market_host, creator, framework);
        markets::create_market(market_host, 10, 100);
        let lister_addr = signer::address_of(lister);
        let market_addr = signer::address_of(market_host);
        let bidder_1_addr = signer::address_of(bidder_1);
        let creator_addr = signer::address_of(creator);

        let obj = create_test_object(creator);
        object::transfer(creator, obj, lister_addr);
        let obj_addr = object::object_address(&obj);
        markets::start_listing<ListMe, FakeMoney>(
            lister, @0x345, obj_addr,
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            true,
            10,
            1, 1 + 86400,
            false
        );

        timestamp::update_global_time_for_test(2_000_000);
        markets::bid<ListMe, FakeMoney>(
            bidder_1, lister_addr, obj_addr,
            0,
            10
        );

        timestamp::update_global_time_for_test(86400_000_000 + 2_000_000);
        assert!(coin::balance<FakeMoney>(bidder_1_addr) == 90, 0);
        markets::close_listing<ListMe, FakeMoney>(lister, market_addr, 0);
        assert!(object::is_owner(obj, bidder_1_addr), 1);
        assert!(coin::balance<FakeMoney>(lister_addr) == 108, 2);
        assert!(coin::balance<FakeMoney>(market_addr) == 101, 3);
        assert!(coin::balance<FakeMoney>(creator_addr) == 101, 4);
    }

    #[test(
        lister = @0x123, 
        bidder_1 = @0x234, 
        bidder_2 = @0x235, 
        market_host = @0x345,
        creator = @0x456, 
        framework = @0x1
    )]
    fun test_auction_happy_path(
        lister: &signer, 
        bidder_1: &signer, 
        bidder_2: &signer, 
        market_host: &signer,
        creator: &signer, 
        framework: &signer
    ) {
        setup_test(lister, bidder_1, bidder_2, market_host, creator, framework);
        markets::create_market(market_host, 10, 100);
        let lister_addr = signer::address_of(lister);
        let market_addr = signer::address_of(market_host);
        let bidder_1_addr = signer::address_of(bidder_1);
        let bidder_2_addr = signer::address_of(bidder_2);
        let creator_addr = signer::address_of(creator);


        let obj = create_test_object(creator);
        object::transfer(creator, obj, lister_addr);
        let obj_addr = object::object_address(&obj);
        markets::start_listing<ListMe, FakeMoney>(
            lister, @0x345, obj_addr,
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            false,
            1,
            1, 86400 + 1,
            false
        );

        timestamp::update_global_time_for_test(2000_000);
        markets::bid<ListMe, FakeMoney>(
            bidder_1, lister_addr, obj_addr,
            0,
            10
        );

        markets::bid<ListMe, FakeMoney>(
            bidder_2, lister_addr, obj_addr,
            0,
            20
        );

        assert!(coin::balance<FakeMoney>(bidder_1_addr) == 90, 0);
        assert!(coin::balance<FakeMoney>(bidder_2_addr) == 80, 1);
        timestamp::update_global_time_for_test(86400_000_000 + 86400_000_000);
        markets::close_listing<ListMe, FakeMoney>(lister, market_addr, 0);
        assert!(object::is_owner(obj, bidder_2_addr), 2);
        assert!(coin::balance<FakeMoney>(lister_addr) == 116, 3);
        assert!(coin::balance<FakeMoney>(market_addr) == 102, 4);
        assert!(coin::balance<FakeMoney>(creator_addr) == 102, 5);

        timestamp::update_global_time_for_test(1000_000 + 86400_000_000 + 86400_000_000);
        bids::withdraw_from_expired<FakeMoney>(bidder_1);
        assert!(coin::balance<FakeMoney>(bidder_1_addr) == 100, 6);
    }

    #[test(
        lister = @0x123, 
        bidder_1 = @0x234, 
        bidder_2 = @0x235, 
        market_host = @0x345,
        creator = @0x456, 
        framework = @0x1
    )]
    #[expected_failure(abort_code = 524297, location = token_objects_marketplace::listings)]
    fun test_auction_create_twice(
        lister: &signer, 
        bidder_1: &signer, 
        bidder_2: &signer, 
        market_host: &signer,
        creator: &signer, 
        framework: &signer
    ) {
        setup_test(lister, bidder_1, bidder_2, market_host, creator, framework);
        markets::create_market(market_host, 10, 100);
        let lister_addr = signer::address_of(lister);
        let obj = create_test_object(creator);
        object::transfer(creator, obj, lister_addr);
        let obj_addr = object::object_address(&obj);
        
        markets::start_listing<ListMe, FakeMoney>(
            lister, @0x345, obj_addr,
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            false,
            5,
            1, 86400 + 1,
            false
        );

        timestamp::update_global_time_for_test(4000_000);

        markets::start_listing<ListMe, FakeMoney>(
            lister, @0x345, obj_addr,
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            false,
            1,
            5, 86400 + 5,
            false
        );
    }
}