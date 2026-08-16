###############################################################################
## Copyright (C) 2014-2023 Analog Devices, Inc. All rights reserved.
### SPDX short identifier: ADIBSD
###############################################################################

# ------------------------------------------------------------
# Параметры проекта
# ------------------------------------------------------------
set ip_name         "axi_i2s_adi"
set ip_version      "1.5"    ;# бампать при каждом изменении src/*, иначе Vivado не предложит Upgrade IP в уже открытом проекте
set ip_vendor       "analog.com"
set ip_library      "user"
set ip_display_name "ADI AXI I2S Controller"
set ip_description  "ADI AXI I2S Controller"

set src_dir         "./src"                        ;# папка с исходниками
set ip_output_dir   "./ip_repo"                    ;# куда сохранить IP
set part_name       "xc7z010clg400-1"              ;# часть для временного проекта

# Чистим выход перед каждой пересборкой -- иначе при смене версии
# в директории остаются старые файлы (например xgui/<name>_v1_0.tcl),
# и Vivado ругается на несовпадение формата имени с текущей версией.
if {[file exists $ip_output_dir]} {
    file delete -force $ip_output_dir
}

# ------------------------------------------------------------
# Создаём временный проект
# ------------------------------------------------------------
create_project -in_memory -part $part_name
set_property target_language VHDL [current_project]

set vhdl_files {
    axi_ctrlif.vhd
    axi_streaming_dma_tx_fifo.vhd
    axi_streaming_dma_rx_fifo.vhd
    pl330_dma_fifo.vhd
    dma_fifo.vhd
    i2s_controller.vhd
    i2s_rx.vhd
    i2s_tx.vhd
    i2s_clkgen.vhd
    fifo_synchronizer.vhd
    axi_i2s_adi.vhd
}
foreach f $vhdl_files {
    add_files -norecurse [file join $src_dir $f]
}

add_files -fileset constrs_1 -norecurse [file join $src_dir axi_i2s_adi_constr.xdc]
set_property top axi_i2s_adi [current_fileset]
update_compile_order -fileset sources_1

# ------------------------------------------------------------
# Упаковка проекта
# ------------------------------------------------------------
ipx::package_project -root_dir $ip_output_dir \
                     -vendor $ip_vendor \
                     -library $ip_library \
                     -taxonomy /UserIP \
                     -import_files -force

