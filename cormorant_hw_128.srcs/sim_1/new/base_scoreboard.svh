// base_scoreboard.svh — shared test counters and summary for all kernel scoreboards.
virtual class base_scoreboard;
    int unsigned total_tests = 0;
    int unsigned pass_cnt    = 0;
    int unsigned fail_cnt    = 0;

    pure virtual function string kernel_name();

    task print_summary();
        $display("==========================================================");
        $display(" %s Test Summary: %0d / %0d passed",
                 kernel_name(), pass_cnt, total_tests);
        if (fail_cnt == 0)
            $display(" ALL TESTS PASSED");
        else
            $display(" %0d TEST(S) FAILED", fail_cnt);
        $display("==========================================================");
    endtask
endclass
