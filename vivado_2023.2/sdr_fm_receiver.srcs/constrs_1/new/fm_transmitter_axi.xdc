# =============================================================================
#  fm_transmitter_axi -- timing constraints for clk_rf = 250 MHz
# =============================================================================
#
#  CONFIRMED WORKING: report_timing_summary on the real build now shows
#  WNS = +0.395ns, TNS = 0.000, 0 failing endpoints out of 41550, "All user
#  specified timing constraints are met." clk_out3 (clk_audio) no longer
#  appears anywhere paired with clk_out1 (clk_rf) in the Inter Clock Table --
#  the crossing is correctly excluded from setup/hold analysis.
#
#  Full clock map, now confirmed from the Clock Summary table of a real run:
#    clk_out1_design_1_clk_wiz_0_0 = 250.000 MHz = clk_rf
#    clk_out2_design_1_clk_wiz_0_0 =  50.000 MHz = s_axi_aclk
#    clk_out3_design_1_clk_wiz_0_0 =  12.295 MHz = clk_audio
#
#  Section 1 below now uses all three literal names -- previously s_axi_aclk
#  was resolved via a pin (get_clocks -of_objects [get_pins ...]) because I
#  had no confirmed name for it; that pin-based approach is also what silently
#  failed for clk_audio earlier, for a reason I never fully root-caused (an
#  interactive get_cells -hier in the Tcl console found the same cells fine,
#  so plain hierarchical search works -- the failure was specific to how the
#  auto-applied XDC file evaluated get_clocks -of_objects on it). Now that all
#  three names are confirmed from real data, there's no reason to keep that
#  indirection anywhere in this file.
#
#  Note this one for the record, not because anything is currently broken:
#  clk_out2 (50MHz) x clk_out1 (250MHz) is an exact 5x integer ratio, so it
#  already passed normal synchronous analysis on its own (Requirement:
#  4.000ns, comfortable margin) even before this group existed -- clk_out3's
#  ratio (12.295MHz vs 250MHz = not an integer) is what forced Vivado into a
#  razor-thin worst-case edge alignment and is why only that crossing showed
#  up as a hard violation. Grouping s_axi_aclk here anyway is still the
#  functionally correct thing to do (ftw_sync/dev_sync are 2FF-synchronised
#  CDC by design, not "coincidentally-timed" logic), it just wasn't the one
#  keeping WNS negative.
# =============================================================================

# ---- 1. The three domains are asynchronous --------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks clk_out3_design_1_clk_wiz_0_0] \
    -group [get_clocks -include_generated_clocks clk_out1_design_1_clk_wiz_0_0] \
    -group [get_clocks -include_generated_clocks clk_out2_design_1_clk_wiz_0_0]