# Метаданные IP
set cc [ipx::current_core]
set_property name $ip_name                 $cc
set_property version $ip_version           $cc
set_property display_name $ip_display_name $cc
set_property description $ip_description   $cc
set_property vendor_display_name {Analog Devices}     $cc
set_property company_url         {http://www.analog.com} $cc
set_property AUTO_FAMILY_SUPPORT_LEVEL level_2         $cc

# Установка PROCESSING_ORDER LATE для констрейнов
set synth_fileset [ipx::get_file_groups xilinx_anylanguagesynthesis -of_objects $cc]
if {$synth_fileset ne ""} {
    set xdc_file [ipx::get_files */axi_i2s_adi_constr.xdc -of_objects $synth_fileset]
    if {$xdc_file ne ""} {
        set_property PROCESSING_ORDER LATE $xdc_file
    }
}

# Очистка автоматически собранных интерфейсов (удален i2s чтобы порты остались обычными пинами)
foreach iface {s_axi s_axis m_axis i2s dma_ack_rx dma_req_rx dma_ack_tx dma_req_tx s_axi_aclk s_axis_aclk m_axis_aclk dma_req_tx_aclk dma_req_rx_aclk data_clk_i} {
    if {[ipx::get_bus_interfaces $iface -of_objects $cc -quiet] ne ""} {
        ipx::remove_bus_interface $iface $cc
    }
}

# ============================================================
# 1. S_AXI (AXI4-Lite)
# ============================================================
ipx::add_bus_interface s_axi $cc
set_property abstraction_type_vlnv xilinx.com:interface:aximm_rtl:1.0 [ipx::get_bus_interfaces s_axi -of_objects $cc]
set_property bus_type_vlnv xilinx.com:interface:aximm:1.0 [ipx::get_bus_interfaces s_axi -of_objects $cc]
set_property interface_mode slave [ipx::get_bus_interfaces s_axi -of_objects $cc]

foreach {logical physical} {
    AWADDR s_axi_awaddr   AWVALID s_axi_awvalid   AWREADY s_axi_awready   AWPROT s_axi_awprot
    WDATA s_axi_wdata     WSTRB s_axi_wstrb       WVALID s_axi_wvalid     WREADY s_axi_wready
    BRESP s_axi_bresp     BVALID s_axi_bvalid     BREADY s_axi_bready
    ARADDR s_axi_araddr   ARVALID s_axi_arvalid   ARREADY s_axi_arready   ARPROT s_axi_arprot
    RDATA s_axi_rdata     RRESP s_axi_rresp       RVALID s_axi_rvalid     RREADY s_axi_rready
} {
    if {[ipx::get_ports $physical -of_objects $cc -quiet] ne ""} {
        ipx::add_port_map $logical [ipx::get_bus_interfaces s_axi -of_objects $cc]
        set_property physical_name $physical [ipx::get_port_maps $logical -of_objects [ipx::get_bus_interfaces s_axi -of_objects $cc]]
    }
}

if {[ipx::get_memory_maps s_axi -of_objects $cc -quiet] ne ""} { ipx::remove_memory_map s_axi $cc }
ipx::add_memory_map s_axi $cc
set_property description {s_axi memory map} [ipx::get_memory_maps s_axi -of_objects $cc]
ipx::add_address_block reg0 [ipx::get_memory_maps s_axi -of_objects $cc]
set_property range 65536 [ipx::get_address_blocks reg0 -of_objects [ipx::get_memory_maps s_axi -of_objects $cc]]
set_property usage register [ipx::get_address_blocks reg0 -of_objects [ipx::get_memory_maps s_axi -of_objects $cc]]
# Без этого memory map висит сам по себе -- Address Editor в BD его не увидит
set_property slave_memory_map_ref s_axi [ipx::get_bus_interfaces s_axi -of_objects $cc]

# ============================================================
# 2. PL330 DMA Интефрейсы
# ============================================================
proc add_axis_bus {core name mode port_maps} {
    ipx::add_bus_interface $name $core
    set bus [ipx::get_bus_interfaces $name -of_objects $core]
    set_property abstraction_type_vlnv xilinx.com:interface:axis_rtl:1.0 $bus
    set_property bus_type_vlnv xilinx.com:interface:axis:1.0 $bus
    set_property interface_mode $mode $bus
    foreach {phys log} $port_maps {
        if {[ipx::get_ports $phys -of_objects $core -quiet] ne ""} {
            ipx::add_port_map $log $bus
            set_property physical_name $phys [ipx::get_port_maps $log -of_objects $bus]
        }
    }
}

add_axis_bus $cc dma_ack_rx slave  {dma_req_rx_davalid TVALID dma_req_rx_daready TREADY dma_req_rx_datype TUSER}
add_axis_bus $cc dma_req_rx master {dma_req_rx_drvalid TVALID dma_req_rx_drready TREADY dma_req_rx_drtype TUSER dma_req_rx_drlast TLAST}
add_axis_bus $cc dma_ack_tx slave  {dma_req_tx_davalid TVALID dma_req_tx_daready TREADY dma_req_tx_datype TUSER}
add_axis_bus $cc dma_req_tx master {dma_req_tx_drvalid TVALID dma_req_tx_drready TREADY dma_req_tx_drtype TUSER dma_req_tx_drlast TLAST}

# ============================================================
# 3. AXI-Stream Интефрейсы (s_axis и m_axis)
# ============================================================
add_axis_bus $cc s_axis slave  {s_axis_tvalid TVALID s_axis_tready TREADY s_axis_tdata TDATA s_axis_tlast TLAST s_axis_tkeep TKEEP}
add_axis_bus $cc m_axis master {m_axis_tvalid TVALID m_axis_tready TREADY m_axis_tdata TDATA m_axis_tlast TLAST m_axis_tkeep TKEEP}

# ============================================================
# 4. Привязка Clocks и Resets ко всем шинам
# ============================================================
proc add_clk_rst_bus {core clk_name rst_name assoc_buses} {
    if {[ipx::get_bus_interfaces $clk_name -of_objects $core -quiet] eq ""} {
        set bus [ipx::add_bus_interface $clk_name $core]
        set_property abstraction_type_vlnv xilinx.com:signal:clock_rtl:1.0 $bus
        set_property bus_type_vlnv xilinx.com:signal:clock:1.0 $bus
        set port_map [ipx::add_port_map CLK $bus]
        set_property physical_name $clk_name $port_map
    }
    set bus [ipx::get_bus_interfaces $clk_name -of_objects $core]
    
    if {$assoc_buses ne ""} {
        set param [ipx::get_bus_parameters ASSOCIATED_BUSIF -of_objects $bus -quiet]
        if {$param eq ""} { set param [ipx::add_bus_parameter ASSOCIATED_BUSIF $bus] }
        set_property value $assoc_buses $param
    }
    
    if {$rst_name ne "" && [ipx::get_ports $rst_name -of_objects $core -quiet] ne ""} {
        set param [ipx::get_bus_parameters ASSOCIATED_RESET -of_objects $bus -quiet]
        if {$param eq ""} { set param [ipx::add_bus_parameter ASSOCIATED_RESET $bus] }
        set_property value $rst_name $param
    }
}

add_clk_rst_bus $cc s_axi_aclk s_axi_aresetn s_axi
add_clk_rst_bus $cc s_axis_aclk s_axis_aresetn s_axis
add_clk_rst_bus $cc m_axis_aclk m_axis_aresetn m_axis
add_clk_rst_bus $cc dma_req_tx_aclk dma_req_tx_rstn "dma_req_tx:dma_ack_tx"
add_clk_rst_bus $cc dma_req_rx_aclk dma_req_rx_rstn "dma_req_rx:dma_ack_rx"
add_clk_rst_bus $cc data_clk_i "" "" 

# ============================================================
# 5. Зависимости и параметры
# ============================================================
set_property -dict [list value_validation_type "list" value_validation_list "16 20 24 32"] [ipx::get_user_parameters SLOT_WIDTH -of_objects $cc]
set_property -dict [list value_validation_type "pairs" value_validation_pairs {"Falling Edge" "0" "Rising Edge" "1"}] [ipx::get_user_parameters LRCLK_POL -of_objects $cc]
set_property -dict [list value_validation_type "pairs" value_validation_pairs {"Falling Edge" "0" "Rising Edge" "1"}] [ipx::get_user_parameters BCLK_POL -of_objects $cc]
set_property -dict [list value_validation_type "pairs" value_validation_pairs {"AXI Stream" "0" "PL330" "1"}] [ipx::get_user_parameters DMA_TYPE -of_objects $cc]
set_property -dict [list value_validation_type "range_long" value_validation_range_minimum "0" value_validation_range_maximum "1"] [ipx::get_user_parameters HAS_RX -of_objects $cc]
set_property -dict [list value_validation_type "range_long" value_validation_range_minimum "0" value_validation_range_maximum "1"] [ipx::get_user_parameters HAS_TX -of_objects $cc]
set_property -dict [list value_validation_type "range_long" value_validation_range_minimum "1" value_validation_range_maximum "32"] [ipx::get_user_parameters NUM_OF_CHANNEL -of_objects $cc]
set_property -dict [list value_validation_type "range_long" value_validation_range_minimum "1" value_validation_range_maximum "32"] [ipx::get_user_parameters S_AXI_ADDRESS_WIDTH -of_objects $cc]

# Enablement Dependencies
set dep_tx_pl330 "(spirit:decode(id('MODELPARAM_VALUE.DMA_TYPE')) = 1 and spirit:decode(id('MODELPARAM_VALUE.HAS_TX')) = 1)"
set dep_rx_pl330 "(spirit:decode(id('MODELPARAM_VALUE.DMA_TYPE')) = 1 and spirit:decode(id('MODELPARAM_VALUE.HAS_RX')) = 1)"
set dep_tx_axis "(spirit:decode(id('MODELPARAM_VALUE.DMA_TYPE')) = 0 and spirit:decode(id('MODELPARAM_VALUE.HAS_TX')) = 1)"
set dep_rx_axis "(spirit:decode(id('MODELPARAM_VALUE.DMA_TYPE')) = 0 and spirit:decode(id('MODELPARAM_VALUE.HAS_RX')) = 1)"

foreach iface {dma_ack_tx dma_req_tx dma_req_tx_aclk} { set_property enablement_dependency $dep_tx_pl330 [ipx::get_bus_interfaces $iface -of_objects $cc] }
foreach port {dma_req_tx_aclk dma_req_tx_rstn} { if {[ipx::get_ports $port -of_objects $cc -quiet] ne ""} { set_property enablement_dependency $dep_tx_pl330 [ipx::get_ports $port -of_objects $cc] } }

foreach iface {dma_ack_rx dma_req_rx dma_req_rx_aclk} { set_property enablement_dependency $dep_rx_pl330 [ipx::get_bus_interfaces $iface -of_objects $cc] }
foreach port {dma_req_rx_aclk dma_req_rx_rstn} { if {[ipx::get_ports $port -of_objects $cc -quiet] ne ""} { set_property enablement_dependency $dep_rx_pl330 [ipx::get_ports $port -of_objects $cc] } }

foreach iface {s_axis s_axis_aclk} { set_property enablement_dependency $dep_tx_axis [ipx::get_bus_interfaces $iface -of_objects $cc] }
foreach port {s_axis_aclk s_axis_aresetn} { if {[ipx::get_ports $port -of_objects $cc -quiet] ne ""} { set_property enablement_dependency $dep_tx_axis [ipx::get_ports $port -of_objects $cc] } }

foreach iface {m_axis m_axis_aclk} { set_property enablement_dependency $dep_rx_axis [ipx::get_bus_interfaces $iface -of_objects $cc] }
foreach port {m_axis_aclk m_axis_aresetn} { if {[ipx::get_ports $port -of_objects $cc -quiet] ne ""} { set_property enablement_dependency $dep_rx_axis [ipx::get_ports $port -of_objects $cc] } }

# Принудительно устанавливаем 0 на неиспользуемых входах
set_property driver_value 0 [ipx::get_ports -filter "direction==in && enablement_dependency!={}" -of_objects $cc]

# ============================================================
# 6. Настройка GUI
# ============================================================
set page0 [ipgui::get_pagespec -name "Page 0" -component $cc]

set i2s_group [ipgui::add_group -name "I2S Configuration" -component $cc -parent $page0 -display_name "I2S Configuration"]
set p [ipgui::get_guiparamspec -name "SLOT_WIDTH" -component $cc]
ipgui::move_param -component $cc -order 0 $p -parent $i2s_group
set_property -dict [list widget "comboBox" display_name "Slot Width"] $p

set p [ipgui::get_guiparamspec -name "LRCLK_POL" -component $cc]
ipgui::move_param -component $cc -order 1 $p -parent $i2s_group
set_property -dict [list widget "comboBox" display_name "Left-Right Clock Polarity"] $p

set p [ipgui::get_guiparamspec -name "BCLK_POL" -component $cc]
ipgui::move_param -component $cc -order 2 $p -parent $i2s_group
set_property -dict [list widget "comboBox" display_name "Bit Clock Polarity"] $p

set general_group [ipgui::add_group -name "General Configuration" -component $cc -parent $page0 -display_name "General Configuration"]
set p [ipgui::get_guiparamspec -name "HAS_RX" -component $cc]
ipgui::move_param -component $cc -order 0 $p -parent $general_group
set_property -dict [list widget "checkBox" display_name "Enable I2S Receiver Support"] $p

set p [ipgui::get_guiparamspec -name "HAS_TX" -component $cc]
ipgui::move_param -component $cc -order 1 $p -parent $general_group
set_property -dict [list widget "checkBox" display_name "Enable I2S Transmitter Support"] $p

set p [ipgui::get_guiparamspec -name "DMA_TYPE" -component $cc]
ipgui::move_param -component $cc -order 2 $p -parent $general_group
set_property -dict [list widget "comboBox" display_name "DMA Interface Type"] $p

set p [ipgui::get_guiparamspec -name "NUM_OF_CHANNEL" -component $cc]
ipgui::move_param -component $cc -order 3 $p -parent $general_group
set_property -dict [list display_name "Number of Audio Channels"] $p

set p [ipgui::get_guiparamspec -name "S_AXI_ADDRESS_WIDTH" -component $cc]
ipgui::move_param -component $cc -order 4 $p -parent $general_group
set_property -dict [list display_name "AXI Address Width"] $p

ipgui::remove_param -component $cc [ipgui::get_guiparamspec -name "S_AXI_DATA_WIDTH" -component $cc -quiet]
ipgui::remove_param -component $cc [ipgui::get_guiparamspec -name "DEVICE_FAMILY" -component $cc -quiet]

# Завершение
ipx::check_integrity $cc
ipx::create_xgui_files $cc
ipx::update_checksums $cc
ipx::save_core $cc
close_project

puts "IP '$ip_name' successfully packaged in '$ip_output_dir'"