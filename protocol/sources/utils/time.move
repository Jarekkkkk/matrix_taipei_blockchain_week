module protocol::time{
    use sui::clock::{Self, Clock};

    const MINUTE: u64 = { 60 };
    const HOUR: u64 = { 60 * 60 };
    const WEEK: u64 = { 86400 * 7};
    const DAY: u64 = { 24 * 60 * 60 };


    public fun week():u64 { WEEK }

    public fun hours():u64 { HOUR }

    public fun minutes():u64 { MINUTE }

    public fun days():u64{ DAY }


    public fun get_sec(clock: &Clock):u64{
        clock::timestamp_ms(clock) / 1000
    }
}