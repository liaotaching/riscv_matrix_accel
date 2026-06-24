# 基於 RISC-V 系統之記憶體映射雙埠 BRAM 矩陣乘法硬體加速器

**元智大學 電機工程學系 (Yuan Ze University, EE)** **114-2 EEB318A 數位系統設計與實驗 (Digital System Design with Lab) - 期末專題** **作者：** 廖大慶 (Student ID: 1120303)

---

## 專案簡介 (Project Overview)
本專案實作一個由 RISC-V (PicoRV32) 核心控制之 3x3 矩陣乘法硬體加速系統。系統採用軟硬體協同設計，利用 Memory-Mapped I/O (MMIO) 技術將自訂的雙埠 BRAM (Dual-port BRAM) 與矩陣乘加運算單元 (MAC Unit) 映射至 CPU 記憶體空間。

透過硬體電路大幅縮短矩陣運算週期，並將最終結果精確顯示於 FPGA 開發板之 LED 狀態燈上。系統支援帶正負號的固定小數點 (二補數) 運算。

### 核心硬體規格
* **CPU Core:** PicoRV32
* **Target Board:** Digilent Basys 3 (Xilinx Artix-7 FPGA)
* **System Clock:** 100MHz (透過內部降頻器提供 25MHz 給系統總線與加速器)
* **MMIO Mapping:**
  * `0x0001_0000`: GPIO / LED 狀態顯示區
  * `0x0002_0000`: Hardware Accelerator 控制暫存器 (Start/Done Flags)
  * `0x0003_0000`: Dual-port BRAM 矩陣資料暫存區

---

## 專案檔案結構 (File Structure)
* `system_top.v`: 系統頂層模組，包含降頻器、PicoRV32 實體化、MMIO 總線解碼器、BRAM 控制邏輯，以及 RISC-V 韌體之預載機器碼。
* `matrix_accel.v`: 硬體加速器模組，包含與 BRAM 溝通之讀寫介面及 3x3 矩陣乘加運算狀態機 (FSM)。
* `Basys3.xdc`: 硬體腳位與時序約束檔 (包含 generated clock 宣告以解決 STA 時序違規問題)。
* `s1120303_final_project_report.pdf`: 完整期末專題報告與除錯歷程記錄。

---

## 如何重現與測試 (How to Reproduce)

### 1. 開發環境設定
1. 開啟 Xilinx Vivado (建議版本 2020.2 或更新)。
2. 建立新專案，選擇對應之 FPGA 型號 (`xc7a35tcpg236-1` for Basys 3)。
3. 將本倉庫的 `.v` 原始碼檔案與 `.xdc` 約束檔加入專案中。

### 2. 測資修改 (預載模式)
因系統採用極簡化架構，測資直接預載於 `system_top.v` 中。
* 開啟 `system_top.v`，找到 `// --- 6. 系統初始資料預載 ---` 區塊。
* 可自由修改 `matrix_ram[0]` 到 `matrix_ram[8]` (矩陣 A) 以及 `matrix_ram[9]` 到 `matrix_ram[17]` (矩陣 B) 的數值。
* 預設 CPU 會讀取輸出矩陣 C 的右下角元素 (記憶體位址偏移量 `104`)，可修改 RISC-V 組合語言 `lw a2, 104(t1)` 改變觀測目標。

### 3. 合成與燒錄
1. 點擊 **Generate Bitstream** 進行合成與佈線。
2. 將 Basys 3 開發板連接至電腦，開啟 **Hardware Manager**。
3. 選擇 **Program Device**，將生成的 `.bit` 檔案燒錄至 FPGA 中。

### 4. 實機操作與結果觀測
1. **啟動運算：** 按下開發板正中央的按鈕 (**BTNC** / Reset)，喚醒 RISC-V CPU。
2. **狀態指示燈：**
   * 最左側 **LED[15]** 會閃爍，代表系統進入 `BUSY` 狀態。
   * 隨後 **LED[14]** 穩定亮起，代表加速器算完並舉起 `DONE` 旗標。
3. **結果判讀：** 觀測開發板右側 **LED[13:0]** 的亮暗狀態，將其二進位數值轉換為十進位，即為矩陣運算之最終結果 (例如亮起 `00_0000_0000_1001` 即為 9)。

---
**成果展示影片：** [點此觀看實機運作展示](https://youtu.be/KuwpMRzprfo)
