// axil_agent.svh — shared AXI-Lite read/write base for all drivers and monitors.
virtual class axil_agent;
    protected string tag;

    function new(string t = "AGENT");
        this.tag = t;
    endfunction

    protected task axil_write(input [39:0] addr, input [31:0] data);
        logic [1:0] rsp;
        `PS.write_data(addr, 4, {{(2048-32){1'b0}}, data}, rsp);
        if (rsp !== 2'b00)
            $error("[%0t][%s] AXI-Lite write FAILED  addr=0x%010h  rsp=%0b",
                   $time, tag, addr, rsp);
    endtask

    protected task axil_read(input [39:0] addr, output [31:0] data);
        logic [127:0] rd_raw;
        logic [1:0]   rsp;
        `PS.read_data(addr, 4, rd_raw, rsp);
        data = rd_raw[31:0];
        if (rsp !== 2'b00)
            $error("[%0t][%s] AXI-Lite read FAILED  addr=0x%010h  rsp=%0b",
                   $time, tag, addr, rsp);
    endtask
endclass
