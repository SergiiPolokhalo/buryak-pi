--	(c) 2012 d18c7db(a)hotmail
--
--	This program is free software; you can redistribute it and/or modify it under
--	the terms of the GNU General Public License version 3 or, at your option,
--	any later version as published by the Free Software Foundation.
--
--	This program is distributed in the hope that it will be useful,
--	but WITHOUT ANY WARRANTY; without even the implied warranty of
--	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
--
-- For full details, see the GNU General Public License at www.gnu.org/licenses

--------------------------------------------------------------------------------
-- Video scan converter
--
--	Horizonal Timing
-- _____________              ______________________              _____________________
-- VIDEO (last) |____________|         VIDEO        |____________|         VIDEO (next)
-- -hD----------|-hA-|hB|-hC-|----------hD----------|-hA-|hB|-hC-|----------hD---------
-- __________________|  |________________________________|  |__________________________
-- HSYNC             |__|              HSYNC             |__|              HSYNC

-- Vertical Timing
-- _____________              ______________________              _____________________
-- VIDEO (last)||____________||||||||||VIDEO|||||||||____________||||||||||VIDEO (next)
-- -vD----------|-vA-|vB|-vC-|----------vD----------|-vA-|vB|-vC-|----------vD---------
-- __________________|  |________________________________|  |__________________________
-- VSYNC             |__|              VSYNC             |__|              VSYNC

-- Scan converter input and output timings compared to standard VGA
--	Resolution  - Frame   | Pixel      | Front     | HSYNC      | Back       | Active      | HSYNC    | Front    | VSYNC    | Back     | Active    | VSYNC
--              - Rate    | Clock      | Porch hA  | Pulse hB   | Porch hC   | Video hD    | Polarity | Porch vA | Pulse vB | Porch vC | Video vD  | Polarity
-------------------------------------------------------------------------------------------------------------------------------------------------------------
--  In  256x224 - 59.18Hz |  6.000 MHz | 38 pixels |  32 pixels |  58 pixels |  256 pixels | negative | 16 lines | 8 lines  | 16 lines | 224 lines | negative
--  Out 640x480 - 59.18Hz | 24.000 MHz |  2 pixels |  92 pixels |  34 pixels |  640 pixels | negative | 17 lines | 2 lines  | 29 lines | 480 lines | negative
--  VGA 640x480 - 59.94Hz | 25.175 MHz | 16 pixels |  96 pixels |  48 pixels |  640 pixels | negative | 10 lines | 2 lines  | 33 lines | 480 lines | negative

library ieee;
	use ieee.std_logic_1164.all;
	use ieee.std_logic_unsigned.all;
	use ieee.numeric_std.all;

entity scan_convert is
	generic (
		-- mark active area of input video
		cstart      	: integer range 0 to 1023 := 92;  -- composite sync start
		clength     	: integer range 0 to 1023 := 704;  -- composite sync length
		-- output video timing
		hA					: integer range 0 to 1023 := 48;	-- h front porch
		hB					: integer range 0 to 1023 := 64;	-- h sync
		hC					: integer range 0 to 1023 := 80;	-- h back porch
		hD					: integer range 0 to 1023 := 704;	-- visible video
	--	vA					: integer range 0 to 1023 :=  0;	-- v front porch (not used)
		vB					: integer range 0 to 1023 :=  2;	-- v sync
		vC					: integer range 0 to 1023 := 10;	-- v back porch
		vD					: integer range 0 to 1023 := 284;-- visible video - old 284
		hpad				: integer range 0 to 1023 :=  0;	-- create H black border
		vpad				: integer range 0 to 1023 :=  0	-- create V black border -- todo!!!
	);
	port (
		I_RGBI				: in  std_logic_vector(3 downto 0);
		I_HSYNC				: in  std_logic;
		I_VSYNC				: in  std_logic;

		O_RED 				: out std_logic_vector(1 downto 0);
		O_GREEN 				: out std_logic_vector(1 downto 0);
		O_BLUE 				: out std_logic_vector(1 downto 0);
		O_HSYNC				: out std_logic;
		O_VSYNC				: out std_logic;

		CLK					: in  std_logic;
		CLK_x2				: in  std_logic;

		VA						: out std_logic_vector(14 downto 0);
		D 					: inout std_logic_vector(7 downto 0);
		N_VWE					: out std_logic := '1'
	);
end;

architecture RTL of scan_convert is
	--
	-- input timing
	--
	signal ivsync_last_x2	: std_logic := '1';
	signal ihsync_last		: std_logic := '1';
	signal hpos_i			: std_logic_vector(9 downto 0) := (others => '0');

	--
	-- output timing
	--
	signal hpos_o			: std_logic_vector(9 downto 0) := (others => '0');

	signal vcnt				: std_logic_vector(9 downto 0) := (others => '0');
	signal hcnt				: std_logic_vector(9 downto 0) := (others => '0');
	signal hcnti			: std_logic_vector(9 downto 0) := (others => '0');

	signal rgbi 			: std_logic_vector(3 downto 0);
	signal wr_buf 			: std_logic_vector(7 downto 0);
	signal rd_buf 			: std_logic_vector(7 downto 0);
	signal pixel 			: std_logic_vector(3 downto 0);
	signal blank 			: std_logic;

