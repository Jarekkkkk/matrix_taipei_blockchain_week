module protocol::constants{
    use math::int::{Self, Int};

    const MAX_FENWICK_INDEX:u64 =  7_388;

    // min price that bucket index stay at '-3232'
    const MIN_PRICE: u256 = 99_836_282_890;
    // max price that bucket index stay at '4156'
    const MAX_PRICE: u256 = 1_004_968_987__606512354182109771;

    public fun UINT_MAX():u256 { 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff }

    public fun max_fenwick_index():u64 { MAX_FENWICK_INDEX }

    public fun min_price():u256 { MIN_PRICE }

    public fun max_price():u256 { MAX_PRICE }

    public fun UNIT():u256 { 1_000_000_000_000_000_000 }

    /// -ln(2)/12
    public fun NEG_H_MAU_HOURS():Int{
        int::neg_from_u256(57_762_265_046_662_105)
    }

    /// -ln(2)/84
    public fun NEG_H_TU_HOURS():Int{
        int::neg_from_u256(8_251_752_149_523_158)
    }

    public fun PERCENT_102():Int{
        int::from_u256(1_020_000_000_000_000_000)
    }

    public fun DECREASE_COEFFICIENT(): u256{
        900_000_000_000_000_000
    }

    public fun INCREASE_COEFFICIENT(): u256{
        1_100_000_000_000_000_000
    }
}