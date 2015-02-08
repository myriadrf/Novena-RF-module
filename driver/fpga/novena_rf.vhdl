------------------------------------------------------------------------
-- FPGA design for Novena-RF SDR
-- Top level design for Novena-RF:
-- Contains register space, register capture,
-- memory to stream, framer, and deframer.
--
-- Copyright (c) 2015-2015 Lime Microsystems
-- Copyright (c) 2015-2015 Andrew "bunnie" Huang
-- SPDX-License-Identifier: Apache-2.0
-- http://www.apache.org/licenses/LICENSE-2.0
------------------------------------------------------------------------

library work;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
library UNISIM;
use UNISIM.VComponents.all;

entity novena_rf is
    port(
        -- EIM signals
        EIM_BCLK : in std_logic;
        EIM_CS : in std_logic_vector(1 downto 0);
        EIM_DA : inout std_logic_vector(15 downto 0);
        EIM_A : in std_logic_vector(18 downto 16);
        EIM_LBA : in std_logic;
        EIM_OE : in std_logic;
        EIM_RW : in std_logic;
        EIM_WAIT : out std_logic;

        --misc clocks and reset
        clk_in : in std_logic; -- use with lms data
        CLK2_N : in std_logic;
        CLK2_P : in std_logic;-- 50MHz clock diff input
        FPGA_LED2 : out std_logic;
        APOPTOSIS : out std_logic;
        RESETBMCU : in std_logic;

        --lms control signals
        lms_rxen : out std_logic;
        lms_txen : out std_logic;
        lms_lmsrst : out std_logic;

        --spi to lms
        lms_sen : out std_logic;
        lms_sclk : out std_logic;
        lms_miso : in std_logic;
        lms_mosi : out std_logic;

        --spi from cpu
        cpu_sen : in std_logic;
        cpu_sclk : in std_logic;
        cpu_miso : out std_logic;
        cpu_mosi : in std_logic;

        --lms data buses
        TXIQSEL : out std_logic;
        TXD : out std_logic_vector(11 downto 0);
        RXIQSEL : in std_logic;
        RXD : in std_logic_vector(11 downto 0)
    );
end entity novena_rf;

