--
-- generate 892Khz clock for Gottlieb MPU from 50Mhz system clock
-- part of GottFA
-- bontango 01.2021
--

LIBRARY ieee;
USE ieee.std_logic_1164.all;

	entity cpu_clk_gen is
		port(
                clk_in  : in std_logic;                
                cpu_clk_out : out std_logic
            );
    end cpu_clk_gen;
	 
   architecture Behavioral of cpu_clk_gen is
	   signal q_cpuClkCount : integer range 0 to 100;
		--signal q_cpuClkCount	: std_logic_vector(6 downto 0); 
    begin
		cpu_clk_gen: process (clk_in)
			begin
				if rising_edge(clk_in) then
					if q_cpuClkCount < 56 then		
						q_cpuClkCount <= q_cpuClkCount + 1;
					else
						q_cpuClkCount <= 0;
					end if;
					if q_cpuClkCount < 28 then		
						cpu_clk_out <= '0';
					else
						cpu_clk_out <= '1';
					end if;
				end if;
			end process;
    end Behavioral;				

-- CPU Clock

-- CPU frequency 	Counter top 	Counter half-way
-- 532Khz if cpuClkCount < 93 then 	if cpuClkCount < 47 then
-- 806Khz if cpuClkCount < 62 then 	if cpuClkCount < 31 then
-- 835Khz if cpuClkCount < 60 then 	if cpuClkCount < 30 then
-- ==> 892Khz if cpuClkCount < 56 then 	if cpuClkCount < 28 then
--1MHz 	if cpuClkCount < 49 then 	if cpuClkCount < 25 then
--2MHz 	if cpuClkCount < 24 then 	if cpuClkCount < 12 then
--5MHz 	if cpuClkCount < 9 then 	if cpuClkCount < 4 then
--10MHz 	if cpuClkCount < 4 then 	if cpuClkCount < 2 then
--12.5MHz 	if cpuClkCount < 3 then 	if cpuClkCount < 2 then
--16.6MHz 	if cpuClkCount < 2 then 	if cpuClkCount < 2 then
--25MHz 	if cpuClkCount < 1 then 	if cpuClkCount < 1 then	

    