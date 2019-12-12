-- --------------------------------------------------------------------
-- Buriak-Pi firmware
-- v1.0
-- (c) 2019 Andy Karpov
-- --------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity firmware_top is
	port(
		-- Clock
		CLK28				: in std_logic;

		-- CPU signals
		CLK_CPU			: out std_logic := '1';
		N_RESET			: inout std_logic := 'Z';
		N_INT				: out std_logic := '1';
		N_RD				: in std_logic;
		N_WR				: in std_logic;
		N_IORQ			: in std_logic;
		N_MREQ			: in std_logic;
		N_M1				: in std_logic;
		A					: in std_logic_vector(15 downto 0);
		D 					: inout std_logic_vector(7 downto 0) := "ZZZZZZZZ";
		N_NMI 			: out std_logic := 'Z';
--		N_WAIT 			: out std_logic := 'Z';
		
		-- RAM 
		MA 				: out std_logic_vector(20 downto 0);
		MD 				: inout std_logic_vector(7 downto 0) := "ZZZZZZZZ";
		N_MRD				: out std_logic := '1';
		N_MWR				: out std_logic := '1';
		
		-- VRAM 
		VA					: out std_logic_vector(14 downto 0);
		VD 				: inout std_logic_vector(7 downto 0) := "ZZZZZZZZ";
		N_VWE 			: out std_logic := '1';

		-- ROM
		N_ROMCS			: out std_logic := '1';
		N_ROMWE			: out std_logic := '1';
		ROM_A 			: out std_logic_vector(15 downto 14) := "00";
		
		-- VGA Video
		VGA_VSYNC    		: out std_logic;
		VGA_HSYNC 			: out std_logic;
		VGA_R       		: out std_logic_vector(1 downto 0) := "00";
		VGA_G       		: out std_logic_vector(1 downto 0) := "00";
		VGA_B       		: out std_logic_vector(1 downto 0) := "00";

		-- Interfaces 
		BEEPER			: out std_logic := '1';

		-- AY
		AY_BC1			: out std_logic;
		AY_BDIR			: out std_logic;

		-- SD card
		SD_CLK 			: out std_logic := '0';
		SD_DI 			: out std_logic;
		SD_DO 			: in std_logic;
		N_SD_CS 			: out std_logic := '1';
--		SD_DETECT		: in std_logic;
		
		-- Keyboard Atmega
		KEY_SCK 			: in std_logic;
		KEY_SS 			: in std_logic;
		KEY_MOSI 		: in std_logic;
		KEY_MISO 		: out std_logic;
		
		-- Other in signals
		N_BTN_NMI			: in std_logic := '1'
	);
end firmware_top;

architecture rtl of firmware_top is

	signal clk_14 		: std_logic := '0';
	signal clk_7 		: std_logic := '0';

	signal buf_md		: std_logic_vector(7 downto 0) := "11111111";
	signal is_buf_wr	: std_logic := '0';	
	