architecture rtl of novena_rf is

    --register constants
    constant REG_SENTINEL_VALUE : natural := 16#5246#;
    constant REG_VERSION_VALUE : natural := 16#0001#;
    constant REG_SENTINEL_ADDR : natural := 0;
    constant REG_VERSION_ADDR : natural := 2;
    constant REG_RESET_ADDR : natural := 4;
    constant REG_LOOPBACK_ADDR : natural := 6;
    constant REG_LMS_GPIO_ADDR : natural := 8;

    constant REG_TIME_LO_ADDR : natural := 20;
    constant REG_TIME_ME_ADDR : natural := 22;
    constant REG_TIME_HI_ADDR : natural := 24;
    constant REG_TIME_EX_ADDR : natural := 26;
    constant REG_TIME_CTRL_ADDR : natural := 28;

    constant REG_S2MM_FRAMER0_CTRL_LO_ADDR : natural := 32;
    constant REG_S2MM_FRAMER0_CTRL_HI_ADDR : natural := 34;
    constant REG_MM2S_FRAMER0_CTRL_LO_ADDR : natural := 36;
    constant REG_MM2S_FRAMER0_CTRL_HI_ADDR : natural := 38;
    constant REG_S2MM_DEFRAMER0_CTRL_LO_ADDR : natural := 40;
    constant REG_S2MM_DEFRAMER0_CTRL_HI_ADDR : natural := 42;
    constant REG_MM2S_DEFRAMER0_CTRL_LO_ADDR : natural := 44;
    constant REG_MM2S_DEFRAMER0_CTRL_HI_ADDR : natural := 46;
    constant REG_ALL_DMA_FIFO_RV_CTRLS_ADDR : natural := 48;

    --time registers for framer/deframer
    signal if_time : unsigned(63 downto 0);
    signal if_time_rd : std_logic_vector(63 downto 0) := (others => '0');
    signal if_time_wr : std_logic_vector(63 downto 0) := (others => '0');
    signal if_time_reg_out : boolean := false;
    signal if_time_reg_in : boolean := false;

    --bus from EIM
    signal bus_clk : std_logic;
    signal bus_rst : std_logic;
    signal bus_sel : std_logic;
    signal bus_wr : std_logic;
    signal bus_addr : std_logic_vector(18 downto 0);
    signal bus_data_wr : std_logic_vector(15 downto 0);
    signal bus_data_rd : std_logic_vector(15 downto 0);

    --register bus
    signal reg_sel : std_logic;
    signal reg_wr : std_logic;
    signal reg_addr : std_logic_vector(15 downto 0);
    signal reg_data_wr : std_logic_vector(15 downto 0);
    signal reg_data_rd : std_logic_vector(15 downto 0);

    --ram test bus
    signal test0_sel : std_logic;
    signal test0_wr : std_logic;
    signal test0_addr : std_logic_vector(15 downto 0);
    signal test0_data_wr : std_logic_vector(15 downto 0);
    signal test0_data_rd : std_logic_vector(15 downto 0);
    signal Wr : std_logic;
    signal Wr_addr : natural range 0 to 15;
    signal Rd_addr : natural range 0 to 15;
    signal Wr_data : std_ulogic_vector(15 downto 0);
    signal Rd_data : std_ulogic_vector(15 downto 0);

    --framer signals
    signal framer0_sel : std_logic;
    signal framer0_wr : std_logic;
    signal framer0_addr : std_logic_vector(15 downto 0);
    signal framer0_data_wr : std_logic_vector(15 downto 0);
    signal framer0_data_rd : std_logic_vector(15 downto 0);

    signal framer0_rxd_data : std_logic_vector(31 downto 0);
    signal framer0_rxd_last : std_logic;
    signal framer0_rxd_valid : std_logic;
    signal framer0_rxd_ready : std_logic;

    signal framer0_ctrl_data : std_logic_vector(31 downto 0);
    signal framer0_ctrl_last : std_logic;
    signal framer0_ctrl_valid : std_logic;
    signal framer0_ctrl_ready : std_logic;

    --deframer signals
    signal deframer0_sel : std_logic;
    signal deframer0_wr : std_logic;
    signal deframer0_addr : std_logic_vector(15 downto 0);
    signal deframer0_data_wr : std_logic_vector(15 downto 0);
    signal deframer0_data_rd : std_logic_vector(15 downto 0);

    signal deframer0_txd_data : std_logic_vector(31 downto 0);
    signal deframer0_txd_last : std_logic;
    signal deframer0_txd_valid : std_logic;
    signal deframer0_txd_ready : std_logic;

    signal deframer0_stat_data : std_logic_vector(31 downto 0);
    signal deframer0_stat_last : std_logic;
    signal deframer0_stat_valid : std_logic;
    signal deframer0_stat_ready : std_logic;

    --dma control and status signals
    signal dma_ctrl_data : std_logic_vector(31 downto 0); --setting for all DMAs
    signal dma_stat_data : std_logic_vector(31 downto 0); --readback for all DMAs
    signal s2mm_framer0_ctrl_valid : std_logic;
    signal s2mm_framer0_ctrl_ready : std_logic;
    signal s2mm_framer0_stat_data : std_logic_vector(31 downto 0);
    signal s2mm_framer0_stat_valid : std_logic;
    signal s2mm_framer0_stat_ready : std_logic;
    signal mm2s_framer0_ctrl_valid : std_logic;
    signal mm2s_framer0_ctrl_ready : std_logic;
    signal s2mm_deframer0_ctrl_valid : std_logic;
    signal s2mm_deframer0_ctrl_ready : std_logic;
    signal s2mm_deframer0_stat_data : std_logic_vector(31 downto 0);
    signal s2mm_deframer0_stat_valid : std_logic;
    signal s2mm_deframer0_stat_ready : std_logic;
    signal mm2s_deframer0_ctrl_valid : std_logic;
    signal mm2s_deframer0_ctrl_ready : std_logic;

    signal lms_clk : std_logic;
    signal lms_rst : std_logic;

    signal loopback_test : std_logic_vector(15 downto 0) := (others => '0');
