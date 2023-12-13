module math::wad{
    const WAD: u256 = 1000000000000000000;

    public fun wmul(x: u256, y: u256): u256 {
        (x * y + WAD / 2) / WAD
    }

    public fun floorWmul(x: u256, y: u256): u256 {
        (x * y) / WAD
    }

    public fun ceilWmul(x: u256, y: u256): u256 {
        (x * y + WAD - 1) / WAD
    }

    public fun wdiv(x: u256, y: u256): u256 {
        (x * WAD + y / 2) / y
    }

    public fun floorWdiv(x: u256, y: u256): u256 {
        (x * WAD) / y
    }

    public fun ceilWdiv(x: u256, y: u256): u256 {
        (x * WAD + y - 1) / y
    }

    public fun ceilDiv(x: u256, y: u256): u256 {
        (x + y - 1) / y
    }

    public fun max(x: u256, y: u256): u256 {
        if(x >= y) return x;
        y
    }

    public fun min(x: u256, y: u256): u256 {
        if(x <= y) return x;
        y
    }

    public fun wad(x: u256): u256 {
        x * WAD
    }
}