module math::sd59x18{
    use math::int::{Self, Int};
    use math::u256_common;
    use math::wad;

    // Error
    const E_EXP_2_INPUT_TOO_BIG: u64 = 1;
    const E_EXP_INPUT_TOO_BIG: u64 = 2;
    const E_LOG_INPUT_TOO_SMALL: u64 = 3;
    const E_MUL_INPUT_TOO_SMALL: u64 = 4;
    const E_MUL_OVERFLOW: u64 = 5;
    const E_CEIL_OVERFLOW: u64 = 6;
    const E_DIV_INPUT_TOO_SMALL: u64 = 7;
    const E_DIV_OVERFLOW: u64 = 8;
    const E_SQRT_NEGATIVE_INPUT: u64 = 9;
    const E_SQRT_OVERFLOW: u64 = 10;

    const UNIT: u256 = 1000000000000000000;

    // Constants
    const MAX_SD59x18: u256 = 57896044618658097711785492504343953926634992332820282019728792003956564819967;

    public fun uMIN_SD59x18():Int{
        int::neg_from_u256(MAX_SD59x18)
    }
    public fun uMAX_SD59x18(): Int{
        int::from_u256(57896044618658097711785492504343953926634992332820282019728_792003956564819967)
    }
    public fun uEXP_MAX_INPUT():Int{
        int::from_u256(133_084258667509499440)
    }
    public fun uEXP2_MAX_INPUT():Int {
        int::from_u256(191999999999999999999)
    }
    public fun uMAX_WHOLE_SD59x18():Int {
        int::from_u256(57896044618658097711785492504343953926634992332820282019728_000000000000000000)
    }
    public fun uUNIT_SQUARED():Int {
        int::from_u256(1000000000000000000000000000000000000)
    }
    public fun uNIT():Int {
        // 1e18
        int::from_u256(1000000000000000000)
    }
    public fun uDOUBLE_UNIT():Int {
        int::from_u256(2000000000000000000)
    }
    public fun uHALF_UNIT():Int {
        int::from_u256(500000000000000000)
    }
    public fun uLOG2_E():Int{
        int::from_u256(1_442695040888963407)
    }
    public fun E():Int {
        int::from_u256(2_718281828459045235)
    }
    public fun PI():Int {
        int::from_u256(3_141592653589793238)
    }
    public fun NEGATIVE_PI():Int {
        int::neg_from_u256(3_141592653589793238)
    }

    public fun from_int(x: Int):Int{
        int::mul(&x, &uNIT())
    }

    public fun to_int(x: Int):Int{
        int::div(&x, &uNIT())
    }

    public fun ceil(x: Int):Int {
        if(int::gt(&x, &uMAX_WHOLE_SD59x18())) abort E_CEIL_OVERFLOW;

        let remainder = int::mod(&x, &uNIT());
        if(int::is_zero(&remainder)){
            return x
        }else{
            let result = int::sub(&x, &remainder);
            if(int::gt(&x, &int::zero())){
                result = int::add(&result, &uNIT());
            };
            return result
        }
    }

    public fun exp(x: Int): Int{
        if(int::gt(&x, &uEXP2_MAX_INPUT())){
            abort E_EXP_INPUT_TOO_BIG
        };
        let double_unit_product = int::mul(&x, &uLOG2_E());
        exp2(int::div(&double_unit_product, &uNIT()))
    }

    public fun exp2(x: Int):Int {
        if(!int::is_positive(&x)){
            // if int_x < < -59_794705707972522261
            if(int::lt(&x, &int::neg_from_u128(59_794705707972522261))){
                return int::zero()
            };
            return int::div(&uUNIT_SQUARED(), &exp2(int::flip(&x)))
        }else{
            if(int::gt(&x, &uEXP2_MAX_INPUT())){
                abort E_EXP_2_INPUT_TOO_BIG
            };
            let x_192x64 = int::as_u256(&int::div(&int::shl(&x, 64), &uNIT()));
            return int::from_u256(u256_common::exp2(x_192x64))
        }
    }

