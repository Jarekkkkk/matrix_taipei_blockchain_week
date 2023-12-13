module protocol::position{
    use std::ascii::{Self, String};
    use std::string::utf8;

    use sui::object::{Self, UID};
    use sui::package;
    use sui::object::ID;
    use sui::display;
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::vec_map::{Self, VecMap};

    use protocol::bucket::Lender;

    const ERR_LIQUIDITY_REMAINED: u64 = 101;

    friend protocol::pool;

    struct POSITION has drop {}

    struct Position has key{
        id: UID,
        pool: ID,
        img_url: String,
        positions: VecMap<u64, Lender>
    }

    public fun pool(self: &Position):ID{ self.pool }

    public fun lender(self: &Position, index: &u64):std::option::Option<Lender>{
        vec_map::try_get(&self.positions, index)
    }

    public fun positions(self: &Position):&VecMap<u64, Lender>{&self.positions}

    // [MUT]
    public(friend) fun positions_mut(self: &mut Position):&mut VecMap<u64, Lender>{
        &mut self.positions
    }

    public(friend) fun lender_mut(self: &mut Position, index: &u64):&mut Lender{
        vec_map::get_mut(&mut self.positions, index)
    }

    public fun check_if_remained_liquidity(self: &Position){
        if(vec_map::size(&self.positions) != 0) abort ERR_LIQUIDITY_REMAINED;
    }

    fun init(otw: POSITION, ctx: &mut TxContext){
        // display
        let publisher = package::claim(otw, ctx);
        let keys = vector[
            utf8(b"link"),
            utf8(b"image_url"),
            utf8(b"description"),
            utf8(b"project_url"),
        ];
        let values = vector[
            utf8(b"https://suidoubashi.io/vest"),
            utf8(b"{img_url}"),
            utf8(b"Matrix Position NFT"),
            utf8(b"https://suidoubashi.io"),
        ];
        let display = display::new_with_fields<Position>(&publisher, keys, values, ctx);
        display::update_version(&mut display);

        transfer::public_transfer(publisher, tx_context::sender(ctx));
        transfer::public_transfer(display, tx_context::sender(ctx));
    }

    public (friend) fun new(pool: ID, ctx: &mut TxContext):Position{
        Position{
            id: object::new(ctx),
            img_url: ascii::string(b"ipfs://bafybeiby3hzsai47geyjdcl5istck2k7bsz3yr6cbiotrco52on4rlbq24/166.png"),
            pool,
            positions: vec_map::empty()
        }
    }

    public (friend) fun delete(self: Position){
        check_if_remained_liquidity(&self);
        let Position{
            id,
            pool: _,
            img_url: _,
            positions: _
        } = self;
        object::delete(id);
    }

    public(friend) fun update_position(self: &mut Position, index: u64, lender: Lender){
        if(!vec_map::contains(&self.positions, &index)){
            vec_map::insert(&mut self.positions, index, lender);
        }else{
            *vec_map::get_mut(&mut self.positions, &index) = lender;
        };
    }

    public(friend) fun drop_position(self: &mut Position, index: u64){
        if(vec_map::contains(&self.positions, &index)){
            vec_map::remove(&mut self.positions, &index);
        };
    }

    // TODO: make it private  transfer hooks
    public fun transfer(self: Position, receiver: address){
        transfer::transfer(self, receiver);
    }
}