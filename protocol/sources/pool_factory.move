module protocol::pool_factory{
    use std::vector;
    use std::option;
    use std::type_name::{Self, get, borrow_string};
    use std::bcs;
    use std::string::{Self, String};
    use sui::object::UID;
    use sui::table::{Self, Table};
    use sui::coin;
    use sui::tx_context::{Self,TxContext};
    use sui::object;
    use sui::coin::CoinMetadata;
    use sui::transfer;

    use protocol::event;
    use protocol::pool;

    // Error
    const ERR_INVALD_INTEREST_RATE: u64 = 0;
    const ERR_INVALID_DECIMALS: u64 = 1;
    const ERR_INVALD_TYPE: u64 = 1;

    // Constant
     ///  Min interest rate value allowed for deploying the pool (1%), 0.01 * 1e18
    const MIN_RATE: u256 = 10_000_000_000_000_000;
     ///  Max interest rate value allowed for deploying the pool (10%), 0.1 * 1e18
    const MAX_RATE: u256 = 100_000_000_000_000_000;

    struct PoolCap has key { id: UID }

    struct PoolReg has key {
        id: UID,
        pools: Table<vector<u8>, address>
    }

    fun assert_interest_rate(i_rate: u256){
       assert!(i_rate <= MAX_RATE && i_rate >= MIN_RATE, ERR_INVALD_INTEREST_RATE);
    }

    fun get_token_scale_<X>(metadata: &CoinMetadata<X>):u256{
        let decimals = coin::get_decimals(metadata);
        if(decimals > 9) abort(ERR_INVALID_DECIMALS);
        (sui::math::pow(10, 18 - decimals) as u256)
    }

    // ===== entry =====
    fun init(ctx:&mut TxContext){
        let pool_gov = PoolReg{
            id: object::new(ctx),
            pools: table::new<vector<u8>, address>(ctx)
        };
        transfer::share_object(
            pool_gov
        );
        transfer::transfer(
            PoolCap{
                id: object::new(ctx)
            },
            tx_context::sender(ctx)
        );
    }

    public entry fun create_token_pool<Quote: drop, Collateral: drop>(
        self: &mut PoolReg,
        quote_mata: &CoinMetadata<Quote>,
        collateral_meta: &CoinMetadata<Collateral>,
        i_rate: u256,
        ctx: &mut TxContext
    ){
        assert_interest_rate(i_rate);
        let quote_type = get<Quote>();
        let collateral_type = get<Collateral>();
        assert!(quote_type != collateral_type, ERR_INVALD_TYPE);

        let quote_scale = get_token_scale_(quote_mata);
        let collateral_scale = get_token_scale_(collateral_meta);

        let hash = bcs::to_bytes(borrow_string(&quote_type));
        vector::append(&mut hash, bcs::to_bytes(borrow_string(&collateral_type)));
        hash = std::hash::sha2_256(hash);

        let name = string::from_ascii(coin::get_symbol(quote_mata));
        let symbol_collateral = string::from_ascii(coin::get_symbol(collateral_meta));
        string::append(&mut name, string::utf8(b"-"));
        string::append(&mut name, symbol_collateral);

        let pool_id = pool::new<Quote, Collateral>(name, quote_scale, option::some(collateral_scale), i_rate, ctx);

        table::add(&mut self.pools, hash, pool_id);
        event::pool_created<Quote, Collateral>(pool_id, tx_context::sender(ctx))
    }
    public entry fun create_nft_pool<Quote: drop, NFT: key + store>(
        self: &mut PoolReg,
        quote_meta: &CoinMetadata<Quote>,
        i_rate: u256,
        ctx: &mut TxContext
    ){
        assert_interest_rate(i_rate);
        let quote_type = get<Quote>();
        let collateral_type = get<NFT>();
        assert!(quote_type != collateral_type, ERR_INVALD_TYPE);

        let quote_scale = get_token_scale_(quote_meta);

        let hash = bcs::to_bytes(borrow_string(&quote_type));
        vector::append(&mut hash, bcs::to_bytes(borrow_string(&collateral_type)));
        hash = std::hash::sha2_256(hash);

        let name = string::from_ascii(coin::get_symbol(quote_meta));
        let (_, _, symbol_collateral) = get_package_module_type<NFT>();
        string::append(&mut name, string::utf8(b"-"));
        string::append(&mut name, symbol_collateral);

        let pool_id = pool::new<Quote, NFT>(name, quote_scale, option::none<u256>(), i_rate, ctx);

        table::add(&mut self.pools, hash, pool_id);
        event::pool_created<Quote, NFT>(pool_id, tx_context::sender(ctx))
    }

    fun get_package_module_type<T>(): (String, String, String) {
        let t = string::utf8(std::ascii::into_bytes(
            type_name::into_string(type_name::get<T>())
        ));
        let delimiter = string::utf8(b"::");

        let package_delimiter_index = string::index_of(&t, &delimiter);
        let package_addr = string::sub_string(&t, 0, 64);

        let tail = string::sub_string(&t, package_delimiter_index + 2, string::length(&t));

        let module_delimiter_index = string::index_of(&tail, &delimiter);
        let module_name = string::sub_string(&tail, 0, module_delimiter_index);

        let type_name = string::sub_string(&tail, module_delimiter_index + 2, string::length(&tail));

        (package_addr, module_name, type_name)
    }

    public fun pools_length(self: &PoolReg):u64{ table::length(&self.pools) }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx)
    }
}