    public fun log2(x: Int):Int {
        if(int::lte(&x, &int::zero())) abort E_LOG_INPUT_TOO_SMALL;

        let sign = int::one();
        if(int::lt(&x, &uNIT())){
            sign = int::flip(&sign);
            x = int::div(&uUNIT_SQUARED(), &x);
        };

        let n = u256_common::msb(int::as_u256(&int::div(&x, &uNIT())));
        let result_int = int::mul(&int::from_u8(n), &uNIT());

        let y = int::shr(&x, n);

        if(int::eq(&y, &uNIT())){
            return int::mul(&result_int, &sign)
        };

        let delta = uHALF_UNIT();
        while(int::gt(&delta, &int::zero())){
            y = int::div(&int::mul(&y, &y), &uNIT());

            if(int::gte(&y, &uDOUBLE_UNIT())){
                result_int = int::add(&result_int, &delta);
                y = int::shr(&y, 1);
            };

            delta = int::shr(&delta, 1);
        };
        int::mul(&result_int, &sign)
    }

    public fun mul(x: Int, y: Int): Int{
        if(int::eq(&x, &uMIN_SD59x18()) || int::eq(&y, &uMIN_SD59x18())) abort E_MUL_INPUT_TOO_SMALL;

        let x_abs = int::as_u256(&int::abs(&x));
        let y_abs = int::as_u256(&int::abs(&y));

        let result_abs = wad::wmul(x_abs, y_abs);
        if(result_abs > MAX_SD59x18) abort E_MUL_OVERFLOW;

        let same_sign = int::is_positive(&x) == int::is_positive(&y);
        if(same_sign){
            int::from_u256(result_abs)
        }else{
            int::neg_from_u256(result_abs)
        }
    }

    public fun div(x: Int, y: Int):Int {
        if(int::eq(&x, &uMIN_SD59x18()) || int::eq(&y, &uMIN_SD59x18())) abort E_DIV_INPUT_TOO_SMALL;

        let x_abs = int::as_u256(&int::abs(&x));
        let y_abs = int::as_u256(&int::abs(&y));

        let result_abs = u256_common::mul_div(x_abs, UNIT, y_abs);
        if(result_abs > MAX_SD59x18) abort E_DIV_OVERFLOW;

        let same_sign = int::is_positive(&x) == int::is_positive(&y);
        if(same_sign){
            int::from_u256(result_abs)
        }else{
            int::neg_from_u256(result_abs)
        }
    }

    public fun sqrt(x: Int):Int {
        if(!int::is_positive(&x)) abort E_SQRT_NEGATIVE_INPUT;
        if(int::gt(&x, &int::div(&uMAX_SD59x18(), &uNIT()))) abort E_SQRT_OVERFLOW;

        int::from_u256(u256_common::sqrt(int::as_u256(&x) * UNIT))
    }

    #[test]
    public fun test_exp(){
        assert!(int::eq(&exp(int::one()), &uNIT()), 404);

        assert!(int::eq(&exp(int::zero()), &uNIT()), 404);

        assert!(int::eq(&exp(int::from_u256(1000)), &int::from_u256(1000000000000000999)), 404);

        assert!(int::eq(&exp(uNIT()), &int::from_u256(2_718281828459045234)), 404);

        assert!(int::eq(&exp(int::from_u256(3_141592653589793238)), &int::from_u256(23_140692632779268962)), 404);

        assert!(int::eq(&exp(E()), &int::from_u256(15_154262241479264171)), 404);

        assert!(int::eq(&exp(PI()), &int::from_u256(23_140692632779268962)), 404);

        assert!(int::eq(&exp(int::from_u256(71001999999999991808)), &int::from_u256(6851360256686127875122555825566484766851976856924)), 404);

        assert!(int::eq(&exp(uEXP_MAX_INPUT()), &int::from_u256(6277101735386680754977611748738314679353920434623901771623000000000000000000)), 404);
    }

    #[test]
    #[expected_failure(abort_code = E_LOG_INPUT_TOO_SMALL)]
    public fun test_log2_input_is_zero_fail(){
        log2(int::zero());
    }

    #[test]
    #[expected_failure(abort_code = E_LOG_INPUT_TOO_SMALL)]
    public fun test_log2_input_is_negative_fail(){
        log2(int::neg_from_u8(4));
    }

