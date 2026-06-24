`timescale 1ns / 1ps

module matrix_accel (
    input  wire clk,
    input  wire resetn,

    // --- 與 CPU 溝通的控制訊號 ---
    input  wire start,
    output reg  done,

    // --- 與 BRAM 溝通的介面 (Word 位址) ---
    output reg  [31:0] bram_addr,
    input  wire [31:0] bram_rdata,
    output reg  [31:0] bram_wdata,
    output reg  bram_we
);

    // 狀態機定義 (FSM)
    localparam IDLE      = 4'd0;
    localparam SET_A     = 4'd1;
    localparam WAIT_A    = 4'd2;
    localparam SET_B     = 4'd3;
    localparam WAIT_B    = 4'd4;
    localparam MAC       = 4'd5;
    localparam WRITE_C   = 4'd6;
    localparam NEXT_ELEM = 4'd7;
    localparam DONE_ST   = 4'd8;

    reg [3:0] state;
    
    // 矩陣 3x3 的指標計數器
    reg [1:0] row; // 對應 i
    reg [1:0] col; // 對應 j
    reg [1:0] k;   // 對應 k
    
    // 運算暫存器 (支援正負號固定小數點或整數運算)
    reg signed [31:0] val_A;
    reg signed [31:0] sum;

    // 記憶體基底位址 (Word偏移量)
    localparam BASE_A = 32'd0;
    localparam BASE_B = 32'd9;
    localparam BASE_C = 32'd18;

    always @(posedge clk) begin
        if (!resetn) begin
            state     <= IDLE;
            done      <= 1'b0;
            bram_we   <= 1'b0;
            bram_addr <= 32'd0;
            row       <= 2'd0;
            col       <= 2'd0;
            k         <= 2'd0;
            sum       <= 32'd0;
        end else begin
            case (state)
                IDLE: begin
                    // 🚨 修改核心：移除了 done <= 1'b0，讓算完的旗標可以一直舉著
                    bram_we <= 1'b0;
                    if (start) begin
                        done  <= 1'b0; // 只有在收到新的 Start 命令時，才把旗標放下！
                        row   <= 2'd0;
                        col   <= 2'd0;
                        k     <= 2'd0;
                        sum   <= 32'd0;
                        state <= SET_A;
                    end
                end

                SET_A: begin
                    bram_addr <= BASE_A + (row * 3) + k;
                    state     <= WAIT_A;
                end

                WAIT_A: begin
                    // BRAM 讀取需要 1 個 Clock 的延遲
                    state <= SET_B; 
                end

                SET_B: begin
                    val_A     <= bram_rdata; // 把從 BRAM 吐出來的 A 矩陣元素存好
                    bram_addr <= BASE_B + (k * 3) + col;
                    state     <= WAIT_B;
                end

                WAIT_B: begin
                    state <= MAC;
                end

                MAC: begin
                    // 最核心的乘加運算: sum = sum + A * B
                    sum <= sum + (val_A * $signed(bram_rdata));
                    
                    if (k == 2'd2) begin
                        state <= WRITE_C; // 3個元素都乘加完畢，準備寫回 C 矩陣
                    end else begin
                        k     <= k + 1'b1;
                        state <= SET_A;   // 繼續抓下一組 k
                    end
                end

                WRITE_C: begin
                    bram_addr  <= BASE_C + (row * 3) + col;
                    bram_wdata <= sum;
                    bram_we    <= 1'b1;
                    state      <= NEXT_ELEM;
                end

                NEXT_ELEM: begin
                    bram_we <= 1'b0; // 關閉寫入
                    if (col == 2'd2) begin
                        if (row == 2'd2) begin
                            state <= DONE_ST; // 9個元素全部算完，收工！
                        end else begin
                            row <= row + 1'b1;
                            col <= 2'd0;
                            k   <= 2'd0;
                            sum <= 32'd0;
                            state <= SET_A;
                        end
                    end else begin
                        col <= col + 1'b1;
                        k   <= 2'd0;
                        sum <= 32'd0;
                        state <= SET_A;
                    end
                end

                DONE_ST: begin
                    done <= 1'b1;  // 舉起完成旗標
                    state <= IDLE; // 直接回到 IDLE。因為 IDLE 已經不會清空 done，所以旗標會穩穩地保持 1！
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule