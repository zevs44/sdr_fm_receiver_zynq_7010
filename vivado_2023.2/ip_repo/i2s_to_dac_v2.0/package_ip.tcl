# package_ip.tcl - упаковка модуля i2s_to_delta_sigma_dac в IP-библиотеку Vivado
# Запуск в Vivado: source package_ip.tcl

# ------------------------------------------------------------
# Пользовательские настройки
# ------------------------------------------------------------
set ip_name         "i2s_to_delta_sigma_dac"
set ip_version      "2.0"
set ip_vendor       "user.org"
set ip_library      "user"
set ip_display_name "I2S to Delta-Sigma DAC v2.0"
set ip_description  "I2S to 1-bit Delta-Sigma DAC"

# Список исходных файлов
set src_files [list \
    "./src_v/audio_sample_buffer.v" \
    "./src_v/delta_sigma_dac.v" \
    "./src_v/i2s_receiver.v" \
    "./src_v/i2s_ds_dac_top.v" \
]
set ip_output_dir   "./ip_repo"

# Часть ПЛИС (любая, используется только для корректности проекта)
set part_name       "xc7z010clg400-1"

# ------------------------------------------------------------
# Создаём временный проект в памяти
# ------------------------------------------------------------
create_project -in_memory -part $part_name
set_property target_language Verilog [current_project]

add_files -norecurse $src_files
set_property top i2s_to_delta_sigma_dac [current_fileset]

update_compile_order -fileset sources_1

# ------------------------------------------------------------
# Упаковка IP (настройки портов можно задать позже в GUI)
# ------------------------------------------------------------
ipx::package_project -root_dir $ip_output_dir \
                     -vendor $ip_vendor \
                     -library $ip_library \
                     -taxonomy /UserIP \
                     -import_files -force

# Метаданные IP
set_property name $ip_name                 [ipx::current_core]
set_property version $ip_version           [ipx::current_core]
set_property display_name $ip_display_name [ipx::current_core]
set_property description $ip_description   [ipx::current_core]

ipx::create_xgui_files [ipx::current_core]
ipx::update_checksums [ipx::current_core]
ipx::check_integrity  [ipx::current_core]

ipx::save_core [ipx::current_core]
close_project

puts "IP '$ip_name' successfully packaged in '$ip_output_dir'"