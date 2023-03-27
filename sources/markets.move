module token_objects_marketplace::markets {
    use std::signer;
    use std::error;
    use std::vector;
    use std::string::String;
    use std::option::{Self, Option};
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_std::table_with_length::{Self, TableWithLength};
    use aptos_framework::timestamp;
    use aptos_framework::object;
    use aptos_token_objects::royalty;
    use token_objects_marketplace::listings;
    use token_objects_marketplace::bids;
    use token_objects_marketplace::common::{Self, Fee};

    const E_ALREADY_DISPLAYED: u64 = 1;
    const E_NO_SUCH_MARKET: u64 = 2;
    const E_NOT_DISPLAYED: u64 = 3;
    const E_INVALID_TIME_RANGE: u64 = 4;

    const MIN_EXPIRATION_SEC: u64 = 86400; // a day
    const MAX_EXPIRATION_SEC: u64 = 2592000; // 30 days
    const MAX_WAIT_UNTIL_START: u64 = 2592000; // 30 days
    const MAX_WAIT_UNTIL_EXECUTION: u64 = 86400; // a day

    struct Market has key {
        fee: Option<Fee>,
        listing_address_list: vector<address>,
        catalog_table: TableWithLength<address, Catalog>
    }

    struct Catalog has store {
        key_list: vector<u64>,
        item_map: SimpleMap<u64, Sale>
    }

    struct Sale has store, drop {
        collection_name: String,
        token_name: String,
        receive_direct_objects_offer: bool
    }

    inline fun new_sale(
        collection_name: String, 
        token_name: String,
        receive_direct_objects_offer: bool
    ): Sale {
        Sale{
            collection_name,
            token_name,
            receive_direct_objects_offer
        }
    }

    fun list_to_catalog(
        market_address: address,
        owner_addr: address,
        listing_nonce: u64,
        collection_name: String,
        token_name: String,
        receive_direct_objects_offer: bool
    )
    acquires Market {
        let market = borrow_global_mut<Market>(market_address);
        if (!table_with_length::contains(&market.catalog_table, owner_addr)) {
            table_with_length::add(
                &mut market.catalog_table, 
                owner_addr, 
                Catalog{
                    key_list: vector::empty(),
                    item_map: simple_map::create()
                }
            );
            vector::push_back(&mut market.listing_address_list, owner_addr);
        };

        let catalog = table_with_length::borrow_mut((&mut market.catalog_table), owner_addr);
        assert!(
            !simple_map::contains_key(&catalog.item_map, &listing_nonce), 
            error::already_exists(E_ALREADY_DISPLAYED)
        );
        let sale = new_sale(collection_name, token_name, receive_direct_objects_offer);
        simple_map::add(&mut catalog.item_map, listing_nonce, sale);
        vector::push_back(&mut catalog.key_list, listing_nonce);
    }

    fun remove_from_catalog(
        market_address: address,
        owner_addr: address,
        listing_nonce: u64
    )
    acquires Market {
        let market = borrow_global_mut<Market>(market_address);
        let catalog = table_with_length::borrow_mut(&mut market.catalog_table, owner_addr);
        assert!(
            simple_map::contains_key(&catalog.item_map, &listing_nonce), 
            error::not_found(E_NOT_DISPLAYED)
        );
        let (ok, idx) = vector::index_of(&catalog.key_list, &listing_nonce);
        assert!(ok, error::not_found(E_NOT_DISPLAYED));
        simple_map::remove(&mut catalog.item_map, &listing_nonce);
        vector::remove(&mut catalog.key_list, idx);
    }

    public entry fun create_market(
        host: &signer,
        fee_numerator: u64,
        fee_denominator: u64
    ) {
        let fee = if (fee_numerator == 0 || fee_denominator == 0) {
            option::none()
        } else {
            option::some(common::new_fee(
                fee_numerator, 
                fee_denominator, 
                signer::address_of(host))
            )
        };

        move_to(
            host,
            Market{
                fee,
                listing_address_list: vector::empty(),
                catalog_table: table_with_length::new()
            }
        )
    }

    public entry fun start_listing<T: key, TCoin>(
        owner: &signer,
        market_address: address,
        object_address: address,
        collection_name: String,
        token_name: String,
        property_name: vector<String>,
        property_value: vector<vector<u8>>,
        property_type: vector<String>,
        is_instant_sale: bool,
        min_price: u64,
        start_sec: u64,
        expiration_sec: u64,
        receive_direct_objects_offer: bool
    )
    acquires Market {
        let now = timestamp::now_seconds();
        assert!(
            now <= start_sec && start_sec < now + MAX_WAIT_UNTIL_START,
            error::invalid_argument(E_INVALID_TIME_RANGE)
        );
        assert!(
            start_sec + MIN_EXPIRATION_SEC <= expiration_sec && 
            expiration_sec < start_sec + MAX_EXPIRATION_SEC,
            error::invalid_argument(E_INVALID_TIME_RANGE)
        );

        let listing = listings::start_listing<T, TCoin>(
            owner,
            object_address,
            collection_name,
            token_name,
            property_name,
            property_value,
            property_type,
            is_instant_sale,
            min_price,
            start_sec,
            expiration_sec
        );
        list_to_catalog(
            market_address,
            signer::address_of(owner),
            common::listing_nonce(&listing),
            collection_name,
            token_name,
            receive_direct_objects_offer
        );
    }

    public entry fun bid<T: key, TCoin>(
        bidder: &signer,
        lister: address,
        object_address: address,
        listing_nonce: u64,
        offer_price: u64
    ) {
        let listing_id = listings::into_listing_id<TCoin>(lister, listing_nonce);
        let listing_expiration_sec = listings::expiration_seconds<TCoin>(&listing_id);
        let bid_id = bids::bid<TCoin>(
            bidder,
            listing_id,
            offer_price,
            listing_expiration_sec + MAX_WAIT_UNTIL_EXECUTION
        );
        listings::bid<TCoin>(&bid_id, object_address);
    }

    public entry fun close_listing<T: key, TCoin>(
        lister: &signer,
        market_address: address, 
        listing_nonce: u64
    )
    acquires Market {
        let lister_addr = signer::address_of(lister);
        let listing_id = listings::into_listing_id<TCoin>(lister_addr, listing_nonce);
        let listing_expiration_sec = listings::expiration_seconds<TCoin>(&listing_id);

        let (ok, highest_bid) = listings::highest_bid<TCoin>(&listing_id);
        if (ok && timestamp::now_seconds() < listing_expiration_sec + MAX_WAIT_UNTIL_EXECUTION) {
            let bidder = common::bidder(&highest_bid);
            let obj_addr = listings::object_address<TCoin>(&listing_id);
            let obj = object::address_to_object<T>(obj_addr);
            let royalty = royalty::get(obj);
            let market = borrow_global<Market>(market_address);
            let fee = market.fee;
            let coin = bids::execute_bid<TCoin>(&highest_bid, royalty, fee);
            listings::complete_listing<T, TCoin>(lister, coin, bidder, &listing_id);
            remove_from_catalog(market_address, lister_addr, listing_nonce);
        } else {
            listings::cancel_listing<T, TCoin>(&listing_id);
        }
    }

    #[test_only]
    use std::string::utf8;

    #[test(lister = @0x123, market_host = @0x234)]
    fun test_market(lister: &signer, market_host: &signer)
    acquires Market {
        create_market(market_host, 10, 100);
        let lister_addr = signer::address_of(lister);
        let market_addr = signer::address_of(market_host);
        list_to_catalog(
            market_addr,
            lister_addr,
            0,
            utf8(b"collection"),
            utf8(b"name"),
            false
        );

        {
            let market = borrow_global<Market>(market_addr);
            assert!(vector::length(&market.listing_address_list) == 1, 0);
            assert!(table_with_length::contains(&market.catalog_table, lister_addr), 1);
            let catalog = table_with_length::borrow(&market.catalog_table, lister_addr);
            assert!(vector::length(&catalog.key_list) == 1, 2);
            assert!(simple_map::contains_key(&catalog.item_map, &0), 2);
        };

        remove_from_catalog(
            market_addr,
            lister_addr,
            0
        );

        {
            let market = borrow_global<Market>(market_addr);
            assert!(vector::length(&market.listing_address_list) == 1, 4);
            assert!(table_with_length::contains(&market.catalog_table, lister_addr), 4);
            let catalog = table_with_length::borrow(&market.catalog_table, lister_addr);
            assert!(vector::length(&catalog.key_list) == 0, 5);
            assert!(!simple_map::contains_key(&catalog.item_map, &0), 6);
        };
    }
}