# Generated at 2026-10-12 23:07

set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6
add_design "D:/riscv/RISCV/ipcore/inst_rom/rtl/ipm2l_rom_v1_8_inst_rom.v"
add_design "D:/riscv/RISCV/ipcore/inst_rom/rtl/ipm2l_spram_v1_8_inst_rom.v"
add_design "D:/riscv/RISCV/ipcore/inst_rom/inst_rom.v"
compile -top_module inst_rom
synthesize -ads
