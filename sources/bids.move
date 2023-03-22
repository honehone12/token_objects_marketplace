module token_objects_marketplace::bids {
    use std::signer;
    use std::error;
    use std::vector;
    use std::option::{Self, Option};
    use aptos_std::table_with_length::{Self, TableWithLength};
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::timestamp;
    use token_objects::royalty::{Self, Royalty};
    use token_objects_marketplace::common::{Self, Fee, BidID, ListingID};

    friend token_objects_marketplace::markets;

    const E_ALREADY_BID: u64 = 1;
    const E_NO_BID_RECORDS: u64 = 2;
    const E_NO_SUCH_BID_ID: u64 = 3;
    const E_UNEXPECTED_COIN_VALUE: u64 = 4;
    const E_ZERO_COIN: u64 = 5;

    struct Bid<phantom TCoin> has store {
        coin: Coin<TCoin>,
        expiration_sec: u64
    }

    struct BidRecords<phantom TCoin> has key {
        key_list: vector<BidID>,
        bids_table: TableWithLength<BidID, Bid<TCoin>>
    }

    inline fun new_bid<TCoin>(
        coin: Coin<TCoin>,
        expiration_sec: u64
    ): Bid<TCoin> {
        Bid{
            coin,
            expiration_sec
        }
    }

    inline fun init_bid_records<TCoin>(bidder: &signer) {
        if (!exists<BidRecords<TCoin>>(signer::address_of(bidder))) {
            move_to(
                bidder,
                BidRecords<TCoin>{
                    key_list: vector::empty(),
                    bids_table: table_with_length::new()
                }
            )
        }
    }

    inline fun calc_royalty(
        value: u64,
        royalty: &Royalty,
    ): u64 {
        let numerator = royalty::numerator(royalty);
        let denominator = royalty::denominator(royalty);
        if (numerator == 0 || denominator == 0) {
            0
        } else {
            value * numerator / denominator
        }
    }

    public(friend) fun bid<TCoin>(
        bidder: &signer,
        entry: ListingID,
        offer_price: u64,
        expiration_sec: u64,
    ): BidID
    acquires BidRecords {
        common::verify_price(offer_price);
        let now = timestamp::now_seconds();
        common::verify_time(now, expiration_sec);
        let bidder_addr = signer::address_of(bidder);
        common::check_balance<TCoin>(bidder_addr, offer_price);
        init_bid_records<TCoin>(bidder);
        let bid_records = borrow_global_mut<BidRecords<TCoin>>(bidder_addr);
        let bid_id = common::new_bid_id(bidder_addr, entry, offer_price);
        assert!(
            !table_with_length::contains(&bid_records.bids_table, bid_id),
            error::already_exists(E_ALREADY_BID)
        );

        let coin = coin::withdraw<TCoin>(bidder, offer_price);
        let bid = new_bid(coin, expiration_sec);
        vector::push_back(&mut bid_records.key_list, bid_id);
        table_with_length::add(&mut bid_records.bids_table, bid_id, bid);
        bid_id
    }

    public(friend) fun execute_bid<TCoin>(
        bid_id: &BidID, 
        royalty: Option<Royalty>,         
        fee: Option<Fee>
    ): Coin<TCoin>
    acquires BidRecords {
        let bidder_addr = common::bidder(bid_id);
        let records = borrow_global_mut<BidRecords<TCoin>>(bidder_addr);
        let bid = table_with_length::borrow_mut(&mut records.bids_table, *bid_id);
        let stored_coin = coin::extract_all(&mut bid.coin);
        let origin_value = coin::value(&stored_coin);
        assert!(
            origin_value == common::bid_price(bid_id), 
            error::internal(E_UNEXPECTED_COIN_VALUE)
        );
        assert!(coin::value(&stored_coin) > 0, error::resource_exhausted(E_ZERO_COIN));

        if (option::is_some(&royalty)) {
            let royalty_raw = option::destroy_some(royalty); 
            let royalty_addr = royalty::payee_address(&royalty_raw);
            let royalty_value = calc_royalty(origin_value, &royalty_raw);
            let royalty_coin = coin::extract(&mut stored_coin, royalty_value);
            coin::deposit(royalty_addr, royalty_coin);
        };
        if (option::is_some(&fee)) {
            let fee_raw = option::destroy_some(fee);
            let fee_addr = common::fee_address(&fee_raw);
            let fee_value = common::calc_fee(origin_value, &fee_raw);
            let fee_coin = coin::extract(&mut stored_coin, fee_value);
            coin::deposit(fee_addr, fee_coin);
        };
        stored_coin
    }

    public entry fun withdraw_from_expired<TCoin>(bidder: &signer)
    acquires BidRecords {
        let bidder_address = signer::address_of(bidder);
        let records = borrow_global_mut<BidRecords<TCoin>>(bidder_address);

        let coin = coin::zero<TCoin>();
        let now = timestamp::now_seconds();
        let i = 0;
        let len = vector::length(&records.key_list);
        while (i < len) {
            let key = vector::borrow(&records.key_list, i);
            let bid = table_with_length::borrow_mut(&mut records.bids_table, *key);
            if (
                bid.expiration_sec <= now &&
                coin::value(&bid.coin) > 0
            ) {
                coin::merge(&mut coin, coin::extract_all(&mut bid.coin))
            };
            i = i + 1;  
        };
        coin::deposit(bidder_address, coin);
    }

    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::coin::FakeMoney;

    #[test_only]
    struct ListMe has key {}

    #[test_only]
    fun setup_test(bidder: &signer, other: &signer, framework: &signer) {
        account::create_account_for_test(@0x1);
        account::create_account_for_test(signer::address_of(bidder));
        account::create_account_for_test(signer::address_of(other));
        timestamp::set_time_has_started_for_testing(framework);
    }

    #[test_only]
    fun create_test_money(bidder: &signer, other: &signer, framework: &signer) {
        coin::create_fake_money(framework, bidder, 400);
        coin::register<FakeMoney>(bidder);
        coin::register<FakeMoney>(other);
        coin::transfer<FakeMoney>(framework, signer::address_of(bidder), 100);
        coin::transfer<FakeMoney>(framework, signer::address_of(other), 100);
    }

    #[test(bidder = @0x123, other = @0x234, framework = @0x1)]
    fun test_bid(bidder: &signer, other: &signer, framework: &signer)
    acquires BidRecords {
        setup_test(bidder, other, framework);
        create_test_money(bidder, other, framework);

        let other_addr = signer::address_of(other);
        let listing_id = common::new_listing_id(other_addr, 0);
        let bid_id = bid<FakeMoney>(bidder, listing_id, 1, 2);
        let bidder_addr = signer::address_of(bidder);
        let records = borrow_global<BidRecords<FakeMoney>>(bidder_addr);
        assert!(table_with_length::length(&records.bids_table) == 1, 0);
        assert!(table_with_length::contains(&records.bids_table, bid_id), 1);
        assert!(vector::length(&records.key_list) == 1, 2);
    }

    #[test(bidder = @0x123, other = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65539, location = token_objects_marketplace::common)]
    fun test_bid_fail_zero(bidder: &signer, other: &signer, framework: &signer)
    acquires BidRecords {
        setup_test(bidder, other, framework);
        create_test_money(bidder, other, framework);

        let other_addr = signer::address_of(other);
        let listing_id = common::new_listing_id(other_addr, 0);
        bid<FakeMoney>(bidder, listing_id, 0, 2);
    }

    #[test(bidder = @0x123, other = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65539, location = token_objects_marketplace::common)]
    fun test_bid_fail_max(bidder: &signer, other: &signer, framework: &signer)
    acquires BidRecords {
        setup_test(bidder, other, framework);
        create_test_money(bidder, other, framework);

        let other_addr = signer::address_of(other);
        let listing_id = common::new_listing_id(other_addr, 0);
        bid<FakeMoney>(bidder, listing_id, 0xffffffff_ffffffff, 2);
    }

    #[test(bidder = @0x123, other = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65537, location = token_objects_marketplace::common)]
    fun test_bid_fail_expire_in_past(bidder: &signer, other: &signer, framework: &signer)
    acquires BidRecords {
        setup_test(bidder, other, framework);
        create_test_money(bidder, other, framework);

        let other_addr = signer::address_of(other);
        let listing_id = common::new_listing_id(other_addr, 0);
        timestamp::update_global_time_for_test(3000_000);
        bid<FakeMoney>(bidder, listing_id, 1, 2);
    }

    #[test(bidder = @0x123, other = @0x234, framework = @0x1)]
    fun test_bid_twice(bidder: &signer, other: &signer, framework: &signer)
    acquires BidRecords {
        setup_test(bidder, other, framework);
        create_test_money(bidder, other, framework);

        let other_addr = signer::address_of(other);
        let listing_id = common::new_listing_id(other_addr, 0);
        bid<FakeMoney>(bidder, listing_id, 1, 2);
        let bid_id = bid<FakeMoney>(bidder, listing_id, 2, 2);
        let bidder_addr = signer::address_of(bidder);
        let records = borrow_global<BidRecords<FakeMoney>>(bidder_addr);
        assert!(table_with_length::length(&records.bids_table) == 2, 0);
        assert!(table_with_length::contains(&records.bids_table, bid_id), 1);
        assert!(vector::length(&records.key_list) == 2, 2);
    }

    #[test(bidder = @0x123, other = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 524289, location = Self)]
    fun test_bid_twice_fail_price_low(bidder: &signer, other: &signer, framework: &signer)
    acquires BidRecords {
        setup_test(bidder, other, framework);
        create_test_money(bidder, other, framework);

        let other_addr = signer::address_of(other);
        let listing_id = common::new_listing_id(other_addr, 0);
        bid<FakeMoney>(bidder, listing_id, 1, 2);
        bid<FakeMoney>(bidder, listing_id, 1, 2);
    }

    #[test(bidder = @0x123, other = @0x234, framework = @0x1)]
    fun test_execute(bidder: &signer, other: &signer, framework: &signer)
    acquires BidRecords {
        setup_test(bidder, other, framework);
        create_test_money(bidder, other, framework);

        let other_addr = signer::address_of(other);
        let listing_id = common::new_listing_id(other_addr, 0);
        let bid_id = bid<FakeMoney>(bidder, listing_id, 10, 2);
        let bidder_addr = signer::address_of(bidder);
        
        let royalty = option::some(royalty::create(10, 100, other_addr));
        let fee = option::some(common::new_fee(10, 100, other_addr));
        let coin = execute_bid<FakeMoney>(&bid_id, royalty, fee);
        assert!(coin::balance<FakeMoney>(bidder_addr) == 90, 0);
        assert!(coin::balance<FakeMoney>(other_addr) == 102, 1);
        coin::deposit(other_addr, coin);
        assert!(coin::balance<FakeMoney>(other_addr) == 110, 2);
    }

    #[test(bidder = @0x123, other = @0x234, framework = @0x1)]
    fun test_execute2(bidder: &signer, other: &signer, framework: &signer)
    acquires BidRecords {
        setup_test(bidder, other, framework);
        create_test_money(bidder, other, framework);

        let other_addr = signer::address_of(other);
        let listing_id = common::new_listing_id(other_addr, 0);
        let bid_id = bid<FakeMoney>(bidder, listing_id, 10, 2);
        let bidder_addr = signer::address_of(bidder);
        
        //let royalty = option::some(royalty::create(0, 100, other_addr));
        //let fee = option::some(common::new_fee(0, 100, other_addr));
        let coin = execute_bid<FakeMoney>(&bid_id, option::none(), option::none());
        assert!(coin::balance<FakeMoney>(bidder_addr) == 90, 0);
        assert!(coin::balance<FakeMoney>(other_addr) == 100, 1);
        coin::deposit(other_addr, coin);
        assert!(coin::balance<FakeMoney>(other_addr) == 110, 2);
    }

    #[test(bidder = @0x123, other = @0x234, framework = @0x1)]
    #[expected_failure]
    fun test_fail_execute_bad_fee(bidder: &signer, other: &signer, framework: &signer)
    acquires BidRecords {
        setup_test(bidder, other, framework);
        create_test_money(bidder, other, framework);

        let other_addr = signer::address_of(other);
        let listing_id = common::new_listing_id(other_addr, 0);
        let bid_id = bid<FakeMoney>(bidder, listing_id, 10, 2);
        
        let royalty = option::some(royalty::create(100, 100, other_addr));
        let fee = option::some(common::new_fee(100, 100, other_addr));
        let coin = execute_bid<FakeMoney>(&bid_id, royalty, fee);
        coin::deposit(other_addr, coin);
    }
}