--	signal attr_r   	: std_logic_vector(7 downto 0);
	signal rgb 	 		: std_logic_vector(2 downto 0);
	signal i 			: std_logic;
	signal vid_a 		: std_logic_vector(13 downto 0);
	signal hcnt 		: std_logic_vector(8 downto 0);
	signal vcnt 		: std_logic_vector(8 downto 0);	
	
	signal timexcfg_reg : std_logic_vector(5 downto 0);
	signal is_port_ff : std_logic := '0';	

	signal border_attr: std_logic_vector(2 downto 0) := "000";

	signal port_7ffd	: std_logic_vector(7 downto 0); -- D0-D2 - RAM page from address #C000
																	  -- D3 - video RAM page: 0 - bank5, 1 - bank7 
																	  -- D4 - ROM page A14: 0 - basic 128, 1 - basic48
																	  -- D5 - 48k RAM lock, 1 - locked, 0 - extended memory enabled
																	  -- D6 - not used
																	  -- D7 - not used
																	  
	signal ram_ext : std_logic_vector(2 downto 0) := "000";

	signal ram_ext_std: std_logic_vector(1 downto 0) := "00"; -- 00 - pentagon-512 via 6,7 bits of the #7FFD port (bit 5 is for 48k lock)
																				 -- 01 - pentagon-1024 via 5,6,7 bits of the #7FFD port (no 48k lock)
																				 -- 10 - profi-1024 via 0,1,2 bits of the #DFFD port
																				 -- 11 - pentagon-128

	signal fd_port : std_logic;
	signal fd_sel : std_logic;	
																	  
	signal ay_port		: std_logic := '0';
		
	signal vbus_req	: std_logic := '1';
	signal vbus_ack	: std_logic := '1';
	signal vbus_mode	: std_logic := '1';	
	signal vbus_rdy	: std_logic := '1';
	
	signal vid_rd		: std_logic := '0';
	
	signal hsync     	: std_logic := '1';
	signal vsync     	: std_logic := '1';

	signal n_is_ram   : std_logic := '1';
	signal ram_page	: std_logic_vector(6 downto 0) := "0000000";

	signal n_is_rom   : std_logic := '1';
	signal rom_page	: std_logic_vector(1 downto 0) := "00";
	
	signal sound_out 	: std_logic := '0';
	signal port_read	: std_logic := '0';
	signal port_write	: std_logic := '0';
	
	signal divmmc_enable : std_logic := '0';
	signal divmmc_do	: std_logic_vector(7 downto 0);
	
	signal divmmc_ram : std_logic;
	signal divmmc_rom : std_logic;
	
	signal divmmc_disable_zxrom : std_logic;
	signal divmmc_eeprom_cs_n : std_logic;
	signal divmmc_eeprom_we_n : std_logic;
	signal divmmc_sram_cs_n : std_logic;
	signal divmmc_sram_we_n : std_logic;
	signal divmmc_sram_hiaddr : std_logic_vector(5 downto 0);
	signal divmmc_sd_cs_n : std_logic;
	signal divmmc_wr : std_logic;
	
	signal kb : std_logic_vector(4 downto 0) := "11111";
	signal joy : std_logic_vector(4 downto 0) := "11111";
	signal nmi : std_logic;
	signal i_vga : std_logic_vector(2 downto 0) := "000";
	signal reset : std_logic;
	signal turbo : std_logic; -- TODO
	
	-- ZXUNO ports
	signal zxuno_regrd : std_logic;
	signal zxuno_regwr : std_logic;
	signal zxuno_addr : std_logic_vector(7 downto 0);
	signal zxuno_regaddr_changed : std_logic;
	signal zxuno_addr_oe_n : std_logic;
	signal zxuno_addr_to_cpu : std_logic_vector(7 downto 0);

	-- UART 
	signal uart_oe_n   : std_logic := '1';
	signal uart_do_bus : std_logic_vector(7 downto 0);
	
	-- UART - AVR signals
	signal uart_avr_txdata : std_logic_vector(7 downto 0);
	signal uart_avr_txbegin : std_logic;
	signal uart_avr_txbusy : std_logic;
	signal uart_avr_rxdata : std_logic_vector(7 downto 0);
	signal uart_avr_rxrecv : std_logic;
	signal uart_avr_data_read : std_logic;
	
	component zxunoregs
	port (
		clk: in std_logic;
		rst_n : in std_logic;
		a : in std_logic_vector(15 downto 0);
		iorq_n : in std_logic;
		rd_n : in std_logic;
		wr_n : in std_logic;
		din : in std_logic_vector(7 downto 0);
		dout : out std_logic_vector(7 downto 0);
		oe_n : out std_logic;
		addr : out std_logic_vector(7 downto 0);
		read_from_reg: out std_logic;
		write_to_reg: out std_logic;
		regaddr_changed: out std_logic);
	end component;
	
	component zxunouart
	port (
		clk : in std_logic;
		zxuno_addr : in std_logic_vector(7 downto 0);
		zxuno_regrd : in std_logic;
		zxuno_regwr : in std_logic;
		din : in std_logic_vector(7 downto 0);
		dout : out std_logic_vector(7 downto 0);
		oe_n : out std_logic;
		
      txdata : out std_logic_vector(7 downto 0);
      txbegin : out std_logic;
      txbusy : in std_logic;
      rxdata : in std_logic_vector(7 downto 0);
      rxrecv : out std_logic;
      data_read : out std_logic		
		);
	end component;

