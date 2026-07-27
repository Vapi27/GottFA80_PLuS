#!/bin/bash
export PATH=/opt/quartus/quartus/bin:$PATH
cd /root/hyb_ay/GottFA80_PLuS_HW21x_Cyclone_10
echo "=== COMPILE START $(date) ==="
quartus_sh --flow compile SYS80
RC=$?
echo "=== COMPILE RC=$RC ==="
if [ $RC -eq 0 ]; then
  echo "=== CPF (.jic) START $(date) ==="
  quartus_cpf -c -d EPCS16 -s 10CL006YE144C8G output_files/SYS80.sof output_files/SYS80_10cl006_coilfix.jic
  echo "=== CPF RC=$? ==="
  ls -la output_files/SYS80_10cl006_coilfix.jic 2>/dev/null
fi
echo "=== ALL DONE $(date) ==="