begin

    --------------------------------------------------------------------
    -- register interface
    --------------------------------------------------------------------
    process (lms_clk, bus_clk, reg_addr, reg_sel, reg_wr)
        variable addr_num : natural;
    begin
        addr_num := to_integer(unsigned(reg_addr(7 downto 0)));

        --handle register writes
        if (rising_edge(bus_clk)) then
            if (reg_sel = '1' and reg_wr = '1') then
                if (addr_num = REG_RESET_ADDR) then
                    bus_rst <= reg_data_wr(0);
                elsif (addr_num = REG_LOOPBACK_ADDR) then
                    loopback_test <= reg_data_wr;
                elsif (addr_num = REG_LMS_GPIO_ADDR) then
                    lms_lmsrst <= reg_data_wr(0);
                    lms_rxen <= reg_data_wr(1);
                    lms_txen <= reg_data_wr(2);
                elsif (addr_num = REG_TIME_LO_ADDR) then
                    if_time_wr(15 downto 0) <= reg_data_wr;
                elsif (addr_num = REG_TIME_ME_ADDR) then
                    if_time_wr(31 downto 16) <= reg_data_wr;
                elsif (addr_num = REG_TIME_HI_ADDR) then
                    if_time_wr(47 downto 32) <= reg_data_wr;
                elsif (addr_num = REG_TIME_EX_ADDR) then
                    if_time_wr(63 downto 48) <= reg_data_wr;
                elsif (addr_num = REG_TIME_CTRL_ADDR) then
                    if_time_reg_out <= reg_data_wr(0) = '1';
                    if_time_reg_in <= reg_data_wr(1) = '1';
                end if;
            end if;
        end if;

        --handle register reads
        if (reg_sel = '1' and reg_wr = '0') then
            if (addr_num = REG_SENTINEL_ADDR) then --sentinel
                reg_data_rd <= std_logic_vector(to_unsigned(REG_SENTINEL_VALUE, 16));
            elsif (addr_num = REG_VERSION_ADDR) then --sentinel
                reg_data_rd <= std_logic_vector(to_unsigned(REG_VERSION_VALUE, 16));
            elsif (addr_num = REG_LOOPBACK_ADDR) then
                reg_data_rd <= loopback_test;
            elsif (addr_num = REG_TIME_LO_ADDR) then
                reg_data_rd <= if_time_rd(15 downto 0);
            elsif (addr_num = REG_TIME_ME_ADDR) then
                reg_data_rd <= if_time_rd(31 downto 16);
            elsif (addr_num = REG_TIME_HI_ADDR) then
                reg_data_rd <= if_time_rd(47 downto 32);
            elsif (addr_num = REG_TIME_EX_ADDR) then
                reg_data_rd <= if_time_rd(63 downto 48);
            else
                reg_data_rd <= (others => '1');
            end if;
        end if;

    end process;

    --------------------------------------------------------------------
    -- timer state machine
    --------------------------------------------------------------------
    process (lms_clk) begin
        if (rising_edge(lms_clk)) then
            if (lms_rst = '1') then
                if_time <= to_unsigned(0, 64);
            else
                if_time <= if_time + to_unsigned(1, 64);
                if (if_time_reg_in) then
                    if_time_rd <= std_logic_vector(if_time);
                end if;
                if (if_time_reg_out) then
                    if_time <= unsigned(if_time_wr);
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- RX chain/framer DMA blocks
    --------------------------------------------------------------------
    s2mm_framer0 : entity work.dma_s2mm
    generic map (
        MEM_SIZE => 128
    )
    port map (
        mem_clk => bus_clk,
        mem_rst => bus_rst,
        stream_clk => lms_clk,
        stream_rst => lms_rst,
        ctrl_data => dma_ctrl_data,
        ctrl_valid => s2mm_framer0_ctrl_valid,
        ctrl_ready => s2mm_framer0_ctrl_ready,
        stat_data => s2mm_framer0_stat_data,
        stat_valid => s2mm_framer0_stat_valid,
        stat_ready => s2mm_framer0_stat_ready,
        mem_sel => framer0_sel,
        mem_addr => framer0_addr,
        mem_data => framer0_data_rd,
        stream_data => framer0_rxd_data,
        stream_last => framer0_rxd_last,
        stream_valid => framer0_rxd_valid,
        stream_ready => framer0_rxd_ready
    );
    mm2s_framer0 : entity work.dma_mm2s
    generic map (
        MEM_SIZE => 128
    )
    port map (
        mem_clk => bus_clk,
        mem_rst => bus_rst,
        stream_clk => lms_clk,
        stream_rst => lms_rst,
        ctrl_data => dma_ctrl_data,
        ctrl_valid => mm2s_framer0_ctrl_valid,
        ctrl_ready => mm2s_framer0_ctrl_ready,
        mem_sel => framer0_sel,
        mem_wr => framer0_wr,
        mem_addr => framer0_addr,
        mem_data => framer0_data_wr,
        stream_data => framer0_ctrl_data,
        stream_last => framer0_ctrl_last,
        stream_valid => framer0_ctrl_valid,
        stream_ready => framer0_ctrl_ready
    );

    --loopback for now
    framer0_rxd_data <= framer0_ctrl_data;
    framer0_rxd_last <= framer0_ctrl_last;
    framer0_rxd_valid <= framer0_ctrl_valid;
    framer0_ctrl_ready <= framer0_rxd_ready;

    --------------------------------------------------------------------
    -- TX chain/deframer DMA blocks
    --------------------------------------------------------------------



    --------------------------------------------------------------------
    -- framers here ... loopback for now
    --------------------------------------------------------------------
    clk_in_BUFGP: component BUFGP
    port map (
        I => clk_in,
        O => lms_clk
    );

    lms_sync_rst: entity work.sync_reset
    port map (
        glbl_reset => bus_rst,
        clk => lms_clk,
        reset => lms_rst
    );

    TXIQSEL <= RXIQSEL;
    TXD <= RXD;
    APOPTOSIS <= '0';

    process (clk_in)
    begin
        FPGA_LED2 <= '0';
    end process;

    --------------------------------------------------------------------
    -- bypass cpu spi to lms
    --------------------------------------------------------------------
    spipass: entity work.spi_bypass
    port map (
        lms_sen => lms_sen,
        lms_sclk => lms_sclk,
        lms_miso => lms_miso,
        lms_mosi => lms_mosi,
        cpu_sen => cpu_sen,
        cpu_sclk => cpu_sclk,
        cpu_miso => cpu_miso,
        cpu_mosi => cpu_mosi
    );

    --------------------------------------------------------------------
    -- convert EIM into an internal addressable bus
    --------------------------------------------------------------------
    eim_bus: entity work.novena_eim
    port map (
        EIM_BCLK => EIM_BCLK,
        EIM_CS => EIM_CS,
        EIM_DA => EIM_DA,
        EIM_A => EIM_A,
        EIM_LBA => EIM_LBA,
        EIM_OE => EIM_OE,
        EIM_RW => EIM_RW,
        EIM_WAIT => EIM_WAIT,
        CLK2_N => CLK2_N,
        CLK2_P => CLK2_P,
        RESETBMCU => RESETBMCU,
        bus_clk => bus_clk,
        bus_data_wr => bus_data_wr,
        bus_data_rd => bus_data_rd,
        bus_addr => bus_addr,
        bus_sel => bus_sel,
        bus_wr => bus_wr
    );

    --------------------------------------------------------------------
    -- bus mux
    --------------------------------------------------------------------
    novena_rf_bus_mux : entity work.novena_rf_bus_mux
    port map (
        bus_sel => bus_sel,
        bus_wr => bus_wr,
        bus_addr => bus_addr,
        bus_data_wr => bus_data_wr,
        bus_data_rd => bus_data_rd,

        bus0_sel => reg_sel,
        bus0_wr => reg_wr,
        bus0_addr => reg_addr,
        bus0_data_wr => reg_data_wr,
        bus0_data_rd => reg_data_rd,

        bus1_sel => test0_sel,
        bus1_wr => test0_wr,
        bus1_addr => test0_addr,
        bus1_data_wr => test0_data_wr,
        bus1_data_rd => test0_data_rd,

        bus2_sel => framer0_sel,
        bus2_wr => framer0_wr,
        bus2_addr => framer0_addr,
        bus2_data_wr => framer0_data_wr,
        bus2_data_rd => framer0_data_rd,

        bus3_sel => deframer0_sel,
        bus3_wr => deframer0_wr,
        bus3_addr => deframer0_addr,
        bus3_data_wr => deframer0_data_wr,
        bus3_data_rd => deframer0_data_rd
    );

    --------------------------------------------------------------------
    -- a loopback test with BRAM
    --------------------------------------------------------------------
    test_ram: entity work.dual_port_ram
    generic map (
        MEM_SIZE => 16--,
        ----SYNC_READ => false
    )
    port map (
        Wr_clock => bus_clk,
        We => Wr,
        Wr_addr => Wr_addr,
        Wr_data => Wr_data,
        Rd_clock => bus_clk,
        Re => '1',
        Rd_addr => Rd_addr,
        Rd_data => Rd_data
    );

    Wr <= test0_wr and test0_sel;
    Rd_addr <= Wr_addr when (test0_sel = '0') else (Wr_addr + 1);
    Wr_addr <= to_integer(unsigned(test0_addr(4 downto 1)));
    test0_data_rd <= std_logic_vector(Rd_data);
    Wr_data <= std_ulogic_vector(test0_data_wr);

end architecture rtl;
