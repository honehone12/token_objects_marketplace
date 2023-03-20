module token_objects_marketplace::listings {
    use std::signer;
    use std::error;
    use std::vector;
    use std::string::String;
    use aptos_std::timestamp;
    use aptos_std::table_with_length::{Self, TableWithLength};
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_std::type_info::{Self, TypeInfo};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::coin::{Self, Coin};
    use aptos_token::property_map::PropertyMap;
    use token_objects_marketplace::common::{Self, BidID, ListingID};

    friend token_objects_marketplace::markets;

    const E_NO_SUCH_LISTING: u64 = 1;
    const E_INVALID_OBJECT_ADDRESS: u64 = 2;
    const E_ALREADY_OWNER: u64 = 3;
    const E_OUT_OF_SERVICE_TIME: u64 = 4;
    const E_NOT_OWNER: u64 = 5;
    const E_LOWER_PRICE: u64 = 6;
    const E_NO_BIDS: u64 = 7;
    const E_EMPTY_COIN: u64 = 8;
    const E_DUPLICATED_LISTING: u64 = 9;

    struct Listing<phantom TCoin> has store {
        object_address: address,
        object_type: TypeInfo,
        object_property: PropertyMap,

        min_price: u64,
        is_instant_sale: bool,
        start_sec: u64, // !!! range
        expiration_sec: u64, // !!! range

        bids_map: SimpleMap<u64, BidID>,
        bid_prices: vector<u64>
    }

    struct ListingRecords<phantom TCoin> has key {
        current_listing_nonce: u64,
        listed_objects: vector<address>,
        key_list: vector<ListingID>,
        listing_table: TableWithLength<ListingID, Listing<TCoin>> 
    }

    inline fun init_listing_records<TCoin>(owner: &signer) {
        if (!exists<ListingRecords<TCoin>>(signer::address_of(owner))) {
            move_to(
                owner,
                ListingRecords<TCoin>{
                    current_listing_nonce: 0,
                    listed_objects: vector::empty(),
                    key_list: vector::empty(),
                    listing_table: table_with_length::new()
                }
            )
        }
    }

    inline fun verify_record_exists<TCoin>(addr: address) {
        assert!(exists<ListingRecords<TCoin>>(addr), error::not_found(E_NO_SUCH_LISTING));
    }

    inline fun verify_listing_exists<TCoin>(records: &ListingRecords<TCoin>, listing_id: &ListingID) {
        assert!(
            table_with_length::contains(&records.listing_table, *listing_id), 
            error::not_found(E_NO_SUCH_LISTING)
        );
    }

    inline fun new_listing<T: key, TCoin>(
        owner: &signer,
        obj: Object<T>,
        property: PropertyMap,
        min_price: u64,
        is_instant_sale: bool,
        start_sec: u64,
        expiration_sec: u64
    ): Listing<TCoin> {
        common::verify_object_owner<T>(obj, signer::address_of(owner));
        common::verify_time(timestamp::now_seconds(), start_sec);
        common::verify_time(start_sec, expiration_sec);
        common::verify_price(min_price);
        Listing{
            object_address: object::object_address(&obj),
            object_type: type_info::type_of<T>(),
            object_property: property,
            min_price,
            is_instant_sale,
            start_sec,
            expiration_sec,
            bids_map: simple_map::create(),
            bid_prices: vector::empty()
        }
    }

    inline fun highest_price<TCoin>(listing: &Listing<TCoin>): u64 {
        let len_prices = vector::length(&listing.bid_prices);
        if (len_prices == 0) {
            listing.min_price
        } else {
            *vector::borrow(&listing.bid_prices, len_prices - 1)
        }
    }

    public fun object_address<TCoin>(listing_id: &ListingID): address
    acquires ListingRecords {
        let listing_address = common::listing_address(listing_id);
        verify_record_exists<TCoin>(listing_address);
        let records = borrow_global<ListingRecords<TCoin>>(listing_address);
        verify_listing_exists<TCoin>(records, listing_id);
        let listing = table_with_length::borrow(&records.listing_table, *listing_id);
        listing.object_address
    }

    public fun highest_bid<TCoin>(listing_id: &ListingID): BidID
    acquires ListingRecords {
        let listing_address = common::listing_address(listing_id);
        verify_record_exists<TCoin>(listing_address);
        let records = borrow_global<ListingRecords<TCoin>>(listing_address);
        verify_listing_exists<TCoin>(records, listing_id);
        let listing = table_with_length::borrow(&records.listing_table, *listing_id);
        assert!(vector::length(&listing.bid_prices) > 0, error::unavailable(E_NO_BIDS));
        let highest_price = highest_price<TCoin>(listing);
        *simple_map::borrow(&listing.bids_map, &highest_price)
    }

    public fun into_listing_id<TCoin>(addr: address, nonce: u64): ListingID 
    acquires ListingRecords {
        verify_record_exists<TCoin>(addr);
        let records = borrow_global<ListingRecords<TCoin>>(addr);
        let id = common::new_listing_id(addr, nonce);
        verify_listing_exists<TCoin>(records, &id);
        id
    }

    public(friend) fun bid<TCoin>(bid_id: BidID, object_address: address)
    acquires ListingRecords {
        let listing_id = common::listing_id(&bid_id);
        let listing_address = common::listing_address(&listing_id);
        verify_record_exists<TCoin>(listing_address);
        let records = borrow_global_mut<ListingRecords<TCoin>>(listing_address);
        verify_listing_exists<TCoin>(records, &listing_id);
        let listing = table_with_length::borrow_mut(&mut records.listing_table, listing_id);
        let now_sec = timestamp::now_seconds();
        assert!(
            listing_address != common::bidder(&bid_id),
            error::invalid_argument(E_ALREADY_OWNER) 
        );
        assert!(
            object_address == listing.object_address, 
            error::invalid_argument(E_INVALID_OBJECT_ADDRESS)
        );
        assert!(
            listing.start_sec < now_sec && now_sec < listing.expiration_sec,
            error::invalid_argument(E_OUT_OF_SERVICE_TIME)
        );

        let price = common::bid_price(&bid_id);
        if (listing.is_instant_sale) {
            assert!(price >= listing.min_price, error::invalid_argument(E_LOWER_PRICE));
            let now = timestamp::now_seconds();
            listing.expiration_sec = now - 1;
        } else {
            assert!(price > highest_price(listing), error::invalid_argument(E_LOWER_PRICE));
        };
        simple_map::add(&mut listing.bids_map, price, bid_id);
        vector::push_back(&mut listing.bid_prices, price);
    }

    public(friend) fun execute_listing<T: key, TCoin>(
        listser: &signer,
        coins: Coin<TCoin>, 
        bidder_address: address,
        listing_id: &ListingID
    )
    acquires ListingRecords {
        let listing_address = common::listing_address(listing_id);
        verify_record_exists<TCoin>(listing_address);
        let records = borrow_global_mut<ListingRecords<TCoin>>(listing_address);
        verify_listing_exists<TCoin>(records, listing_id);
        let listing = table_with_length::borrow(&records.listing_table, *listing_id);
        assert!(
            listing.expiration_sec < timestamp::now_seconds(),
            error::invalid_argument(E_OUT_OF_SERVICE_TIME)
        );
        let obj = object::address_to_object<T>(listing.object_address);
        common::verify_object_owner(obj, listing_address);
        let (ok, idx) = vector::index_of(&records.listed_objects, &listing.object_address);
        assert!(ok, error::internal(E_DUPLICATED_LISTING));
        assert!(coin::value(&coins) > 0, error::resource_exhausted(E_EMPTY_COIN));

        vector::remove(&mut records.listed_objects, idx);
        object::transfer(listser, obj, bidder_address);
        coin::deposit(listing_address, coins);
    }

    public(friend) fun start_listing<T: key, TCoin>(
        owner: &signer,
        object_address: address,
        collection_name: String,
        token_name: String,
        
        property_name: vector<String>,
        property_value: vector<vector<u8>>,
        property_type: vector<String>,

        is_instant_sale: bool,
        min_price: u64,
        start_sec: u64,
        expiration_sec: u64
    ): ListingID
    acquires ListingRecords {
        let obj = object::address_to_object<T>(object_address); // including exists T
        common::verify_token(obj, collection_name, token_name); // including exists Collection & Token
        let prop = common::into_property_map(property_name, property_value, property_type);
        init_listing_records<TCoin>(owner);
        let obj_addr = object::object_address(&obj);
        let owner_addr = signer::address_of(owner);
        let records = borrow_global_mut<ListingRecords<TCoin>>(owner_addr);
        assert!(
            !vector::contains(&records.listed_objects, &obj_addr),
            error::already_exists(E_DUPLICATED_LISTING) 
        );
        
        let nonce = records.current_listing_nonce; 
        records.current_listing_nonce = nonce + 1;
        let id = common::new_listing_id(owner_addr, nonce);
        let listing = new_listing<T, TCoin>(
            owner,
            obj,
            prop,
            min_price,
            is_instant_sale,
            start_sec,
            expiration_sec
        );
        table_with_length::add(&mut records.listing_table, id, listing);
        vector::push_back(&mut records.key_list, id);
        vector::push_back(&mut records.listed_objects, obj_addr);
        id
    }

    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::coin::FakeMoney;
    #[test_only]
    use token_objects::token;
    #[test_only]
    use token_objects::collection;
    #[test_only]
    use std::string::utf8;
    #[test_only]
    use std::option;

    #[test_only]
    struct ListMe has key {}

    #[test_only]
    fun setup_test(lister: &signer, other: &signer, framework: &signer) {
        account::create_account_for_test(@0x1);
        account::create_account_for_test(signer::address_of(lister));
        account::create_account_for_test(signer::address_of(other));
        timestamp::set_time_has_started_for_testing(framework);
    }

    #[test_only]
    fun create_test_money(lister: &signer, other: &signer, framework: &signer) {
        coin::create_fake_money(framework, lister, 400);
        coin::register<FakeMoney>(lister);
        coin::register<FakeMoney>(other);
        coin::transfer<FakeMoney>(framework, signer::address_of(lister), 100);
        coin::transfer<FakeMoney>(framework, signer::address_of(other), 100);
    }

    #[test_only]
    fun create_test_object(account: &signer): Object<ListMe> {
        _ = collection::create_untracked_collection(
            account,
            utf8(b"collection description"),
            collection::create_mutability_config(false, false),
            utf8(b"collection"),
            option::none(),
            utf8(b"collection uri"),
        );
        let cctor = token::create_token(
            account,
            utf8(b"collection"),
            utf8(b"description"),
            token::create_mutability_config(false, false, false),
            utf8(b"name"),
            option::none(),
            utf8(b"uri")
        );
        move_to(&object::generate_signer(&cctor), ListMe{});
        object::object_from_constructor_ref<ListMe>(&cctor)
    }

    #[test(lister = @0x123, other = @0x234, framework = @0x1)]
    fun test_start_listing(lister: &signer, other: &signer, framework: &signer)
    acquires ListingRecords {
        setup_test(lister, other, framework);
        let obj = create_test_object(lister);
        let listing_id = start_listing<ListMe, FakeMoney>(
            lister,
            object::object_address(&obj),
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            false,
            1,
            2,
            5
        );
        let lister_addr = signer::address_of(lister);
        let records = borrow_global<ListingRecords<FakeMoney>>(lister_addr);
        assert!(vector::length(&records.key_list) == 1, 0);
        assert!(table_with_length::contains(&records.listing_table, listing_id), 1);
        assert!(table_with_length::length(&records.listing_table) == 1, 2);
    }

    #[test(lister = @0x123, other = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 327682, location = token_objects_marketplace::common)]
    fun test_fail_start_listing_not_owner(lister: &signer, other: &signer, framework: &signer)
    acquires ListingRecords {
        setup_test(lister, other, framework);
        let obj = create_test_object(other);
        start_listing<ListMe, FakeMoney>(
            lister,
            object::object_address(&obj),
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            false,
            1,
            2,
            5
        );
    }

    #[test(lister = @0x123, other = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65537, location = token_objects_marketplace::common)]
    fun test_fail_start_listing_start_at_past(lister: &signer, other: &signer, framework: &signer)
    acquires ListingRecords {
        setup_test(lister, other, framework);
        timestamp::update_global_time_for_test(2000_000);
        let obj = create_test_object(lister);
        start_listing<ListMe, FakeMoney>(
            lister,
            object::object_address(&obj),
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            false,
            1,
            2,
            5
        );
    }

    #[test(lister = @0x123, other = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65537, location = token_objects_marketplace::common)]
    fun test_fail_start_listing_start_end_past(lister: &signer, other: &signer, framework: &signer)
    acquires ListingRecords {
        setup_test(lister, other, framework);
        timestamp::update_global_time_for_test(2000_000);
        let obj = create_test_object(lister);
        start_listing<ListMe, FakeMoney>(
            lister,
            object::object_address(&obj),
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            false,
            1,
            3,
            1
        );
    }

    #[test(lister = @0x123, other = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65539, location = token_objects_marketplace::common)]
    fun test_fail_start_listing_price_zero(lister: &signer, other: &signer, framework: &signer)
    acquires ListingRecords {
        setup_test(lister, other, framework);
        let obj = create_test_object(lister);
        start_listing<ListMe, FakeMoney>(
            lister,
            object::object_address(&obj),
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            false,
            0,
            1,
            2
        );
    }

    #[test(lister = @0x123, other = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65539, location = token_objects_marketplace::common)]
    fun test_fail_start_listing_price_max(lister: &signer, other: &signer, framework: &signer)
    acquires ListingRecords {
        setup_test(lister, other, framework);
        let obj = create_test_object(lister);
        start_listing<ListMe, FakeMoney>(
            lister,
            object::object_address(&obj),
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            false,
            0xffffffff_ffffffff,
            1,
            2
        );
    }

    #[test(lister = @0x123, other = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65541, location = token_objects_marketplace::common)]
    fun test_fail_start_listing_inconsistent_property(lister: &signer, other: &signer, framework: &signer)
    acquires ListingRecords {
        setup_test(lister, other, framework);
        let obj = create_test_object(lister);
        start_listing<ListMe, FakeMoney>(
            lister,
            object::object_address(&obj),
            utf8(b"collection"), utf8(b"name"),
            vector<String>[utf8(b"a")], vector::empty(), vector::empty(),
            false,
            1,
            1,
            2
        );
    }

    #[test(lister = @0x123, other = @0x234, framework = @0x1)]
    fun test_into_listing_id(lister: &signer, other: &signer, framework: &signer)
    acquires ListingRecords {
        setup_test(lister, other, framework);
        let obj = create_test_object(lister);
        start_listing<ListMe, FakeMoney>(
            lister,
            object::object_address(&obj),
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            false,
            1,
            2,
            5
        );
        let lister_addr = signer::address_of(lister);
        into_listing_id<FakeMoney>(lister_addr, 0);
    }

    #[test(lister = @0x123, other = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 393217, location = Self)]
    fun test_fail_into_listing_id(lister: &signer, other: &signer, framework: &signer)
    acquires ListingRecords {
        setup_test(lister, other, framework);
        let obj = create_test_object(lister);
        start_listing<ListMe, FakeMoney>(
            lister,
            object::object_address(&obj),
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            false,
            1,
            2,
            5
        );
        let lister_addr = signer::address_of(lister);
        into_listing_id<FakeMoney>(lister_addr, 1);
    }

    #[test(lister = @0x123, other = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 393217, location = Self)]
    fun test_fail_into_listing_id2(lister: &signer, other: &signer, framework: &signer)
    acquires ListingRecords {
        setup_test(lister, other, framework);
        let obj = create_test_object(lister);
        start_listing<ListMe, FakeMoney>(
            lister,
            object::object_address(&obj),
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            false,
            1,
            2,
            5
        );
        into_listing_id<FakeMoney>(@0xcafe, 0);
    }

    #[test(lister = @0x123, other = @0x234, framework = @0x1)]
    fun test_bid(lister: &signer, other: &signer, framework: &signer)
    acquires ListingRecords {
        setup_test(lister, other, framework);
        let obj = create_test_object(lister);
        let obj_addr = object::object_address(&obj);
        start_listing<ListMe, FakeMoney>(
            lister,
            obj_addr,
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            false,
            1,
            2,
            5
        );
        let lister_addr = signer::address_of(lister);
        let other_addr = signer::address_of(other);
        let listing_id = common::new_listing_id(lister_addr, 0);
        timestamp::update_global_time_for_test(3000_000);
        let bid_id = common::new_bid_id(other_addr, listing_id, 2);
        bid<FakeMoney>(bid_id, obj_addr);
        let records = borrow_global<ListingRecords<FakeMoney>>(lister_addr);
        let listing = table_with_length::borrow(&records.listing_table, listing_id);
        assert!(vector::length(&listing.bid_prices) == 1, 2);
        assert!(simple_map::contains_key(&listing.bids_map, &2), 3);
    }

    #[test(lister = @0x123, other = @0x234, framework = @0x1)]
    fun test_bid_instant_sale(lister: &signer, other: &signer, framework: &signer)
    acquires ListingRecords {
        setup_test(lister, other, framework);
        let obj = create_test_object(lister);
        let obj_addr = object::object_address(&obj);
        start_listing<ListMe, FakeMoney>(
            lister,
            obj_addr,
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            true,
            1,
            2,
            5
        );
        let lister_addr = signer::address_of(lister);
        let other_addr = signer::address_of(other);
        let listing_id = common::new_listing_id(lister_addr, 0);
        timestamp::update_global_time_for_test(3000_000);
        let bid_id = common::new_bid_id(other_addr, listing_id, 1);
        bid<FakeMoney>(bid_id, obj_addr);
        let records = borrow_global<ListingRecords<FakeMoney>>(lister_addr);
        let listing = table_with_length::borrow(&records.listing_table, listing_id);
        assert!(vector::length(&listing.bid_prices) == 1, 2);
        assert!(simple_map::contains_key(&listing.bids_map, &1), 3);
    }

    #[test(lister = @0x123, other = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65538, location = Self)]
    fun test_bid_fail_invalid_obj(lister: &signer, other: &signer, framework: &signer)
    acquires ListingRecords {
        setup_test(lister, other, framework);
        let obj = create_test_object(lister);
        let obj_addr = object::object_address(&obj);
        start_listing<ListMe, FakeMoney>(
            lister,
            obj_addr,
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            false,
            1,
            2,
            5
        );
        let lister_addr = signer::address_of(lister);
        let other_addr = signer::address_of(other);
        let listing_id = common::new_listing_id(lister_addr, 0);
        timestamp::update_global_time_for_test(3000_000);
        let bid_id = common::new_bid_id(other_addr, listing_id, 1);
        bid<FakeMoney>(bid_id, @0xcafe);
    }

    #[test(lister = @0x123, other = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65539, location = Self)]
    fun test_bid_fail_invalid_self(lister: &signer, other: &signer, framework: &signer)
    acquires ListingRecords {
        setup_test(lister, other, framework);
        let obj = create_test_object(lister);
        let obj_addr = object::object_address(&obj);
        start_listing<ListMe, FakeMoney>(
            lister,
            obj_addr,
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            false,
            1,
            2,
            5
        );
        let lister_addr = signer::address_of(lister);
        let listing_id = common::new_listing_id(lister_addr, 0);
        timestamp::update_global_time_for_test(3000_000);
        let bid_id = common::new_bid_id(lister_addr, listing_id, 1);
        bid<FakeMoney>(bid_id, obj_addr);
    }

    #[test(lister = @0x123, other = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65542, location = Self)]
    fun test_bid_fail_too_low(lister: &signer, other: &signer, framework: &signer)
    acquires ListingRecords {
        setup_test(lister, other, framework);
        let obj = create_test_object(lister);
        let obj_addr = object::object_address(&obj);
        start_listing<ListMe, FakeMoney>(
            lister,
            obj_addr,
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            false,
            1,
            2,
            5
        );
        let lister_addr = signer::address_of(lister);
        let other_addr = signer::address_of(other);
        let listing_id = common::new_listing_id(lister_addr, 0);
        timestamp::update_global_time_for_test(3000_000);
        let bid_id = common::new_bid_id(other_addr, listing_id, 1);
        bid<FakeMoney>(bid_id, obj_addr);
    }

    #[test(lister = @0x123, other = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65542, location = Self)]
    fun test_bid_fail_too_low_instant_sale(lister: &signer, other: &signer, framework: &signer)
    acquires ListingRecords {
        setup_test(lister, other, framework);
        let obj = create_test_object(lister);
        let obj_addr = object::object_address(&obj);
        start_listing<ListMe, FakeMoney>(
            lister,
            obj_addr,
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            true,
            2,
            2,
            5
        );
        let lister_addr = signer::address_of(lister);
        let other_addr = signer::address_of(other);
        let listing_id = common::new_listing_id(lister_addr, 0);
        timestamp::update_global_time_for_test(3000_000);
        let bid_id = common::new_bid_id(other_addr, listing_id, 1);
        bid<FakeMoney>(bid_id, obj_addr);
    }

    #[test(lister = @0x123, other = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65540, location = Self)]
    fun test_bid_fail_not_started(lister: &signer, other: &signer, framework: &signer)
    acquires ListingRecords {
        setup_test(lister, other, framework);
        let obj = create_test_object(lister);
        let obj_addr = object::object_address(&obj);
        start_listing<ListMe, FakeMoney>(
            lister,
            obj_addr,
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            false,
            1,
            5,
            10
        );
        let lister_addr = signer::address_of(lister);
        let other_addr = signer::address_of(other);
        let listing_id = common::new_listing_id(lister_addr, 0);
        timestamp::update_global_time_for_test(3000_000);
        let bid_id = common::new_bid_id(other_addr, listing_id, 2);
        bid<FakeMoney>(bid_id, obj_addr);
    }

    #[test(lister = @0x123, other = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65540, location = Self)]
    fun test_bid_fail_expired(lister: &signer, other: &signer, framework: &signer)
    acquires ListingRecords {
        setup_test(lister, other, framework);
        let obj = create_test_object(lister);
        let obj_addr = object::object_address(&obj);
        start_listing<ListMe, FakeMoney>(
            lister,
            obj_addr,
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            false,
            1,
            2,
            5
        );
        let lister_addr = signer::address_of(lister);
        let other_addr = signer::address_of(other);
        let listing_id = common::new_listing_id(lister_addr, 0);
        timestamp::update_global_time_for_test(6000_000);
        let bid_id = common::new_bid_id(other_addr, listing_id, 2);
        bid<FakeMoney>(bid_id, obj_addr);
    }

    #[test(lister = @0x123, other = @0x234, framework = @0x1)]
    fun test_bid_twice(lister: &signer, other: &signer, framework: &signer)
    acquires ListingRecords {
        setup_test(lister, other, framework);
        let obj = create_test_object(lister);
        let obj_addr = object::object_address(&obj);
        start_listing<ListMe, FakeMoney>(
            lister,
            obj_addr,
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            false,
            1,
            2,
            5
        );
        let lister_addr = signer::address_of(lister);
        let other_addr = signer::address_of(other);
        let listing_id = common::new_listing_id(lister_addr, 0);
        timestamp::update_global_time_for_test(3000_000);
        let bid_id = common::new_bid_id(other_addr, listing_id, 2);
        bid<FakeMoney>(bid_id, obj_addr);
        let bid_id = common::new_bid_id(other_addr, listing_id, 3);
        bid<FakeMoney>(bid_id, obj_addr);
        let records = borrow_global<ListingRecords<FakeMoney>>(lister_addr);
        let listing = table_with_length::borrow(&records.listing_table, listing_id);
        assert!(vector::length(&listing.bid_prices) == 2, 2);
        assert!(simple_map::contains_key(&listing.bids_map, &3), 3);
    }

    #[test(lister = @0x123, other = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65540, location = Self)]
    fun test_fail_bid_twice_instant_sale(lister: &signer, other: &signer, framework: &signer)
    acquires ListingRecords {
        setup_test(lister, other, framework);
        let obj = create_test_object(lister);
        let obj_addr = object::object_address(&obj);
        start_listing<ListMe, FakeMoney>(
            lister,
            obj_addr,
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            true,
            1,
            2,
            5
        );
        let lister_addr = signer::address_of(lister);
        let other_addr = signer::address_of(other);
        let listing_id = common::new_listing_id(lister_addr, 0);
        timestamp::update_global_time_for_test(3000_000);
        let bid_id = common::new_bid_id(other_addr, listing_id, 1);
        bid<FakeMoney>(bid_id, obj_addr);
        let bid_id = common::new_bid_id(other_addr, listing_id, 2);
        bid<FakeMoney>(bid_id, obj_addr);
    }

    #[test(lister = @0x123, other = @0x234, framework = @0x1)]
    fun test_highest_bid(lister: &signer, other: &signer, framework: &signer)
    acquires ListingRecords {
        setup_test(lister, other, framework);
        let obj = create_test_object(lister);
        let obj_addr = object::object_address(&obj);
        start_listing<ListMe, FakeMoney>(
            lister,
            obj_addr,
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            false,
            1,
            2,
            5
        );
        let lister_addr = signer::address_of(lister);
        let other_addr = signer::address_of(other);
        let listing_id = common::new_listing_id(lister_addr, 0);
        timestamp::update_global_time_for_test(3000_000);
        let bid_id = common::new_bid_id(other_addr, listing_id, 2);
        bid<FakeMoney>(bid_id, obj_addr);
        let bid_id = common::new_bid_id(other_addr, listing_id, 3);
        bid<FakeMoney>(bid_id, obj_addr);
        let records = borrow_global<ListingRecords<FakeMoney>>(lister_addr);
        let listing = table_with_length::borrow(&records.listing_table, listing_id);
        assert!(vector::length(&listing.bid_prices) == 2, 2);
        assert!(simple_map::contains_key(&listing.bids_map, &3), 3);
        let highest_bid = highest_bid<FakeMoney>(&listing_id);
        assert!(highest_bid == bid_id, 4);
    }

    #[test(lister = @0x123, other = @0x234, framework = @0x1)]
    fun test_execute(lister: &signer, other: &signer, framework: &signer)
    acquires ListingRecords {
        setup_test(lister, other, framework);
        create_test_money(lister, other, framework);
        let obj = create_test_object(lister);
        let obj_addr = object::object_address(&obj);
        start_listing<ListMe, FakeMoney>(
            lister,
            obj_addr,
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            false,
            1,
            2,
            5
        );
        let lister_addr = signer::address_of(lister);
        let other_addr = signer::address_of(other);
        let listing_id = common::new_listing_id(lister_addr, 0);
        timestamp::update_global_time_for_test(3000_000);
        let bid_id = common::new_bid_id(other_addr, listing_id, 2);
        bid<FakeMoney>(bid_id, obj_addr);
        let bid_id = common::new_bid_id(other_addr, listing_id, 3);
        bid<FakeMoney>(bid_id, obj_addr);
        let records = borrow_global<ListingRecords<FakeMoney>>(lister_addr);
        let listing = table_with_length::borrow(&records.listing_table, listing_id);
        assert!(vector::length(&listing.bid_prices) == 2, 2);
        assert!(simple_map::contains_key(&listing.bids_map, &3), 3);
        let highest_bid = highest_bid<FakeMoney>(&listing_id);
        assert!(highest_bid == bid_id, 4);
        let coin = coin::withdraw<FakeMoney>(other, 1);
        timestamp::update_global_time_for_test(6000_000);
        execute_listing<ListMe, FakeMoney>(lister, coin, other_addr, &listing_id);
        assert!(object::is_owner(obj, other_addr), 5);
    }

    #[test(lister = @0x123, other = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65540, location = Self)]
    fun test_fail_execute_before_expired(lister: &signer, other: &signer, framework: &signer)
    acquires ListingRecords {
        setup_test(lister, other, framework);
        create_test_money(lister, other, framework);
        let obj = create_test_object(lister);
        let obj_addr = object::object_address(&obj);
        start_listing<ListMe, FakeMoney>(
            lister,
            obj_addr,
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            false,
            1,
            2,
            5
        );
        let lister_addr = signer::address_of(lister);
        let other_addr = signer::address_of(other);
        let listing_id = common::new_listing_id(lister_addr, 0);
        timestamp::update_global_time_for_test(3000_000);
        let bid_id = common::new_bid_id(other_addr, listing_id, 2);
        bid<FakeMoney>(bid_id, obj_addr);
        let bid_id = common::new_bid_id(other_addr, listing_id, 3);
        bid<FakeMoney>(bid_id, obj_addr);
        let coin = coin::withdraw<FakeMoney>(other, 1);
        execute_listing<ListMe, FakeMoney>(lister, coin, other_addr, &listing_id);
    }

    #[test(lister = @0x123, other = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 589832, location = Self)]
    fun test_fail_execute_zero_coin(lister: &signer, other: &signer, framework: &signer)
    acquires ListingRecords {
        setup_test(lister, other, framework);
        create_test_money(lister, other, framework);
        let obj = create_test_object(lister);
        let obj_addr = object::object_address(&obj);
        start_listing<ListMe, FakeMoney>(
            lister,
            obj_addr,
            utf8(b"collection"), utf8(b"name"),
            vector::empty(), vector::empty(), vector::empty(),
            false,
            1,
            2,
            5
        );
        let lister_addr = signer::address_of(lister);
        let other_addr = signer::address_of(other);
        let listing_id = common::new_listing_id(lister_addr, 0);
        let bid_id = common::new_bid_id(other_addr, listing_id, 2);
        timestamp::update_global_time_for_test(3000_000);
        bid<FakeMoney>(bid_id, obj_addr);
        let bid_id = common::new_bid_id(other_addr, listing_id, 3);
        bid<FakeMoney>(bid_id, obj_addr);
        timestamp::update_global_time_for_test(6000_000);
        let coin = coin::withdraw<FakeMoney>(other, 0);
        execute_listing<ListMe, FakeMoney>(lister, coin, other_addr, &listing_id);
    }
}