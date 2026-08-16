`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 24.05.2026 14:21:57
// Design Name: 
// Module Name: i2s_to_DeltaSigma
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


//////////////////////////////////////////////////////////////////////////////////
// Module Name: i2s_to_delta_sigma_dac
// Description: Multi-channel, multi-order Delta-Sigma DAC from standard I2S.
//              Perfectly compatible with ADI axi_i2s_adi outputs.
/////////////////////////////////////////////////////////////////////////////////
module i2s_to_delta_sigma_dac #(
      parameter NUM_SDATA_LINES  = 1,   // Количество физических линий i2s_sdata (1 линия = 2 канала)
      parameter AUDIO_DATA_WIDTH = 24,  // Разрядность аудио (обычно 16 или 24)
      parameter DS_ORDER         = 1    // Порядок дельта-сигма модулятора (1, 2 или 3)
  )(
      // System Clock (Частота передискретизации, например 100 МГц)
      input  wire clk,
      input  wire rst_n,
      
      // I2S Interface (Подключается к выходам axi_i2s_adi: BCLK_O, LRCLK_O, SDATA_O)
      input  wire i2s_bclk,
      input  wire i2s_lrclk,
      input  wire [NUM_SDATA_LINES-1:0] i2s_sdata,
      
      // Delta-Sigma DAC Outputs (1-bit PWM/PDM streams)
      // Индексация: dac_out[0] = Line0 Left, dac_out[1] = Line0 Right, dac_out[2] = Line1 Left...
      output wire [(NUM_SDATA_LINES*2)-1:0] dac_out
  );
  
  //--------------------------------------------------------------------------------
  // 1. Clock Domain Crossing (CDC) & Edge Detection
  //--------------------------------------------------------------------------------
  reg [2:0] bclk_sync;
  reg [2:0] lrclk_sync;
  reg [2:0] sdata_sync [0:NUM_SDATA_LINES-1];
  
  integer i;
  always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
          bclk_sync  <= 3'b0;
          lrclk_sync <= 3'b0;
          for (i = 0; i < NUM_SDATA_LINES; i = i + 1)
              sdata_sync[i] <= 3'b0;
      end else begin
          bclk_sync  <= {bclk_sync[1:0], i2s_bclk};
          lrclk_sync <= {lrclk_sync[1:0], i2s_lrclk};
          for (i = 0; i < NUM_SDATA_LINES; i = i + 1)
              sdata_sync[i] <= {sdata_sync[i][1:0], i2s_sdata[i]};
      end
  end
  
  // По стандарту I2S, данные стабильны на нарастающем фронте BCLK
  wire bclk_rise = (bclk_sync[2:1] == 2'b01);
  wire lrclk_val = lrclk_sync[2]; // FIX: было [1] - неполная 3-стадийная CDC, бит [2] не использовался
  
  //--------------------------------------------------------------------------------
  // 2. Robust I2S Demux (BCLK Counter Based)
  //--------------------------------------------------------------------------------
  reg [7:0] bclk_cnt;
  reg lrclk_latched;
  
  reg signed [AUDIO_DATA_WIDTH-1:0] left_shift  [0:NUM_SDATA_LINES-1];
  reg signed [AUDIO_DATA_WIDTH-1:0] right_shift [0:NUM_SDATA_LINES-1];
  reg signed [AUDIO_DATA_WIDTH-1:0] left_latch  [0:NUM_SDATA_LINES-1];
  reg signed [AUDIO_DATA_WIDTH-1:0] right_latch [0:NUM_SDATA_LINES-1];
  
  always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
          bclk_cnt      <= 8'd0;
          lrclk_latched <= 1'b0;
          for (i = 0; i < NUM_SDATA_LINES; i = i + 1) begin
              left_shift[i]  <= 0; right_shift[i]  <= 0;
              left_latch[i]  <= 0; right_latch[i]  <= 0;
          end
      end else if (bclk_rise) begin
          
          // Обнаружили смену канала (LRCLK переключился)
          if (lrclk_val != lrclk_latched) begin
              lrclk_latched <= lrclk_val;
              bclk_cnt      <= 8'd0; // Сброс счетчика битов для нового канала
              
              // Фиксируем сдвинутые данные предыдущего канала
              if (lrclk_latched == 1'b0) begin // 0 = Закончили левый канал
                  for (i = 0; i < NUM_SDATA_LINES; i = i + 1)
                      left_latch[i] <= left_shift[i];
              end else begin                   // 1 = Закончили правый канал
                  for (i = 0; i < NUM_SDATA_LINES; i = i + 1)
                      right_latch[i] <= right_shift[i];
              end
              
          end else begin
              bclk_cnt <= bclk_cnt + 1'b1;
              
              // Собираем биты. Переход LRCLK «поглощает» пустой бит стандарта I2S
              // (bclk_cnt сбрасывается в ветке смены канала), поэтому bclk_cnt=0
              // уже соответствует MSB нового слова.
              if (bclk_cnt < AUDIO_DATA_WIDTH) begin
                  if (lrclk_latched == 1'b0) begin // Принимаем левый канал
                      for (i = 0; i < NUM_SDATA_LINES; i = i + 1)
                          left_shift[i] <= {left_shift[i][AUDIO_DATA_WIDTH-2:0], sdata_sync[i][1]};
                  end else begin                   // Принимаем правый канал
                      for (i = 0; i < NUM_SDATA_LINES; i = i + 1)
                          right_shift[i] <= {right_shift[i][AUDIO_DATA_WIDTH-2:0], sdata_sync[i][1]};
                  end
              end
          end
      end
  end
  
  //--------------------------------------------------------------------------------
  // 3. Multi-Channel Array Mapping
  //--------------------------------------------------------------------------------
  localparam TOTAL_CHANNELS = NUM_SDATA_LINES * 2;
  localparam ACC_WIDTH      = AUDIO_DATA_WIDTH + 4; // Запас бит для предотвращения переполнений
  localparam EXT_WIDTH      = ACC_WIDTH + 3;        // Ширина расширенных шин для арифметики
  
  wire signed [ACC_WIDTH-1:0] din_array [0:TOTAL_CHANNELS-1];
  
  genvar g;
  generate
      for (g = 0; g < NUM_SDATA_LINES; g = g + 1) begin : gen_map
          // Левый и правый каналы: явное знаковое расширение до ACC_WIDTH
          assign din_array[g*2]   = {{(ACC_WIDTH-AUDIO_DATA_WIDTH){left_latch[g][AUDIO_DATA_WIDTH-1]}},  left_latch[g]};
          assign din_array[g*2+1] = {{(ACC_WIDTH-AUDIO_DATA_WIDTH){right_latch[g][AUDIO_DATA_WIDTH-1]}}, right_latch[g]};
      end
  endgenerate
  
  //--------------------------------------------------------------------------------
  // 4. Delta-Sigma Modulators (Error Feedback Topology)
  //--------------------------------------------------------------------------------
  localparam signed [EXT_WIDTH-1:0] MAX_VAL =  (1 << (AUDIO_DATA_WIDTH-1)) - 1;
  localparam signed [EXT_WIDTH-1:0] MIN_VAL = -(1 << (AUDIO_DATA_WIDTH-1));
  
  // Ограничители интеграторов (Clamping) для защиты высших порядков от разрыва
  localparam signed [EXT_WIDTH-1:0] CLAMP_POS = MAX_VAL <<< 1;
  localparam signed [EXT_WIDTH-1:0] CLAMP_NEG = MIN_VAL <<< 1;
  
  generate
      for (g = 0; g < TOTAL_CHANNELS; g = g + 1) begin : gen_dac
          
          wire signed [ACC_WIDTH-1:0] din = din_array[g];
          reg dac_out_r;
          
          wire signed [EXT_WIDTH-1:0] din_ext = {{(EXT_WIDTH-ACC_WIDTH){din[ACC_WIDTH-1]}}, din};
          wire signed [EXT_WIDTH-1:0] fb_ext  = dac_out_r ? MAX_VAL : MIN_VAL;
          
          if (DS_ORDER == 1) begin : ds_order_1
              reg signed [ACC_WIDTH-1:0] e1;
              wire signed [EXT_WIDTH-1:0] e1_ext = {{(EXT_WIDTH-ACC_WIDTH){e1[ACC_WIDTH-1]}}, e1};
              
              wire signed [EXT_WIDTH-1:0] u     = din_ext + e1_ext;
              wire signed [EXT_WIDTH-1:0] e_raw = u - fb_ext;
              
              always @(posedge clk or negedge rst_n) begin
                  if (!rst_n) begin
                      e1 <= 0; dac_out_r <= 0;
                  end else begin
                      // Защита аккумулятора от перегрузок
                      if (e_raw > CLAMP_POS)      e1 <= CLAMP_POS[ACC_WIDTH-1:0];
                      else if (e_raw < CLAMP_NEG) e1 <= CLAMP_NEG[ACC_WIDTH-1:0];
                      else                        e1 <= e_raw[ACC_WIDTH-1:0];
                      
                      dac_out_r <= (u >= 0);
                  end
              end
          end
          
          else if (DS_ORDER == 2) begin : ds_order_2
              reg signed [ACC_WIDTH-1:0] e1, e2;
              wire signed [EXT_WIDTH-1:0] e1_ext = {{(EXT_WIDTH-ACC_WIDTH){e1[ACC_WIDTH-1]}}, e1};
              wire signed [EXT_WIDTH-1:0] e2_ext = {{(EXT_WIDTH-ACC_WIDTH){e2[ACC_WIDTH-1]}}, e2};
              
              // EFM 2nd Order: H(z) = (1 - z^-1)^2 -> + 2*e1 - e2
              wire signed [EXT_WIDTH-1:0] u     = din_ext + (e1_ext <<< 1) - e2_ext;
              wire signed [EXT_WIDTH-1:0] e_raw = u - fb_ext;
              
              always @(posedge clk or negedge rst_n) begin
                  if (!rst_n) begin
                      e1 <= 0; e2 <= 0; dac_out_r <= 0;
                  end else begin
                      if (e_raw > CLAMP_POS)      e1 <= CLAMP_POS[ACC_WIDTH-1:0];
                      else if (e_raw < CLAMP_NEG) e1 <= CLAMP_NEG[ACC_WIDTH-1:0];
                      else                        e1 <= e_raw[ACC_WIDTH-1:0];
                      
                      e2 <= e1;
                      dac_out_r <= (u >= 0);
                  end
              end
          end
          
          else begin : ds_order_3
              reg signed [ACC_WIDTH-1:0] e1, e2, e3;
              wire signed [EXT_WIDTH-1:0] e1_ext = {{(EXT_WIDTH-ACC_WIDTH){e1[ACC_WIDTH-1]}}, e1};
              wire signed [EXT_WIDTH-1:0] e2_ext = {{(EXT_WIDTH-ACC_WIDTH){e2[ACC_WIDTH-1]}}, e2};
              wire signed [EXT_WIDTH-1:0] e3_ext = {{(EXT_WIDTH-ACC_WIDTH){e3[ACC_WIDTH-1]}}, e3};
              
              // EFM 3rd Order: H(z) = (1 - z^-1)^3 -> + 3*e1 - 3*e2 + e3
              wire signed [EXT_WIDTH-1:0] u     = din_ext + (e1_ext <<< 1) + e1_ext
                                                          - (e2_ext <<< 1) - e2_ext
                                                          + e3_ext;
              wire signed [EXT_WIDTH-1:0] e_raw = u - fb_ext;
              
              always @(posedge clk or negedge rst_n) begin
                  if (!rst_n) begin
                      e1 <= 0; e2 <= 0; e3 <= 0; dac_out_r <= 0;
                  end else begin
                      if (e_raw > CLAMP_POS)      e1 <= CLAMP_POS[ACC_WIDTH-1:0];
                      else if (e_raw < CLAMP_NEG) e1 <= CLAMP_NEG[ACC_WIDTH-1:0];
                      else                        e1 <= e_raw[ACC_WIDTH-1:0];
                      
                      e2 <= e1; 
                      e3 <= e2;
                      dac_out_r <= (u >= 0);
                  end
              end
          end
          
          assign dac_out[g] = dac_out_r;
      end
endgenerate
  
endmodule
