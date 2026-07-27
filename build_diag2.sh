#!/bin/bash
export PATH=/opt/quartus/quartus/bin:$PATH
cd /root/hyb_ay/GottFA80_PLuS_HW21x_Cyclone_10
quartus_sh --flow compile SYS80 > /dev/null 2>&1
RC=$?
echo "COMPILE RC=$RC"
if [ $RC -eq 0 ]; then
  quartus_cpf -c -q 6MHz -g 3.3 -n p output_files/SYS80.sof output_files/SYS80_diag2.svf > /dev/null 2>&1
  echo "CPF RC=$?"
  md5sum output_files/SYS80_diag2.svf
  # jic aussi (pour graver en permanent quand validé)
  quartus_cpf -c -d EPCS16 -s 10CL006YE144C8G output_files/SYS80.sof output_files/SYS80_10cl006_diag2.jic > /dev/null 2>&1
  md5sum output_files/SYS80_10cl006_diag2.jic
fi
echo "ALL DONE"
