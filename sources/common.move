module token_objects_marketplace::common {
    use std::error;
    use std::vector;
    use std::string::String;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::coin;
    use aptos_token::property_map::{Self, PropertyMap};
    use aptos_token_objects::token;
    
    const E_TIME_GOES_PAST: u64 = 1;
    const E_NOT_OWNER: u64 = 2;
    const E_INVALID_PRICE: u64 = 3;
    const E_NOT_ADMIN: u64 = 4;
    const E_INCONSISTENT_PROPERTY: u64 = 5;
    const E_INCONSISTENT_NAME: u64 = 6;
    const E_INSUFFICIENT_BLANCE: u64 = 7;
    const E_NOT_FOR_AUCTION: u64 = 8;
    const E_NOT_FOR_INSTANT_SALE: u64 = 9;

    struct BidID has copy, drop, store {
        bidder: address,
        listing_id: ListingID,
        bid_price: u64
    }

    public fun new_bid_id(bidder: address, listing_id: ListingID, bid_price: u64)
    : BidID {
        BidID{
            bidder,
            listing_id,
            bid_price
        }
    }

    public fun empty_bid_id(): BidID {
        BidID{
            bidder: @0x0,
            listing_id: ListingID{
                listing_address: @0x0,
                nonce: 0
            },
            bid_price: 0
        }
    }

    public fun bid_price(bid_id: &BidID): u64 {
        bid_id.bid_price
    }

    public fun bidder(bid_id: &BidID): address {
        bid_id.bidder
    }

    public fun listing_id(bid_id: &BidID): ListingID {
        bid_id.listing_id
    }

    struct ListingID has store, copy, drop {
        listing_address: address,
        nonce: u64
    }

    public fun new_listing_id(listing_address: address, nonce: u64): ListingID {
        ListingID{
            listing_address,
            nonce
        }
    }

    public fun listing_address(listing_id: &ListingID): address {
        listing_id.listing_address
    }

    public fun listing_nonce(listing_id: &ListingID): u64 {
        listing_id.nonce
    }

    struct Fee has store, copy, drop {
        fee_numerator: u64,
        fee_denominator: u64,
        fee_address: address
    }

    public fun new_fee(
        fee_numerator: u64, 
        fee_denominator: u64,
        fee_address: address
    ): Fee {
        Fee{
            fee_numerator,
            fee_denominator,
            fee_address
        }
    }

    public fun calc_fee(
        value: u64,
        fee: &Fee,
    ): u64 {
        if (fee.fee_numerator == 0 || fee.fee_denominator == 0) {
            0
        } else {
            value * fee.fee_numerator / fee.fee_denominator
        }
    }

    public fun fee_address(fee: &Fee): address {
        fee.fee_address
    }

    public fun verify_time(start: u64, end: u64) {
        assert!(start < end, error::invalid_argument(E_TIME_GOES_PAST));
    }

    public fun verify_object_owner<T: key>(obj: Object<T>, owner_addr: address) {
        assert!(
            object::is_owner(obj, owner_addr),
            error::permission_denied(E_NOT_OWNER)
        );
    }

    public fun verify_price(price: u64) {
        assert!(
            0 < price && price < 0xffff_ffff_ffff_ffff,
            error::invalid_argument(E_INVALID_PRICE)
        );
    }

    public fun verify_token<T: key>(
        obj: Object<T>,
        collection_name: String, 
        token_name: String
    ) {
        assert!(
            token::collection(obj) == collection_name &&
            token::name(obj) == token_name,
            error::invalid_argument(E_INCONSISTENT_NAME)
        );
    }

    public fun into_property_map(
        property_name: vector<String>,
        property_value: vector<vector<u8>>,
        property_type: vector<String>,
    ): PropertyMap {
        let len_name = vector::length(&property_name);
        let len_value = vector::length(&property_value);
        let len_type = vector::length(&property_type);  
        assert!(
            len_name ==  len_value && len_value == len_type, 
            error::invalid_argument(E_INCONSISTENT_PROPERTY)
        );

        if (len_name == 0) {
            property_map::empty()
        } else {
            property_map::new(property_name, property_value, property_type)
        }
    }

    public fun check_balance<TCoin>(check_address: address, target_balance: u64) {
        assert!(
            coin::balance<TCoin>(check_address) >= target_balance,
            error::invalid_argument(E_INSUFFICIENT_BLANCE)
        );
    }
}