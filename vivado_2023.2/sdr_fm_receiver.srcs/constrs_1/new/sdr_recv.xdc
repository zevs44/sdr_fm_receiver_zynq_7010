set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVDS_25} [get_ports lvds_p_0]
set_property -dict {PACKAGE_PIN W15 IOSTANDARD LVDS_25} [get_ports lvds_n_0]

set_property PACKAGE_PIN Y14 [get_ports audio_out_l_0]
set_property PACKAGE_PIN W14 [get_ports audio_out_r_0]
set_property IOSTANDARD LVCMOS33 [get_ports audio_out_l_0]
set_property IOSTANDARD LVCMOS33 [get_ports audio_out_r_0]
set_property SLEW FAST [get_ports audio_out_l_0]
set_property SLEW FAST [get_ports audio_out_r_0]
set_property DRIVE 12 [get_ports audio_out_l_0]
set_property DRIVE 12 [get_ports audio_out_r_0]

# ==============================================================================
# НАСТРОЙКИ ПИНОВ ДЛЯ ВХОДА I2S (Пример для LVCMOS 3.3V)
# ==============================================================================

# Битовый клок (Bit Clock / Continuous Serial Clock)
set_property PACKAGE_PIN T17 [get_ports ch2_i2s_bclk_0]
set_property IOSTANDARD LVCMOS33 [get_ports ch2_i2s_bclk_0]

# Выбор канала (Word Select / Left-Right Clock)
set_property PACKAGE_PIN R18 [get_ports ch2_i2s_lrclk_0]
set_property IOSTANDARD LVCMOS33 [get_ports ch2_i2s_lrclk_0]

# Линия последовательных данных (Serial Data Input)
set_property PACKAGE_PIN R17 [get_ports ch2_i2s_sdata_0]
set_property IOSTANDARD LVCMOS33 [get_ports ch2_i2s_sdata_0]


# Включение встроенной терминации 100 Ом для согласования антенны
#set_property DIFF_TERM TRUE [get_ports lvds_p_0]

# Исключаем входной порт из расчета временных задержек (False Path)
#set_false_path -from [get_ports lvds_p_0]

set_property IOSTANDARD LVCMOS33 [get_ports {dac_out_0[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {dac_out_0[1]}]
# dac_out_0[0] - это левый канал
set_property PACKAGE_PIN W13 [get_ports {dac_out_0[0]}]
# dac_out_0[1] - это правый канал
set_property PACKAGE_PIN V12 [get_ports {dac_out_0[1]}]
# Настройки скорости (FAST и DRIVE)
set_property SLEW FAST [get_ports {dac_out_0[0]}]
set_property SLEW FAST [get_ports {dac_out_0[1]}]
set_property DRIVE 12 [get_ports {dac_out_0[0]}]
set_property DRIVE 12 [get_ports {dac_out_0[1]}]

set_property PACKAGE_PIN T16 [get_ports antenna_out_0]
set_property IOSTANDARD LVCMOS33 [get_ports antenna_out_0]
set_property SLEW FAST [get_ports antenna_out_0]
set_property DRIVE 8 [get_ports antenna_out_0]

set_property IOSTANDARD LVCMOS33 [get_ports led_stereo_lock_0]
set_property PACKAGE_PIN M17 [get_ports led_stereo_lock_0]
set_property IOSTANDARD LVCMOS33 [get_ports led_station_found_0]
set_property PACKAGE_PIN M19 [get_ports led_station_found_0]
set_property IOSTANDARD LVCMOS33 [get_ports led_rds_sync_0]
set_property PACKAGE_PIN L19 [get_ports led_rds_sync_0]
set_property IOSTANDARD LVCMOS33 [get_ports led_audio_heartbeat_0]
set_property PACKAGE_PIN F16 [get_ports led_audio_heartbeat_0]
