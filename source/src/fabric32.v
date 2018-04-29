module fabric32(
        input   wire    clk,
        input   wire    arst_n,

        // registers
        // control register
        // [31] run
        // [30] load
        // ...
        // [9:5] start_y
        // [4:0] start_x
        input   wire            ctrl_wr,
        input   wire    [31:0]  ctrl_in,
        output  wire    [31:0]  ctrl_out,

        // memory interface
        input                   data_rdy,
        input   wire    [31:0]  data_rd,
        output  wire    [31:0]  data_wr,

        output  wire    [31:0]  addr_rd,
        output  wire    [31:0]  addr_wr,

        output  wire    req_rd,
        output  wire    req_wr,

        // interrupts
        output  wire    int_load,
        output  wire    int_done
    );
    // params
    localparam ADDR_MAP = 32'h40000000;
    localparam ADDR_DIR = 32'h40002000;

    // states
    localparam ST_IDLE          = 0;
    localparam ST_FIRST_LOAD    = 1;
    localparam ST_W_FIRST_LOAD  = 2;
    localparam ST_LOAD_WEIGHT   = 3;
    localparam ST_W_LOAD        = 4;

    // visble registers
    reg [4:0] reg_start_x;
    reg [4:0] reg_start_y;
    reg reg_load;
    reg reg_run;
    assign ctrl_out = {reg_run, reg_load, 20'd0, reg_start_y, reg_start_x};

    reg rst_n;
    wire rst; assign rst = !rst_n;

    // fabric variables
    reg clr[0:1023];
    reg ld[0:1023];
    reg [3:0] ld_weight;
    wire mod[0:1023];
    wire [11:0] cost[0:1023];
    wire [2:0] dir[0:1023];

    reg [3:0] cs;
    reg [3:0] ns;

    // internal registers
    reg [4:0] curr_x, curr_y;     // current coordinates, for writing and reading
    reg [9:0] curr;         // current node
    reg [6:0] addr_off;     // word address offset
    reg [31:0] data_word;   // data word to read/pass

    assign addr_rd = ADDR_MAP + (addr_off << 2);
    assign addr_wr = ADDR_DIR + (addr_off << 2);

    // SM outputs
    reg o_rst_n;            // enables running: works in the run states
    reg o_clr_curr;         // clear the curr register
    reg o_clr_addr_off;     // clear the addr_off register
    reg o_init_rd; assign req_rd = o_init_rd; // initialize a read
    reg o_inc_addr_off;     // increment the word addr offset
    reg o_sv_word;          // save the data word from a read request
    reg o_ld_weight;        // load the weight in the node pointed by curr
    reg o_inc_curr;         // increment the curr register
    reg o_clr_load_map;     // clear the load map register

    // SM qualifiers
    wire q_load_map; assign q_load_map = reg_load;
    wire q_run; assign q_load_map = reg_run;
    wire q_data_done; assign q_data_done = data_rdy;
    wire q_curr_0; assign q_curr_0 = (curr == 0);
    wire q_curr_mod8_last; assign q_curr_mod8_last = (curr[2:0] == 3'b111);

    // state combinational logic
    integer i;
    always @(*) begin
        ns = cs;
        o_rst_n = 0;
        o_clr_curr = 0;
        o_clr_addr_off = 0;
        o_init_rd = 0;
        o_inc_addr_off = 0;
        o_sv_word = 0;
        o_ld_weight = 0;
        o_inc_curr = 0;
        o_clr_load_map = 0;

        // state logic
        case (cs)

        ST_IDLE: begin
            if (q_load_map) begin
                o_clr_curr = 1;
                o_clr_addr_off = 1;
                ns = ST_FIRST_LOAD;
            end
            else if (q_run) begin
                ns = ST_IDLE;   // TODO
            end
        end

        ST_FIRST_LOAD: begin
            o_init_rd = 1;
            o_inc_addr_off = 1;
            ns = ST_W_FIRST_LOAD;
        end

        ST_W_FIRST_LOAD: begin
            ns = ST_W_FIRST_LOAD;
            if (q_data_done) begin
                ns = ST_LOAD_WEIGHT;
                o_sv_word = 1;
                o_init_rd = 1;
            end
        end

        ST_LOAD_WEIGHT: begin
            o_ld_weight = 1;
            o_inc_curr = 1;
            if (q_curr_mod8_last) begin
                ns = ST_W_LOAD;
                o_inc_addr_off = 1;
            end
            else ns = ST_LOAD_WEIGHT;
        end

        ST_W_LOAD: begin
            if (!q_data_done) begin
                ns = ST_W_LOAD;
            end
            else if (!q_curr_0) begin
                ns = ST_LOAD_WEIGHT;
                o_sv_word = 1;
                o_init_rd = 1;
            end
            else begin
                ns = ST_IDLE;
                o_clr_load_map = 1;
            end
        end

        endcase
    end

    // other combination signals
    always @(*) begin
        // default ld and clr signals
        for (i = 0; i < 1024; i = i + 1) begin
            ld[i] = 0;
            clr[i] = 0;
        end
        if (o_ld_weight) ld[curr] = 1;
        if (reg_run) clr[reg_start_x + (reg_start_y << 5)] = 1;
        case (curr[2:0])
        0: ld_weight = data_word[3:0];
        1: ld_weight = data_word[7:4];
        2: ld_weight = data_word[11:8];
        3: ld_weight = data_word[15:12];
        4: ld_weight = data_word[19:16];
        5: ld_weight = data_word[23:20];
        6: ld_weight = data_word[27:24];
        7: ld_weight = data_word[31:28];
        endcase
    end

    // sequential logic
    initial begin
        cs <= ST_IDLE;
        reg_start_x <= 0;
        reg_start_y <= 0;
        reg_load <= 0;
        reg_run <= 0;
    end

    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            cs <= ST_IDLE;
            reg_start_x <= 0;
            reg_start_y <= 0;
            reg_load <= 0;
            reg_run <= 0;
        end else begin
            // load the control register if not running
            if (ctrl_wr) begin
                if (!reg_run || !ctrl_in[31]) begin
                    reg_run  <= ctrl_in[31];
                    reg_load <= ctrl_in[30];
                    reg_start_y <= ctrl_in[9:5];
                    reg_start_x <= ctrl_in[4:0];
                end
            end
            cs <= ns;

            if (o_clr_curr) begin
                curr_x <= 0; curr_y <= 0;
                curr <= 0;
            end
            if (o_clr_addr_off) begin
                addr_off <= 0;
            end
            if (o_inc_addr_off) begin
                addr_off <= addr_off + 1;
            end
            if (o_sv_word) begin
                data_word <= data_rd;
            end

            if (o_inc_curr) begin
                curr <= curr + 1;

                if (curr_x == 31) begin
                    curr_x <= 0;
                    if (curr_y == 0) begin
                        curr_y <= 0;
                    end
                    else begin
                        curr_y <= curr_y + 1;
                    end
                end
                else begin
                    curr_x <= curr_x + 1;
                end
            end

            if (o_clr_load_map) begin
                reg_load <= 0;
            end

        end
    end

    `include "fabric32_fabric.v"
endmodule
