module math::ud60x18{
    use math::u256_common;
    use math::wad;

    const E_EXP_INPUT_TOO_BIG: u64 = 1;
    const E_EXP_2_INPUT_TOO_BIG: u64 = 2;
    const E_LOG_INPUT_TOO_SMALL: u64 = 3;

    const EXP_MAX_INPUT: u256 = 133_084258667509499440;
    const EXP2_MAX_INPUT: u256 = 191999999999999999999;
    const UNIT: u256 = 1000000000000000000;
    const LOG2_E: u256 = 1_442695040888963407;
    const UNIT_SQUARED: u256 = 1000000000000000000000000000000000000;


    public fun exp(x: u256): u256{
        if(x > EXP_MAX_INPUT){
            abort E_EXP_INPUT_TOO_BIG
        };
        let double_unit_product = x * LOG2_E;
        exp2(double_unit_product / UNIT)
    }

    public fun exp2(x: u256):u256 {
        if(x > EXP2_MAX_INPUT) abort E_EXP_2_INPUT_TOO_BIG;

        let x_192x64 = ( x << 64 )/ UNIT;
        u256_common::exp2(x_192x64)
    }

    public fun pow(x: u256, y:u256):u256{
        if(x == 0){
            return if(y == 0) UNIT else 0
        }else if(x == UNIT){
            return UNIT
        };

        if(y == 0){
            return UNIT
        }else if (y == UNIT){
            return x
        };

        if( x > UNIT){
            exp2(wad::wmul(log2(x),y))
        }else{
            let i = UNIT_SQUARED / x;
            let w = exp2(wad::wmul(log2(i), y));
            UNIT_SQUARED / w
        }
    }

    public fun log2(x: u256): u256{
        if(x < UNIT) abort E_LOG_INPUT_TOO_SMALL;

        let n = u256_common::msb(x / UNIT);
        let result_unit = (n as u256) * UNIT;
        let y = x >> n;

        if(y == UNIT) return result_unit;

        let double_unit = 2000000000000000000;
        let delta = 500000000000000000;
        while(delta > 0){
            y = ( y * y ) / UNIT;
            if(y >= double_unit){
                result_unit = result_unit + delta;
                y = y >> 1;
            };

            delta = delta >> 1;
        };
        result_unit
    }

    #[test]
    public fun test_exp(){
        assert!(exp(1) == 1000000000000000000, 404);
        assert!(exp(1000) == 1000000000000000999, 404);
        assert!(exp(1000000000000000000) == 2_718281828459045234 ,404);
        assert!(exp(2000000000000000000) == 7_389056098930650223,404);
        assert!(exp(2_718281828459045235) == 15_154262241479264171,404);
        assert!(exp(3000000000000000000) == 20_085536923187667724,404);
        assert!(exp(3_141592653589793238) == 23_140692632779268962,404);
        assert!(exp(4000000000000000000) == 54_598150033144239019,404);
        assert!(exp(11892150000000000000) == 146115_107851442195738190,404);
        assert!(exp(16000000000000000000) == 8886110_520507872601090007,404);
        assert!(exp(20820000000000000000) == 1101567497_354306722521735975,404);
        assert!(exp(33333333000000000000) == 299559147061116_199277615819889397,404);
        assert!(exp(64000000000000000000) == 6235149080811616783682415370_612321304359995711,404);
        assert!(exp(71002000000000000000) == 6851360256686183998595702657852_843771046889809565,404);
        assert!(exp(88722839111672999627) == 340282366920938463222979506443879150094_819893272894857679,404);
        assert!(exp(EXP_MAX_INPUT) == 6277101735386680754977611748738314679353920434623901771623_000000000000000000,404);
    }

    #[test]
    public fun test_pow(){
        assert!(pow(1, 1780000000000000000) == 0,404);
        assert!(pow(10000000000000000, 2_718281828459045235) == 3659622955309, 404);
        assert!(pow(125000000000000000, 3_141592653589793238) == 1454987061394186, 404);
        assert!(pow(250000000000000000, 3 * UNIT) == 15625000000000000,404);
        assert!(pow(450000000000000000, 2200000000000000000) == 172610627076774731,404);
        assert!(pow(500000000000000000, 481000000000000000) == 716480825186549911,404);
        assert!(pow(600000000000000000, 950000000000000000) == 615522152723696171,404);
        assert!(pow(700000000000000000, 3100000000000000000) == 330981655626097448,404);
        assert!(pow(750000000000000000, 4 * UNIT) == 316406250000000008,404);
        assert!(pow(800000000000000000, 5 * UNIT) == 327680000000000015,404);
        assert!(pow(900000000000000000, 2500000000000000000) == 768433471420916193,404);
        assert!(pow(UNIT - 1, 8000000000000000) == UNIT,404);
    }
}