begin

	ram_ext_std <= "10"; -- profi-1024

	divmmc_rom <= '1' when (divmmc_disable_zxrom = '1' and divmmc_eeprom_cs_n = '0') else '0';
	divmmc_ram <= '1' when (divmmc_disable_zxrom = '1' and divmmc_sram_cs_n = '0') else '0';
	
	n_is_rom <= '0' when N_MREQ = '0' and ((A(15 downto 14)  = "00" and divmmc_rom = '0' and divmmc_ram = '0') or divmmc_rom = '1') else '1';
	n_is_ram <= '0' when N_MREQ = '0' and ((A(15 downto 14) /= "00" and divmmc_rom = '0' and divmmc_ram = '0') or divmmc_ram = '1') else '1';

	-- speccy ROM banks map (A14, A15):
	-- 00 - bank 0, ESXDOS 0.8.7
	-- 01 - bank 1, empty
	-- 10 - bank 2, Basic-128
	-- 11 - bank 3, Basic-48
	rom_page <= "00" when divmmc_rom = '1' else '1' & (port_7ffd(4));
	ROM_A(14) <= rom_page(0);
	ROM_A(15) <= rom_page(1);	
	
	N_ROMCS <= '0' when n_is_rom = '0' and N_RD = '0' else '1';
	N_ROMWE <= '1';

	ram_page <=	
				"10" & divmmc_sram_hiaddr(5 downto 1) when divmmc_ram = '1' else
				"0000000" when A(15) = '0' and A(14) = '0' else
				"0000101" when A(15) = '0' and A(14) = '1' else
				"0000010" when A(15) = '1' and A(14) = '0' else
				"0" & ram_ext(2 downto 0) & port_7ffd(2 downto 0);

	MA(13 downto 0) <= 
		divmmc_sram_hiaddr(0) & A(12 downto 0) when vbus_mode = '0' and divmmc_ram = '1' else -- divmmc ram 
		A(13 downto 0) when vbus_mode = '0' else -- spectrum ram 
		vid_a; -- video ram

	MA(14) <= ram_page(0) when vbus_mode = '0' else '1';
	MA(15) <= ram_page(1) when vbus_mode = '0' else port_7ffd(3);
	MA(16) <= ram_page(2) when vbus_mode = '0' else '1';
	MA(17) <= ram_page(3) when vbus_mode = '0' else '0';
	MA(18) <= ram_page(4) when vbus_mode = '0' else '0';
	MA(19) <= ram_page(5) when vbus_mode = '0' else '0';
	MA(20) <= ram_page(6) when vbus_mode = '0' else '0';
	
	MD(7 downto 0) <= 
		D(7 downto 0) when vbus_mode = '0' and ((n_is_ram = '0' or (N_IORQ = '0' and N_M1 = '1')) and N_WR = '0') else 
		(others => 'Z');

	vbus_req <= '0' when ( N_MREQ = '0' or N_IORQ = '0' ) and ( N_WR = '0' or N_RD = '0' ) else '1';
	vbus_rdy <= '0' when clk_7 = '0' or hcnt(0) = '0' else '1';
	
	N_MRD <= '0' when (vbus_mode = '1' and vbus_rdy = '0') or (vbus_mode = '0' and N_RD = '0' and N_MREQ = '0') else '1';  
	N_MWR <= '0' when vbus_mode = '0' and n_is_ram = '0' and N_WR = '0' and hcnt(0) = '0' else '1';

	BEEPER <= sound_out;

	ay_port <= '1' when A(7 downto 0) = x"FD" and A(15)='1' and fd_port = '1' else '0';
	AY_BC1 <= '1' when ay_port = '1' and A(14) = '1' and N_IORQ = '0' and (N_WR='0' or N_RD='0') else '0';
	AY_BDIR <= '1' when ay_port = '1' and N_IORQ = '0' and N_WR = '0' else '0';
	
	is_buf_wr <= '1' when vbus_mode = '0' and hcnt(0) = '0' else '0';
	
	N_NMI <= '0' when N_BTN_NMI = '0' or nmi = '0' else '1';
	N_RESET <= '0' when reset = '0' else 'Z';
	
	 -- #FD port correction
	 fd_sel <= '0' when vbus_mode='0' and D(7 downto 4) = "1101" and D(2 downto 0) = "011" else '1'; -- IN, OUT Z80 Command Latch

	 process(fd_sel, N_M1, N_RESET)
	 begin
			if N_RESET='0' then
				  fd_port <= '1';
			elsif rising_edge(N_M1) then 
				  fd_port <= fd_sel;
			end if;
	 end process;

	-- CPU clock 
	process( N_RESET, clk_14, clk_7, hcnt )
	begin
		if clk_14'event and clk_14 = '1' then
			if clk_7 = '1' then
				CLK_CPU <= hcnt(0);
			end if;
		end if;
	end process;
	
	port_write <= '1' when N_IORQ = '0' and N_WR = '0' and N_M1 = '1' and vbus_mode = '0' else '0';
	port_read <= '1' when N_IORQ = '0' and N_RD = '0' and N_M1 = '1' else '0';
	
	-- read ports by CPU
	D(7 downto 0) <= 
		buf_md(7 downto 0) when n_is_ram = '0' and N_RD = '0' else 		 -- MD buf	
		port_7ffd when port_read = '1' and A(15)='0' and A(1)='0' else  -- #7FFD - system port 
		"111" & kb(4 downto 0) when port_read = '1' and A(0) = '0' else -- #FE - keyboard 
		"000" & joy when port_read = '1' and A(7 downto 0) = X"1F" else -- #1F - kempston joy
		divmmc_do when divmmc_wr = '1' else 									 -- divMMC
		zxuno_addr_to_cpu when zxuno_addr_oe_n = '0' else 					 -- ZXUNO control register
		uart_do_bus when uart_oe_n = '0' else									 -- ZXUNO UART
		--"00" & timexcfg_reg when port_read = '1' and A(7 downto 0) = x"FF" and is_port_ff = '1' else -- #FF (timex config)
		--attr_r when port_read = '1' and A(7 downto 0) = x"FF" and is_port_ff = '0' else -- #FF - attributes (timex port never set)
		"ZZZZZZZZ";

	divmmc_enable <= '1';
	
	-- clocks
	process (CLK28)
	begin 
		if (CLK28'event and CLK28 = '1') then 
			clk_14 <= not(clk_14);
		end if;
	end process;
	
	process (clk_14)
	begin 
		if (clk_14'event and clk_14 = '1') then 
			clk_7 <= not(clk_7);
		end if;
	end process;
	
	-- fill memory buf
	process(is_buf_wr)
	begin 
		if (is_buf_wr'event and is_buf_wr = '0') then  -- high to low transition to lattch the MD into BUF
			buf_md(7 downto 0) <= MD(7 downto 0);
		end if;
	end process;	
	
	-- video mem
	process( clk_14, clk_7, hcnt, vbus_mode, vid_rd, vbus_req, vbus_ack )
	begin
		-- lower edge of 7 mhz clock
		if clk_14'event and clk_14 = '1' then 
			if hcnt(0) = '1' and clk_7 = '0' then
				if vbus_req = '0' and vbus_ack = '1' then
					vbus_mode <= '0';
				else
					vbus_mode <= '1';
					vid_rd <= not vid_rd;
				end if;	
				vbus_ack <= vbus_req;
			end if;
		end if;
	end process;

	-- ports, write by CPU
	process( clk_14, clk_7, N_RESET, A, D, port_write, port_7ffd, N_M1, N_MREQ, ram_ext_std )
	begin
		if N_RESET = '0' then
			port_7ffd <= "00000000";
			ram_ext <= "000";
			sound_out <= '0';
			timexcfg_reg <= (others => '0');
			is_port_ff <= '0';
		elsif clk_14'event and clk_14 = '1' then 
			if clk_7 = '1' then
				if port_write = '1' then

					 -- port #7FFD  
					if A(15)='0' and A(1) = '0' then -- short decoding #FD
						if ram_ext_std = "00" and port_7ffd(5) = '0' then -- penragon-512
							port_7ffd <= D;
							ram_ext <= '0' & D(6) & D(7); 
						elsif ram_ext_std = "01" then -- pentagon-1024
							port_7ffd <= D;
							ram_ext <= D(5) & D(6) & D(7);
						elsif ram_ext_std = "10" and port_7ffd(5) = '0' then -- profi 1024
							port_7ffd <= D;
						elsif ram_ext_std = "11" and port_7ffd(5) = '0' then -- pentagon-128
							port_7ffd <= D;
							ram_ext <= "000";
						end if;
					end if;
					
					-- port #DFFD (profi ram ext)
					if ram_ext_std = "10" and A = X"DFFD" and port_7ffd(5) = '0' and fd_port='1' then
							ram_ext <= D(2 downto 0);
					end if;
					
					-- port #FE
					if A(0) = '0' then
						border_attr <= D(2 downto 0); -- border attr
						sound_out <= D(4); -- BEEPER
					end if;
					
					-- port FF / timex CFG
					if (A(7 downto 0) = X"FF") then 
						timexcfg_reg(5 downto 0) <= D(5 downto 0);
						is_port_ff <= '1';
					end if;
					
				end if;
				
			end if;
		end if;
	end process;	

	-- divmmc interface
	U1: entity work.divmmc
	port map (
		I_CLK		=> CLK28,
		I_CS		=> divmmc_enable,
		I_RESET		=> not(N_RESET),
		I_ADDR		=> A,
		I_DATA		=> D,
		O_DATA		=> divmmc_do,
		I_WR_N		=> N_WR,
		I_RD_N		=> N_RD,
		I_IORQ_N		=> N_IORQ,
		I_MREQ_N		=> N_MREQ,
		I_M1_N		=> N_M1,
		
		O_WR 				 => divmmc_wr,
		O_DISABLE_ZXROM => divmmc_disable_zxrom,
		O_EEPROM_CS_N 	 => divmmc_eeprom_cs_n,
		O_EEPROM_WE_N 	 => divmmc_eeprom_we_n,
		O_SRAM_CS_N 	 => divmmc_sram_cs_n,
		O_SRAM_WE_N 	 => divmmc_sram_we_n,
		O_SRAM_HIADDR	 => divmmc_sram_hiaddr,
		
		O_CS_N		=> divmmc_sd_cs_n,
		O_SCLK		=> SD_CLK,
		O_MOSI		=> SD_DI,
		I_MISO		=> SD_DO);
		
	N_SD_CS <= divmmc_sd_cs_n;
	
	-- keyboard
	U2: entity work.cpld_kbd 
	port map (
		CLK => CLK28,
		
		A => A(15 downto 8),
		KB => kb,
		
		AVR_SCK => KEY_SCK,
		AVR_MOSI => KEY_MOSI,
		AVR_MISO => KEY_MISO,
		AVR_SS => KEY_SS,
		
		O_RESET => reset,
		O_TURBO => turbo,
		O_MAGICK => nmi,
		O_JOY => joy,

		UART_TXDATA => uart_avr_txdata,
		UART_TXBEGIN => uart_avr_txbegin,
		UART_TXBUSY => uart_avr_txbusy,
		UART_RXDATA => uart_avr_rxdata,
		UART_RXRECV => uart_avr_rxrecv,
		UART_DATA_READ => uart_avr_data_read
	);
	
	-- video module
	U3: entity work.video 
	port map (
		CLK => CLK_14,
		ENA7 => CLK_7,
		BORDER => border_attr,
		TIMEXCFG => timexcfg_reg,
		DI => MD,
		TURBO => '0', -- TODO: turbo mode
		INTA => '0', -- TOOD: int end for turbo
		INT => N_INT,
		ATTR_O => open, --attr_r, 
		A => vid_a,
		BLANK => open,
		RGB => rgb,
		I => i,
		HSYNC => hsync,
		VSYNC => vsync,
		VBUS_MODE => vbus_mode,
		VID_RD => vid_rd,
		HCNT_O => hcnt,
		VCNT_O => vcnt
	);
	
	-- scandoubler
	U4: entity work.vga_pal 
	port map (
		RGBI_IN => rgb & i,
      HSYNC_IN => hsync,
		VSYNC_IN => vsync,
		HCNT_IN => hcnt,
		VCNT_IN => vcnt,
		F28 => CLK28,
		F14 => CLK_14,
		F7 => CLK_7,
		R_VGA => VGA_R,
		G_VGA => VGA_G,
		B_VGA => VGA_B,
		HSYNC_VGA => VGA_HSYNC,
		VSYNC_VGA => VGA_VSYNC,
		A => VA,
		WE => N_VWE,
		D => VD
	);	

-- -- alternate scandoubler implementation
--	U4: entity work.scan_convert 
--	port map ( 
--		I_RGBI => rgb & i,
--		I_HSYNC => hsync,
--		I_VSYNC => vsync,
--		
--		O_RED => VGA_R,
--		O_BLUE => VGA_B,
--		O_GREEN => VGA_G,
--		O_HSYNC => VGA_HSYNC,
--		O_VSYNC => VGA_VSYNC,
--		
--		CLK => CLK_14,
--		CLK_x2 => CLK28,
--		
--		VA => VA,
--		D => VD,
--		N_VWE => N_VWE
--	);

	-- UART (via ZX UNO ports #FC3B / #FD3B) 
	U5: zxunoregs 
	port map(
		clk => CLK28,
		rst_n => N_RESET,
		a => A,
		iorq_n => N_IORQ,
		rd_n => N_RD,
		wr_n => N_WR,
		din => D,
		dout => zxuno_addr_to_cpu,
		oe_n => zxuno_addr_oe_n,
		addr => zxuno_addr,
		read_from_reg => zxuno_regrd,
		write_to_reg => zxuno_regwr,
		regaddr_changed => zxuno_regaddr_changed);

	U6: zxunouart 
	port map(
		clk => CLK_7,
		zxuno_addr => zxuno_addr,
		zxuno_regrd => zxuno_regrd,
		zxuno_regwr => zxuno_regwr,
		din => D,
		dout => uart_do_bus,
		oe_n => uart_oe_n,
		
		txdata => uart_avr_txdata,
      txbegin => uart_avr_txbegin,
      txbusy => uart_avr_txbusy,
      rxdata => uart_avr_rxdata,
      rxrecv => uart_avr_rxrecv,
      data_read => uart_avr_data_read
);
	
end;
