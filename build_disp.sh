#!/bin/bash
export PATH=/opt/quartus/quartus/bin:$PATH
cd /root/hyb_ay/GottFA80_PLuS_HW21x_Cyclone_10
quartus_sh --flow compile SYS80 > /root/hyb_ay/build_disp_full.log 2>&1
RC=$?
echo "COMPILE RC=$RC"
if [ $RC -ne 0 ]; then grep -iE "^Error" /root/hyb_ay/build_disp_full.log | head -8; exit 1; fi
quartus_cpf -c -q 6MHz -g 3.3 -n p output_files/SYS80.sof output_files/SYS80_disp.svf >/dev/null 2>&1
echo "CPF RC=$?"
md5sum output_files/SYS80_disp.svf
