# Generated at 2026-10-12 23:07

set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6
add_design "D:/riscv/RISCV/ipcore/data_ram/rtl/ipm2l_spram_v1_8_data_ram.v"
add_design "D:/riscv/RISCV/ipcore/data_ram/data_ram.v"
compile -top_module data_ram
synthesize -ads