    #[test]
    public fun test_log2(){
        assert!(int::eq(&log2(int::from_u256(62500000000000000)), &int::neg_from_u256(4000000000000000000)), 404);

        assert!(int::eq(&log2(int::from_u256(125000000000000000)), &int::neg_from_u256(3000000000000000000)), 404);

        assert!(int::eq(&log2(int::from_u256(250000000000000000)), &int::neg_from_u256(2000000000000000000)), 404);

        assert!(int::eq(&log2(int::from_u256(500000000000000000)), &int::neg_from_u256(1000000000000000000)), 404);

        assert!(int::eq(&log2(int::from_u256(1000000000000000000)), &int::from_u256(0)), 404);

        assert!(int::eq(&log2(int::from_u256(2000000000000000000)), &int::from_u256(1000000000000000000)), 404);

        assert!(int::eq(&log2(int::from_u256(4000000000000000000)), &int::from_u256(2000000000000000000)), 404);

        assert!(int::eq(&log2(int::from_u256(8000000000000000000)), &int::from_u256(3000000000000000000)), 404);

        assert!(int::eq(&log2(int::from_u256(16000000000000000000)), &int::from_u256(4000000000000000000)), 404);

        assert!(int::eq(&log2(int::from_u256(50216813883093446110686315385661331328818843555712276103168000000000000000000)), &int::from_u256(195000000000000000000)), 404);
    }

    #[test]
    public fun test_mul(){
        let unit = 1000000000000000000;

        assert!(int::eq(&mul(int::from_u256(5 * unit), int::from_u256(2 * unit)), &int::from_u256(10 * unit)), 404);
        assert!(int::eq(&mul(int::neg_from_u256(5 * unit), int::from_u256(2 * unit)), &int::neg_from_u256(10 * unit)), 404);
        assert!(int::eq(&mul(int::neg_from_u256(5 * unit), int::neg_from_u256(2 * unit)), &int::from_u256(10 * unit)), 404);
    }

    #[test]
    public fun test_div(){
        assert!(int::eq(&div(int::from_u256(0), NEGATIVE_PI()), &int::zero()), 404);
        assert!(int::eq(&div(int::zero(), int::neg_from_u256(1000000000000000000000000)), &int::zero()), 404);
        assert!(int::eq(&div(int::zero(), int::neg_from_u256(1000000000000000000)), &int::zero()), 404);
        assert!(int::eq(&div(int::zero(), uNIT()), &int::zero()), 404);
        assert!(int::eq(&div(int::zero(), PI()), &int::zero()), 404);
        assert!(int::eq(&div(int::zero(), int::from_u256(1000000000000000000000000000000)), &int::zero()), 404);

        assert!(int::eq(&div(int::neg_from_u256(1000000000000000000000000), int::neg_from_u256(1000000000000000000)), &int::from_u256(1000000000000000000000000)), 404);
        assert!(int::eq(&div(int::neg_from_u256(2503000000000000000000), int::neg_from_u256(918882110000000040697856)), &int::from_u256(2723962054283546)), 404);
        assert!(int::eq(&div(int::neg_from_u256(100135000000000000000), int::neg_from_u256(100134000000000000000)), &int::from_u256(1_000009986617931971)), 404);
        assert!(int::eq(&div(int::neg_from_u256(22000000000000000000), int::neg_from_u256(7000000000000000000)), &int::from_u256(3_142857142857142857)), 404);
        assert!(int::eq(&div(int::neg_from_u256(4000000000000000000), int::neg_from_u256(2000000000000000000)), &int::from_u256(2000000000000000000)), 404);
        assert!(int::eq(&div(int::neg_from_u256(2000000000000000000), int::neg_from_u256(5000000000000000000)), &int::from_u256(400000000000000000)), 404);
        assert!(int::eq(&div(int::neg_from_u256(2000000000000000000), int::neg_from_u256(2000000000000000000)), &int::from_u256(1000000000000000000)), 404);
        assert!(int::eq(&div(int::neg_from_u256(100000000000000000), int::neg_from_u256(10000000000000000)), &int::from_u256(10000000000000000000)), 404);
        assert!(int::eq(&div(int::neg_from_u256(50000000000000000), int::neg_from_u256(20000000000000000)), &int::from_u256(2500000000000000000)), 404);
        assert!(int::eq(&div(int::neg_from_u256(10000000000000), int::neg_from_u256(20000000000000)), &int::from_u256(500000000000000000)), 404);

        assert!(int::eq(&div(int::neg_from_u256(1), int::neg_from_u256(UNIT)), &int::from_u256(1)), 404);
        assert!(int::eq(&div(int::neg_from_u256(1), int::neg_from_u256(1000000000000000001)), &int::from_u256(0)), 404);
        assert!(int::eq(&div(int::from_u256(1), int::from_u256(MAX_SD59x18)), &int::from_u256(0)), 404);
        assert!(int::eq(&div(int::neg_from_u256(10000000000000), int::neg_from_u256(10000000000000)), &int::from_u256(1000000000000000000)), 404);
        assert!(int::eq(&div(int::from_u256(10000000000000), int::from_u256(20000000000000)), &int::from_u256(500000000000000000)), 404);
        assert!(int::eq(&div(int::from_u256(50000000000000000), int::from_u256(20000000000000000)), &int::from_u256(2500000000000000000)), 404);

        assert!(int::eq(&div(int::from_u256(22000000000000000000), int::from_u256(7000000000000000000)), &int::from_u256(3_142857142857142857)), 404);

        assert!(int::eq(&div(int::from_u256(100135000000000000000), int::from_u256(100134000000000000000)), &int::from_u256(1_000009986617931971)), 404);
        assert!(int::eq(&div(int::from_u256(772050000000000000000), int::from_u256(199980000000000000000)), &int::from_u256(3_860636063606360636)), 404);
        assert!(int::eq(&div(int::from_u256(2503000000000000000000), int::from_u256(918882110000000000000000)), &int::from_u256(2723962054283546)), 404);
        assert!(int::eq(&div(int::from_u256(1000000000000000000000000), int::from_u256(1000000000000000000)), &int::from_u256(1000000000000000000000000)), 404);
    }

