# ----------------------------------------
# JasperGold Version Info
# tool      : JasperGold 2021.06
# platform  : Linux 4.18.0-553.34.1.el8_10.x86_64
# version   : 2021.06p001 64 bits
# build date: 2021.07.27 03:20:16 UTC
# ----------------------------------------
# started   : 2025-02-23 11:49:00 EST
# hostname  : caen-vnc-mi02.engin.umich.edu.(none)
# pid       : 2894711
# arguments : '-label' 'session_0' '-console' '//127.0.0.1:34631' '-style' 'windows' '-data' 'AAAAxHicPYxNDgFREIS/YWPpCC7gzQVmO1ZEYiG2MkNIsJgfCRtXdZPnm0d00lVd3dWVAcUrxkiq8VOYsmTFhlJcs5VR5fS0NHLFngM3p4XOkh0XrqrafWfn6rOuwdOK4XcJ6bNO++GaKnt/mSITRvaEuebKEJgZ8NDecTL27lNj9NFd+Hv4AHjIHtw=' '-proj' '/home/jsstchur/EECS_470/p4-w25.group9/jgproject/sessionLogs/session_0' '-init' '-hidden' '/home/jsstchur/EECS_470/p4-w25.group9/jgproject/.tmp/.initCmds.tcl' 'synth/verify.tcl'
clear -all
# Add files to include here
analyze -sv09 verilog/ROB.sv verilog/FIFO_sva.svh verilog/FIFO_fv.sv verilog/memDP.sv
