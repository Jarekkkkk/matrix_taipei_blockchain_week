module protocol::auction{
    use sui::table::{Self, Table};
    use sui::clock::Clock;
    use sui::tx_context::TxContext;
    use sui::vec_map::{Self, VecMap};

    use protocol::bucket::{Self, Lender};

    use protocol::helpers;

    friend protocol::pool;
    friend protocol::kicker;

    const ERR_NOT_AUCTION: u64 = 100;
    const ERR_AUCTION_NOT_TAKEABLE: u64 = 101;
    const ERR_INSUFFICIENT_LIQUIDITY: u64 = 102;
    const ERR_AUCTION_PRICE_GT_BUCKET_PRICE: u64 = 103;
    const ERR_INVALID_AMOUNT: u64 = 104;

    struct AuctionState has store{
        // total number of auctions in pool
        num_of_auctions: u64,
        // first address in auction queue
        head: address,
        // last address in auction queue
        tail: address,
        // total amount of quote token posted as auction kick bonds
        total_bond_escrowed: u256,
        liquidations: Table<address, Liquidation>,
        kickers: Table<address, Kicker>
    }
    public (friend) fun default_auction_state(ctx: &mut TxContext):AuctionState{
        AuctionState{
            num_of_auctions: 0,
            head: @0x00,
            tail: @0x00,
            total_bond_escrowed: 0,
            liquidations: table::new<address, Liquidation>(ctx),
            kickers: table::new<address, Kicker>(ctx)
        }
    }
    // [ VIEW ]
    public fun num_of_auctions(self: &AuctionState): u64{
        self.num_of_auctions
    }
    public fun head(self: &AuctionState): address{
        self.head
    }
    public fun tail(self: &AuctionState): address{
        self.tail
    }
    public fun total_bond_escrowed(self: &AuctionState): u256{
        self.total_bond_escrowed
    }
    public fun liquidations(self: &AuctionState): &Table<address, Liquidation>{
        &self.liquidations
    }
    public fun kickers(self: &AuctionState): &Table<address, Kicker>{
        &self.kickers
    }
    // [ MUT ]
    public (friend) fun add_num_of_auctions(self: &mut AuctionState){
        self.num_of_auctions = self.num_of_auctions + 1;
    }
    public (friend) fun add_total_bond_escrowed(self: &mut AuctionState, value: u256){
        self.total_bond_escrowed = self.total_bond_escrowed + value;
    }
    public (friend) fun update_head(self: &mut AuctionState, head: address){
        self.head = head;
    }
    public (friend) fun update_tail(self: &mut AuctionState, tail: address){
        self.tail = tail;
    }
    public (friend) fun remove_total_bond_escrowed(self: &mut AuctionState, value: u256){
        self.total_bond_escrowed = self.total_bond_escrowed - value;
    }
    public (friend) fun kickers_mut(self: &mut AuctionState): &mut Table<address, Kicker>{
        &mut self.kickers
    }
    public (friend) fun liquidations_mut(self: &mut AuctionState): &mut Table<address, Liquidation>{
        &mut self.liquidations
    }

    // Liquidation
    struct Liquidation has store, drop{
        // address that initiated liquidation
        kicker: address,
        // [WAD] bond factor used to start liquidation
        bond_factor: u256,
        // timestamp when liquidation was started
        kick_time: u64,
        // previous liquidated borrower in auctions queue
        prev: address,
        // [WAD] used to calculate auction start price
        reference_price: u256,
        // next liquidated borrower in auctions queue
        next: address,
        // [WAD] liquidation bond size
        bond_size: u256,
        // [WAD] Neutral Price when liquidation was started
        neutral_price: u256
    }
    public (friend) fun default_liquidation():Liquidation{
        Liquidation{
            kicker: @0x00,
            bond_factor: 0,
            kick_time: 0,
            prev: @0x00,
            reference_price: 0,
            next: @0x00,
            bond_size: 0,
            neutral_price: 0
        }
    }
    public fun liquidation_info(liquidation: &Liquidation)
    :(address, u256, u64, address, u256, address, u256, u256){
        (liquidation.kicker, liquidation.bond_factor, liquidation.kick_time, liquidation.prev, liquidation.reference_price, liquidation.next, liquidation.bond_size, liquidation.neutral_price)
    }
    public fun liquidation(self: &AuctionState, borrower: address): &Liquidation{
        table::borrow(&self.liquidations, borrower)
    }
    public fun liquidation_kicker(liquidation: &Liquidation):address{
        liquidation.kicker
    }
    public fun bond_factor(liquidation: &Liquidation):u256{
        liquidation.bond_factor
    }
    public fun kick_time(liquidation: &Liquidation):u64{
        liquidation.kick_time
    }
    public fun prev(liquidation: &Liquidation):address{
        liquidation.prev
    }
    public fun reference_price(liquidation: &Liquidation):u256{
        liquidation.reference_price
    }
    public fun next(liquidation: &Liquidation):address{
        liquidation.next
    }
    public fun bond_size(liquidation: &Liquidation):u256{
        liquidation.bond_size
    }
    public fun neutral_price(liquidation: &Liquidation):u256{
        liquidation.neutral_price
    }
    public fun auction_price(self: &AuctionState, borrower: address, clock: &Clock):u256{
        let liquidation = liquidation(self, borrower);
        helpers::auction_price(liquidation.reference_price, liquidation.kick_time, clock)
    }
    // [ MUT]
    public(friend) fun liquidation_mut(self: &mut AuctionState, borrower: address): &mut Liquidation{
        table::borrow_mut(&mut self.liquidations, borrower)
    }
    public (friend) fun update_kicker_address(liquidation: &mut Liquidation, kicker: address){
        liquidation.kicker = kicker;
    }
    public (friend) fun update_bond_factor(liquidation: &mut Liquidation, bond_factor: u256){
        liquidation.bond_factor = bond_factor;
    }
    public (friend) fun update_kick_time(liquidation: &mut Liquidation, kick_time: u64){
        liquidation.kick_time = kick_time;
    }
    public (friend) fun update_prev(liquidation: &mut Liquidation, prev: address){
        liquidation.prev = prev;
    }
    public (friend) fun update_reference_price(liquidation: &mut Liquidation, reference_price: u256){
        liquidation.reference_price = reference_price;
    }
    public (friend) fun update_next(liquidation: &mut Liquidation, next: address){
        liquidation.next = next;
    }
    public (friend) fun add_bond_size(liquidation: &mut Liquidation, bond_size: u256){
        liquidation.bond_size = liquidation.bond_size + bond_size;
    }
    public (friend) fun remove_bond_size(liquidation: &mut Liquidation, bond_size: u256){
        liquidation.bond_size = liquidation.bond_size - bond_size;
    }
    public (friend) fun update_bond_size(liquidation: &mut Liquidation, bond_size: u256){
        liquidation.bond_size = bond_size;
    }
    public (friend) fun update_neutral_price(liquidation: &mut Liquidation, neutral_price: u256){
        liquidation.neutral_price = neutral_price;
    }

    struct Kicker has store{
        // [WAD] kicker's claimable balance
        claimable: u256,
        // [WAD] kicker's balance of tokens locked in auction bonds
        locked: u256,
        // kicker is awarded bond change worth of LPB in the bucket
        lenders: VecMap<u64, Lender>
    }
    public (friend) fun default_kicker():Kicker{
        Kicker{
            claimable: 0,
            locked: 0,
            lenders: vec_map::empty()
        }
    }
    public fun kicker(self: &AuctionState, kicker: address): &Kicker{
        table::borrow(&self.kickers, kicker)
    }
    public fun claimable(kicker: &Kicker):u256{
        kicker.claimable
    }
    public fun locked(kicker: &Kicker):u256{
        kicker.locked
    }
    public fun kicker_lender(kicker: &Kicker, index: u64):(u256, u64){
        let lender = vec_map::get(&kicker.lenders, &index);
        (bucket::lender_lps(lender), bucket::lender_deposit_time(lender))
    }
    // [MUT]
    public (friend) fun kicker_mut(self: &mut AuctionState, kicker: address): &mut Kicker{
        table::borrow_mut(&mut self.kickers, kicker)
    }
    public (friend) fun add_claimable(kicker: &mut Kicker, value: u256){
        kicker.claimable = kicker.claimable + value;
    }
    public (friend) fun remove_claimable(kicker: &mut Kicker, value: u256){
        kicker.claimable = kicker.claimable - value;
    }
    public (friend) fun update_claimable(kicker: &mut Kicker, value: u256){
        kicker.claimable = value;
    }
    public (friend) fun add_locked(kicker: &mut Kicker, value: u256){
        kicker.locked = kicker.locked + value;
    }
    public (friend) fun remove_locked(kicker: &mut Kicker, value: u256){
        kicker.locked = kicker.locked - value;
    }
    public (friend) fun drop_lenders(kicker: &mut Kicker):(vector<u64>, vector<Lender>){
        let (indexes, lenders ) = vec_map::into_keys_values(kicker.lenders);
        kicker.lenders = vec_map::empty<u64, Lender>();

        (indexes, lenders)
    }
    public (friend) fun add_kicker_lps(
        kicker: &mut Kicker,
        index: u64,
        value: u256,
        bankruptcy_time: u64,
        clock: &Clock
    ){
        if(!vec_map::contains(&kicker.lenders, &index)){
            vec_map::insert(&mut kicker.lenders, index, bucket::default_lender());
        };
        bucket::add_lender_lp(vec_map::get_mut(&mut kicker.lenders, &index), bankruptcy_time, value, clock);
    }

    struct BucketTakeParams has drop{
        borrower: address,
        deposit_take: bool,
        index: u64,
        inflator: u256,
        collateral_scale: u256
    }

    public (friend) fun new_bucket_take_params(
        borrower: address,
        deposit_take: bool,
        index: u64,
        inflator: u256,
        collateral_scale: u256
    ):BucketTakeParams{
        BucketTakeParams{
            borrower,
            deposit_take,
            index,
            inflator,
            collateral_scale
        }
    }

    public(friend) fun remove_auction(
        auction_state: &mut AuctionState,
        borrower_address: address
    ){
        let (prev, next) = {
            let liquidation = table::borrow(&auction_state.liquidations, borrower_address);
            let kicker = table::borrow_mut(&mut auction_state.kickers, liquidation_kicker(liquidation));

            kicker.locked = kicker.locked - liquidation.bond_size;
            kicker.claimable = kicker.claimable + liquidation.bond_size;

            auction_state.num_of_auctions = auction_state.num_of_auctions - 1;
            ( liquidation.prev, liquidation.next )
        };

        // update auctions queue
        if (auction_state.head == borrower_address && auction_state.tail == borrower_address) {
            // liquidation is the head and tail
            auction_state.head = @0x00;
            auction_state.tail = @0x00;
        }
        else if(auction_state.head == borrower_address) {
            // liquidation is the head
            table::borrow_mut(&mut auction_state.liquidations, next).prev == @0x00;
            auction_state.head = next;
        }
        else if(auction_state.tail == borrower_address) {
            // liquidation is the tail
            liquidation_mut(auction_state, prev).next = @0x00;
            auction_state.tail = prev;
        }
        else {
            // liquidation is in the middle
            liquidation_mut(auction_state, prev).next = next;
            liquidation_mut(auction_state, next).prev = prev;
        };
        // delete liquidation
        table::remove(&mut auction_state.liquidations, borrower_address);
    }

    public fun in_auction(auction_state: &AuctionState, borrower: address):bool{
        if(table::contains(liquidations(auction_state), borrower)) kick_time(liquidation(auction_state, borrower)) != 0 else false
    }

}