begin

	D <= wr_buf when CLK = '1' else (others => 'Z');
	N_VWE <= not(CLK);
	VA <= "00000" & vcnt(1) & hpos_i(9 downto 1) when CLK = '1' else "00000" & not(vcnt(1)) & hpos_o(9 downto 1);
	
	-- normalize input signals
	process (CLK)
	begin 
		if falling_edge(CLK) then 
			rgbi <= I_RGBI;
		end if;
	end process;
	
	-- write 2x pixels into buffer
	process(CLK)
	begin 
		if rising_edge(CLK) then 
			if hpos_i(0) = '1' then 
				wr_buf(3 downto 0) <= rgbi;
			else 
				wr_buf(7 downto 4) <= rgbi;
			end if;
		end if;
	end process;

	-- read 2x pixels from buffer
	process(CLK_x2)
	begin 
		if (rising_edge(CLK_x2)) then 
			if CLK = '0' then 
				rd_buf <= D;
			end if;
		end if;
	end process;
	
	-- horizontal counter for input video
	p_hcounter : process (CLK, I_HSYNC, ihsync_last, hcnti)
	begin
		if CLK'event and CLK = '0' then
			ihsync_last <= I_HSYNC;
			-- trigger off rising hsync
			if I_HSYNC = '1' and ihsync_last = '0' then
				hcnti <= (others => '0');
			else
				hcnti <= hcnti + 1;
			end if;
		end if;
	end process;

	-- increment write position during active video
	p_ram_in : process (CLK, hcnti)
	begin
		if (CLK'event and CLK = '0') then
			if (hcnti < cstart) or (hcnti >= (cstart + clength)) then
				hpos_i <= (others => '0');
			else
				hpos_i <= hpos_i + 1;
			end if;
		end if;
	end process;

	-- VGA H and V counters, synchronized to input frame V sync, then H sync
	p_out_ctrs : process (CLK_x2, I_VSYNC, ivsync_last_x2, hcnt)
		variable trigger : boolean;
	begin
		if CLK_x2'event and CLK_x2 = '1' then
			ivsync_last_x2 <= I_VSYNC;
			if (I_VSYNC = '0') and (ivsync_last_x2 = '1') then
				trigger := true;
			elsif trigger and I_HSYNC = '0' then
				trigger := false;
				hcnt <= (others => '0');
				vcnt <= (others => '0');
			else
				hcnt <= hcnt + 1;
				if hcnt = (hA+hB+hC+hD+hpad+hpad-1) then
					hcnt <= (others => '0');
					vcnt <= vcnt + 1;
				end if;
			end if;
		end if;
	end process;
	
	-- generate hsync
	p_gen_hsync : process (CLK_x2)
	begin
		if CLK_x2'event and CLK_x2 = '1' then
		-- H sync timing
			if (hcnt < hB) then
				O_HSYNC <= '0';
			else
				O_HSYNC <= '1';
			end if;
		end if;
	end process;

	-- generate vsync
	p_gen_vsync : process (CLK_x2)
	begin
		if CLK_x2'event and CLK_x2 = '1' then
		-- V sync timing
			if (vcnt < vB) then
				O_VSYNC <= '0';
			else
				O_VSYNC <= '1';
			end if;
		end if;
	end process;

	-- generate video read address
	p_gen_active_vid : process (CLK_x2)
	begin
		if CLK_x2'event and CLK_x2 = '1' then
			-- visible video area doubled from the original game
			if ((hcnt >= (hB + hC + hpad)) and (hcnt < (hB + hC + hD + hpad))) and ((vcnt > 2*(vB + vC + vpad)) and (vcnt <= 2*(vB + vC + vD + vpad))) then
				hpos_o <= hpos_o + 1;
			else
				hpos_o <= (others => '0');
			end if;
		end if;
	end process;
	
	-- divide pixels from read buffer
	process (CLK_x2, CLK) 
	begin
	  if (rising_edge(CLK_x2)) then
			if CLK = '0' then 
				pixel <= rd_buf(3 downto 0);
			else 
				pixel <= rd_buf(7 downto 4);
			end if;
		end if;
	end process;
	
	-- generate blanking signal including additional borders to pad the input signal to standard VGA resolution
	p_gen_blank : process (CLK_x2)
	begin
		if CLK_x2'event and CLK_x2 = '1' then
			-- active video area 640x480 (VGA) after padding with blank borders
			if ((hcnt >= (hB + hC)) and (hcnt < (hB + hC + hD + 2*hpad))) and ((vcnt > 2*(vB + vC)) and (vcnt <= 2*(vB + vC + vD + 2*vpad))) then
				blank <= '1';
			else
				blank <= '0';
			end if;
		end if;
	end process;
	
	-- output pixels 
	process (CLK_x2) 
	begin 
		if (rising_edge(CLK_x2)) then  -- если фронт тактового импульса,

		 O_RED(0)     <= pixel(3) and blank;
		 O_GREEN(0)   <= pixel(2) and blank;
		 O_BLUE(0)    <= pixel(1) and blank;
		 
		 if (pixel(0) and blank) = '0'  then  -- если яркость пониженная:
			  O_RED(1)   <= '0'; -- уменьшаем сигнал подключением резисторов к 0
			  O_GREEN(1) <= '0';
			  O_BLUE(1)  <= '0'; 
		 else
			  O_GREEN(1) <= 'Z'; -- резисторы отключены
			  O_RED(1)   <= 'Z';
			  O_BLUE(1)  <= 'Z'; 
		 end if;

	  end if;
	end process;

end architecture RTL;