     #[test]
    public fun test_sqrt(){
        assert!(int::eq(&sqrt(int::from_u256(1)), &int::from_u256(1000000000)), 404);
        assert!(int::eq(&sqrt(int::from_u256(1000)), &int::from_u256(31622776601)), 404);
        assert!(int::eq(&sqrt(int::from_u256(UNIT)), &int::from_u256(UNIT)), 404);
        assert!(int::eq(&sqrt(int::from_u256(2 * UNIT)), &int::from_u256(1_414213562373095048)), 404);
        assert!(int::eq(&sqrt(E()), &int::from_u256(1_648721270700128146)), 404);
        assert!(int::eq(&sqrt(int::from_u256(3 * UNIT)), &int::from_u256(1_732050807568877293)), 404);
        assert!(int::eq(&sqrt(PI()), &int::from_u256(1_772453850905516027)), 404);
        assert!(int::eq(&sqrt(int::from_u256(4 * UNIT)), &int::from_u256(2 * UNIT)), 404);
        assert!(int::eq(&sqrt(int::from_u256(16 * UNIT)), &int::from_u256(4 * UNIT)), 404);
        assert!(int::eq(&sqrt(int::from_u256(100000000000000000000000000000000000)), &int::from_u256(316227766_016837933199889354)), 404);
        assert!(int::eq(&sqrt(int::from_u256(12489131238983290393813_123784889921092801)), &int::from_u256(111754781727_598977910452220959)), 404);
        assert!(int::eq(&sqrt(int::from_u256(1889920002192904839344128288891377_732371920009212883)), &int::from_u256(43473210166640613973238162807779776)), 404);

        assert!(int::eq(&sqrt(int::from_u256(10000000000000000000000000000000000000000000000000000000000)), &int::from_u256(100000000000000000000000000000000000000)), 404);
        assert!(int::eq(&sqrt(int::from_u256(50000000000000000000000000000000000000000000000000000000000)), &int::from_u256(223606797749978969640_917366873127623544)), 404);
        assert!(int::eq(&sqrt(int::from_u256(57896044618658097711785492504343953926634992332820282019728)), &int::from_u256(240615969168004511545_033772477625056927)), 404);
    }
}