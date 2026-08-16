`timescale 1ns / 1ps

module i2s_tone_generator_stereo (
    // Атрибуты для автоматического распознавания системного клока в Block Design
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_RESET rst_n" *)
    input  wire        clk,        // Системный клок 100 МГц

    // Атрибуты для автоматического распознавания активного низкого сброса
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire        rst_n,      // Сброс (активный низкий)

    // Выходы стандартного стерео I2S
    output reg         i2s_bclk,   // Генерируемый BCLK (~3.125 МГц)
    output reg         i2s_lrclk,  // Генерируемый LRCLK (~48.8 кГц): 0 = Left, 1 = Right
    output reg         i2s_data    // Выходной последовательный стерео-поток данных
);

    // ---- Генераторы сетки частот I2S (для входного клока 100 МГц) ----
    // Делим 100 МГц на 32 для получения BCLK: 100 MHz / 32 = 3.125 MHz
    // Делим BCLK на 64 для получения LRCLK: 3.125 MHz / 64 = 48.828 kHz
    reg [4:0] clk_div;  // 5-битный делитель тактовой частоты (0..31)
    reg [5:0] bclk_div; // Счётчик бит внутри кадра LRCLK (0..63)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_div  <= 5'd0;
            bclk_div <= 6'd0;
            i2s_bclk  <= 1'b0;
            i2s_lrclk <= 1'b0;
        end else begin
            clk_div <= clk_div + 5'd1;

            if (clk_div == 5'd15) begin
                i2s_bclk <= 1'b1; // Передний фронт BCLK
            end else if (clk_div == 5'd31) begin
                i2s_bclk <= 1'b0; // Задний фронт BCLK
                bclk_div <= bclk_div + 6'd1;

                // Смена каналов LRCLK происходит строго по спаду BCLK
                // Слоты 0..31  - Левый канал (LRCLK = 0)
                // Слоты 32..63 - Правый канал (LRCLK = 1)
                if (bclk_div == 6'd31) begin
                    i2s_lrclk <= 1'b1; // Переход к Правому каналу
                end else if (bclk_div == 6'd63) begin
                    i2s_lrclk <= 1'b0; // Переход к Левому каналу
                end
            end
        end
    end

    // ---- Генераторы тона (DDS) ----
    // Шаг вычислен для частоты дискретизации Fs = 48828.125 Гц
    // Step = (Fout * 2^24) / Fs
    // Левый канал (1000 Гц): Step = 343597
    // Правый канал (500 Гц):  Step = 171798
    reg [23:0] acc_l, acc_r;
    reg [23:0] tone_l, tone_r;

    wire frame_tick = (clk_div == 5'd31) && (bclk_div == 6'd63);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_l  <= 24'd0;
            acc_r  <= 24'd0;
            tone_l <= 24'd0;
            tone_r <= 24'd0;
        end else if (frame_tick) begin
            acc_l <= acc_l + 24'd343597;
            acc_r <= acc_r + 24'd171798;

            tone_l <= {{4{acc_l[23]}}, acc_l[23:4]};  // было tone_l <= acc_l -- урезано в ~16 раз
            tone_r <= {{4{acc_r[23]}}, acc_r[23:4]};  // было tone_r <= acc_r
        end
    end

    // ---- Сдвиговый регистр и выдача данных ----
    reg [23:0] shift_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_reg <= 24'd0;
            i2s_data  <= 1'b0;
        end else if (clk_div == 5'd31) begin // Синхронизировано со спадом BCLK
            
            // 1. Сдвиг и выдача бита на линию данных
            if (bclk_div == 6'd0 || bclk_div == 6'd32) begin
                // Начальный защитный интервал I2S (Skip slot)
                i2s_data <= 1'b0;
            end else if (bclk_div >= 6'd1 && bclk_div <= 6'd24) begin
                // Выдача 24 бит Левого канала (MSB first)
                i2s_data  <= shift_reg[23];
                shift_reg <= {shift_reg[22:0], 1'b0};
            end else if (bclk_div >= 6'd33 && bclk_div <= 6'd56) begin
                // Выдача 24 бит Правого канала (MSB first)
                i2s_data  <= shift_reg[23];
                shift_reg <= {shift_reg[22:0], 1'b0};
            end else begin
                // Неиспользуемые биты слота заполняем нулями
                i2s_data <= 1'b0;
            end

            // 2. Параллельная загрузка сэмплов в начале полупериодов
            if (bclk_div == 6'd0) begin
                shift_reg <= tone_l; // Загрузка Левого канала
            end
            if (bclk_div == 6'd32) begin
                shift_reg <= tone_r; // Загрузка Правого канала
            end
        end
    end

endmodule