`timescale 1ns / 1ps

module system_top (
    input  wire clk,      // 板子原始的 100MHz 時脈
    input  wire reset,
    output wire [15:0] led
);

    wire resetn = ~reset;

    // --- 🔑 降頻器 (Clock Divider) 100MHz -> 25MHz ---
    // 為了讓 32-bit 乘加運算器有足夠的物理時間完成運算，降低系統頻率
    reg [1:0] clk_div = 2'b0;
    always @(posedge clk) begin
        clk_div <= clk_div + 1'b1;
    end
    
    wire sys_clk; // 這是降頻後、真正要給 CPU 和加速器使用的 25MHz 心跳
    BUFG clk_buf (.I(clk_div[1]), .O(sys_clk));

    // --- CPU 介面 ---
    wire mem_valid, mem_instr, mem_ready;
    wire [31:0] mem_addr, mem_wdata, mem_rdata;
    wire [3:0]  mem_wstrb;

    picorv32 cpu_core (
        .clk          (sys_clk),  // 餵給它安全的 25MHz
        .resetn       (resetn),
        .mem_valid    (mem_valid),
        .mem_instr    (mem_instr),
        .mem_ready    (mem_ready),
        .mem_addr     (mem_addr),
        .mem_wdata    (mem_wdata),
        .mem_wstrb    (mem_wstrb),
        .mem_rdata    (mem_rdata)
    );

    // --- 1. MMIO 區段位址解碼器 ---
    wire is_main_mem   = (mem_addr[31:16] == 16'h0000); 
    wire is_led        = (mem_addr[31:16] == 16'h0001); 
    wire is_accel_ctrl = (mem_addr[31:16] == 16'h0002); 
    wire is_matrix_ram = (mem_addr[31:16] == 16'h0003); 

    reg mem_ready_reg;

    // --- 2. 主記憶體 (CPU 專用) ---
    reg [31:0] main_memory [0:2047];
    wire [10:0] main_mem_word_addr = mem_addr[12:2];
    wire main_mem_we = (mem_valid && !mem_ready_reg && is_main_mem);
    reg [31:0] main_mem_rdata_reg;
    
    always @(posedge sys_clk) begin
        if (main_mem_we) begin
            if (mem_wstrb[0]) main_memory[main_mem_word_addr][7:0]   <= mem_wdata[7:0];
            if (mem_wstrb[1]) main_memory[main_mem_word_addr][15:8]  <= mem_wdata[15:8];
            if (mem_wstrb[2]) main_memory[main_mem_word_addr][23:16] <= mem_wdata[23:16];
            if (mem_wstrb[3]) main_memory[main_mem_word_addr][31:24] <= mem_wdata[31:24];
        end
        main_mem_rdata_reg <= main_memory[main_mem_word_addr];
    end

    // --- 3. 矩陣專用 Dual-Port BRAM ---
    reg [31:0] matrix_ram [0:31];
    
    wire [4:0] matrix_ram_word_addr = mem_addr[6:2]; 
    wire matrix_ram_we = (mem_valid && !mem_ready_reg && is_matrix_ram && mem_wstrb != 4'b0000);
    reg [31:0] cpu_matrix_rdata_reg;
    
    always @(posedge sys_clk) begin
        if (matrix_ram_we) begin
            matrix_ram[matrix_ram_word_addr] <= mem_wdata;
        end
        cpu_matrix_rdata_reg <= matrix_ram[matrix_ram_word_addr];
    end

    wire [31:0] accel_bram_addr;
    wire [31:0] accel_bram_wdata;
    wire [31:0] accel_bram_rdata;
    wire        accel_bram_we;
    reg  [31:0] accel_bram_rdata_reg;

    always @(posedge sys_clk) begin
        if (accel_bram_we) begin
            matrix_ram[accel_bram_addr[4:0]] <= accel_bram_wdata;
        end
        accel_bram_rdata_reg <= matrix_ram[accel_bram_addr[4:0]];
    end
    assign accel_bram_rdata = accel_bram_rdata_reg;

    // --- 4. 實體化矩陣加速器 ---
    reg  accel_start;
    wire accel_done;

    matrix_accel accel_inst (
        .clk        (sys_clk), // 餵給它安全的 25MHz
        .resetn     (resetn),
        .start      (accel_start),
        .done       (accel_done),
        .bram_addr  (accel_bram_addr),
        .bram_rdata (accel_bram_rdata),
        .bram_wdata (accel_bram_wdata),
        .bram_we    (accel_bram_we)
    );

    // --- 捕捉加速器的 Done 旗標 ---
    reg accel_done_latched;
    always @(posedge sys_clk) begin
        if (!resetn) accel_done_latched <= 1'b0;
        else if (accel_start) accel_done_latched <= 1'b0; 
        else if (accel_done) accel_done_latched <= 1'b1;  
    end

    // --- 5. 系統總線路由 ---
    reg [31:0] mem_rdata_mux;
    reg [15:0] led_reg;
    reg mem_ready_chain; // 🔑 修復關鍵：引入 1 週期 Wait State 緩衝

    always @(posedge sys_clk) begin
        if (!resetn) begin
            mem_ready_reg <= 1'b0;
            mem_ready_chain <= 1'b0;
            mem_rdata_mux <= 32'b0;
            led_reg       <= 16'b0;
            accel_start   <= 1'b0;
        end else begin
            mem_ready_reg <= 1'b0;
            accel_start   <= 1'b0;

            // 握手狀態機：收到請求且尚未處理
            if (mem_valid && !mem_ready_reg && !mem_ready_chain) begin
                mem_ready_chain <= 1'b1; // 第一個週期：捕捉位址，讓記憶體有時間把資料吐出來
                
                // 寫入動作 (Write) 可以在第一週期直接鎖存
                if (is_accel_ctrl && mem_wstrb != 4'b0000) accel_start <= mem_wdata[0];
                if (is_led && mem_wstrb != 4'b0000) led_reg <= mem_wdata[15:0];
            end 
            else if (mem_ready_chain) begin
                mem_ready_chain <= 1'b0;
                mem_ready_reg   <= 1'b1; // 第二個週期：通知 CPU 資料準備好了！

                // 讀取動作 (Read) 必須在第二週期取值，確保拿到「最新出爐」的正確資料
                if (is_main_mem) begin
                    mem_rdata_mux <= main_mem_rdata_reg;
                end
                else if (is_matrix_ram) begin
                    mem_rdata_mux <= cpu_matrix_rdata_reg;
                end
                else if (is_accel_ctrl) begin
                    mem_rdata_mux <= {31'b0, accel_done_latched};
                end
                else begin
                    mem_rdata_mux <= 32'b0;
                end
            end
        end
    end

    assign mem_ready = mem_ready_reg;
    assign mem_rdata = mem_rdata_mux;
    assign led = led_reg;

    // --- 6. 系統初始資料預載 ---
    integer i;
    initial begin
        for (i = 0; i < 2048; i = i + 1) main_memory[i] = 32'b0;
        for (i = 0; i < 32; i = i + 1) matrix_ram[i] = 32'b0;
        
        // A 矩陣
        matrix_ram[0]=32'd1; matrix_ram[1]=32'd2; matrix_ram[2]=32'd3;
        matrix_ram[3]=32'd4; matrix_ram[4]=32'd5; matrix_ram[5]=32'd6;
        matrix_ram[6]=32'd7; matrix_ram[7]=32'd8; matrix_ram[8]=32'd9;
        
        // B 矩陣
        matrix_ram[9]=32'd1;  matrix_ram[10]=32'd0; matrix_ram[11]=32'd0;
        matrix_ram[12]=32'd0; matrix_ram[13]=32'd1; matrix_ram[14]=32'd0;
        matrix_ram[15]=32'd0; matrix_ram[16]=32'd0; matrix_ram[17]=32'd1;

        // --- 前面的 A 矩陣與 B 矩陣預載請保留 ---
        
        // RISC-V 韌體 (終極除錯：加入 Busy 與 Done 狀態燈探針)
        main_memory[0]  = 32'h000202B7; // lui t0, 0x00020 (設定加速器控制區)
        main_memory[1]  = 32'h00030337; // lui t1, 0x00030 (設定 BRAM 資料區)
        main_memory[2]  = 32'h000103B7; // lui t2, 0x00010 (設定 LED 區)

        // 第一步：先點亮最左邊的燈 LED[15] 代表 "BUSY" (CPU 還活著，準備觸發)
        main_memory[3]  = 32'h00008537; // lui a0, 0x8     (a0 = 0x8000)
        main_memory[4]  = 32'h00A3A023; // sw  a0, 0(t2)   (寫入 LED)

        // 第二步：發射啟動訊號
        main_memory[5]  = 32'h00100513; // li  a0, 1
        main_memory[6]  = 32'h00A2A023; // sw  a0, 0(t0)   (寫入 1 觸發 Start)

        // 第三步：死亡輪詢 (等 Done 旗標)
        main_memory[7]  = 32'h0002A583; // lw  a1, 0(t0)   (讀取 Done 旗標)
        main_memory[8]  = 32'h0015F593; // andi a1, a1, 1  (擷取第 0 位元)
        main_memory[9]  = 32'hFE058CE3; // beq a1, zero, -8(如果是 0，跳回第 7 行繼續等)

        // 第四步：算完了！讀取結果，並點亮 LED[14] 代表 "DONE"
        main_memory[10] = 32'h06832603; // lw  a2, 104(t1) (讀取矩陣 C[2][2])
        main_memory[11] = 32'h000045B7; // lui a1, 0x4     (a1 = 0x4000)
        main_memory[12] = 32'h00C5E633; // or  a2, a1, a2  (把答案跟 LED[14] 結合)
        main_memory[13] = 32'h00C3A023; // sw  a2, 0(t2)   (寫入 LED 顯示最終狀態)
        main_memory[14] = 32'h0000006F; // j 0             (停在這裡)
    end
endmodule