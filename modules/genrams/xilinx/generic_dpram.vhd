--------------------------------------------------------------------------------
-- CERN BE-CO-HT
-- General Cores Library
-- https://www.ohwr.org/projects/general-cores
--------------------------------------------------------------------------------
--
-- unit name:   generic_dpram
--
-- description: True dual-port synchronous RAM for Xilinx FPGAs with:
-- - configurable address and data bus width
-- - byte-addressing mode (data bus width restricted to multiple of 8 bits)
--
-- todo:
-- - loading initial contents from file
-- - add support for read-first/write-first address conflict resulution (only
--   supported by Xilinx in VHDL templates)
--
--------------------------------------------------------------------------------
-- Copyright CERN 2011-2018
--------------------------------------------------------------------------------
-- Copyright and related rights are licensed under the Solderpad Hardware
-- License, Version 2.0 (the "License"); you may not use this file except
-- in compliance with the License. You may obtain a copy of the License at
-- http://solderpad.org/licenses/SHL-2.0.
-- Unless required by applicable law or agreed to in writing, software,
-- hardware and materials distributed under this License is distributed on an
-- "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
-- or implied. See the License for the specific language governing permissions
-- and limitations under the License.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

library work;
use work.genram_pkg.all;
use work.memory_loader_pkg.all;

entity generic_dpram is

  generic (
    -- standard parameters
    g_data_width : natural := 32;
    g_size       : natural := 16384;

    g_with_byte_enable         : boolean := false;
    g_addr_conflict_resolution : string  := "read_first";
    g_init_file                : string  := "";
    g_dual_clock               : boolean := true;
    g_fail_if_file_not_found   : boolean := true;
    g_implementation_hint      : string  := "auto";
    g_fpga_family              : string  := "kintex7";
    g_use_bram_macros          : boolean := false
    );

  port (
    rst_n_i : in std_logic := '1';      -- synchronous reset, active LO

    -- Port A
    clka_i : in  std_logic;
    bwea_i : in  std_logic_vector((g_data_width+7)/8-1 downto 0);
    wea_i  : in  std_logic;
    aa_i   : in  std_logic_vector(f_log2_size(g_size)-1 downto 0);
    da_i   : in  std_logic_vector(g_data_width-1 downto 0);
    qa_o   : out std_logic_vector(g_data_width-1 downto 0);
    -- Port B

    clkb_i : in  std_logic;
    bweb_i : in  std_logic_vector((g_data_width+7)/8-1 downto 0);
    web_i  : in  std_logic;
    ab_i   : in  std_logic_vector(f_log2_size(g_size)-1 downto 0);
    db_i   : in  std_logic_vector(g_data_width-1 downto 0);
    qb_o   : out std_logic_vector(g_data_width-1 downto 0)
    );

end generic_dpram;



architecture syn of generic_dpram is

  constant c_gen_split    :boolean := (g_dual_clock = false and g_data_width=32
      and g_with_byte_enable=true and (g_addr_conflict_resolution="dont_care" or
      g_addr_conflict_resolution="read_first") and (not g_use_bram_macros));
  constant c_gen_sc       :boolean := (not c_gen_split) and (not g_dual_clock)
      and (not g_use_bram_macros);
  constant c_gen_dc       :boolean := g_dual_clock and (not g_use_bram_macros);
  constant c_gen_sc_macro :boolean := g_use_bram_macros and (not g_dual_clock);
  constant c_gen_dc_macro :boolean := g_use_bram_macros and g_dual_clock;

  component generic_dpram_split
    generic (
      g_size                     : natural;
      g_addr_conflict_resolution : string  := "dont_care";
      g_init_file                : string  := "none";
      g_fail_if_file_not_found   : boolean := true;
      g_implementation_hint      : string  := "auto"
      );
    port (
      rst_n_i : in  std_logic := '1';
      clk_i   : in  std_logic;
      bwea_i : in  std_logic_vector(3 downto 0);
      wea_i  : in  std_logic;
      aa_i   : in  std_logic_vector(f_log2_size(g_size)-1 downto 0);
      da_i   : in  std_logic_vector(31 downto 0);
      qa_o   : out std_logic_vector(31 downto 0);
      bweb_i : in  std_logic_vector(3 downto 0);
      web_i  : in  std_logic;
      ab_i   : in  std_logic_vector(f_log2_size(g_size)-1 downto 0);
      db_i   : in  std_logic_vector(31 downto 0);
      qb_o   : out std_logic_vector(31 downto 0));
  end component;

  component generic_dpram_sameclock
    generic (
      g_data_width               : natural;
      g_size                     : natural;
      g_with_byte_enable         : boolean;
      g_addr_conflict_resolution : string;
      g_init_file                : string;
      g_fail_if_file_not_found   : boolean;
      g_implementation_hint      : string
      );
    port (
      rst_n_i : in  std_logic := '1';
      clk_i   : in  std_logic;
      bwea_i  : in  std_logic_vector((g_data_width+7)/8-1 downto 0);
      wea_i   : in  std_logic;
      aa_i    : in  std_logic_vector(f_log2_size(g_size)-1 downto 0);
      da_i    : in  std_logic_vector(g_data_width-1 downto 0);
      qa_o    : out std_logic_vector(g_data_width-1 downto 0);
      bweb_i  : in  std_logic_vector((g_data_width+7)/8-1 downto 0);
      web_i   : in  std_logic;
      ab_i    : in  std_logic_vector(f_log2_size(g_size)-1 downto 0);
      db_i    : in  std_logic_vector(g_data_width-1 downto 0);
      qb_o    : out std_logic_vector(g_data_width-1 downto 0));
  end component;  

  component generic_dpram_dualclock
    generic (
      g_data_width               : natural;
      g_size                     : natural;
      g_with_byte_enable         : boolean;
      g_addr_conflict_resolution : string;
      g_init_file                : string;
      g_fail_if_file_not_found   : boolean;
      g_implementation_hint      : string
      );
    port (
      rst_n_i : in  std_logic := '1';
      clka_i  : in  std_logic;
      bwea_i  : in  std_logic_vector((g_data_width+7)/8-1 downto 0);
      wea_i   : in  std_logic;
      aa_i    : in  std_logic_vector(f_log2_size(g_size)-1 downto 0);
      da_i    : in  std_logic_vector(g_data_width-1 downto 0);
      qa_o    : out std_logic_vector(g_data_width-1 downto 0);
      clkb_i  : in  std_logic;
      bweb_i  : in  std_logic_vector((g_data_width+7)/8-1 downto 0);
      web_i   : in  std_logic;
      ab_i    : in  std_logic_vector(f_log2_size(g_size)-1 downto 0);
      db_i    : in  std_logic_vector(g_data_width-1 downto 0);
      qb_o    : out std_logic_vector(g_data_width-1 downto 0));
  end component;

  component generic_dpram_inst_7series
    generic (
      g_fpga_family              : string;
      g_data_width               : natural;
      g_size                     : natural;
      g_with_byte_enable         : boolean;
      g_addr_conflict_resolution : string;
      g_init_file                : string;
      g_fail_if_file_not_found   : boolean;
      g_implementation_hint      : string
      );
    port (
      rst_n_i : in  std_logic := '1';
      clka_i  : in  std_logic;
      bwea_i  : in  std_logic_vector((g_data_width+7)/8-1 downto 0);
      wea_i   : in  std_logic;
      aa_i    : in  std_logic_vector(f_log2_size(g_size)-1 downto 0);
      da_i    : in  std_logic_vector(g_data_width-1 downto 0);
      qa_o    : out std_logic_vector(g_data_width-1 downto 0);
      clkb_i  : in  std_logic;
      bweb_i  : in  std_logic_vector((g_data_width+7)/8-1 downto 0);
      web_i   : in  std_logic;
      ab_i    : in  std_logic_vector(f_log2_size(g_size)-1 downto 0);
      db_i    : in  std_logic_vector(g_data_width-1 downto 0);
      qb_o    : out std_logic_vector(g_data_width-1 downto 0));
  end component;

begin

  -- generic_dpram_split is like generic_dpram_sameclock, but hardcoded to
  -- 32-bit data width and split into 4 BRAMs, each of them 8-bit wide. It's
  -- better for Xilinx ISE, because it's unable to infer DPRAM with byte-write
  -- enables without using huge number of LUTs.
  -- Since it's hardcoded to 32-bits data width, we need to keep
  -- generic_dpram_sameclock as well. For reasons why generic_dpram_split is
  -- hardcoded to 32-bits please check the Note in generic_dpram_split.vhd.
  gen_splitram: if c_gen_split generate
    U_RAM_SPLIT: generic_dpram_split
      generic map(
        g_size                     => g_size,
        g_addr_conflict_resolution => g_addr_conflict_resolution,
        g_init_file                => g_init_file,
        g_fail_if_file_not_found   => g_fail_if_file_not_found,
        g_implementation_hint      => g_implementation_hint)
      port map(
        rst_n_i => rst_n_i,
        clk_i   => clka_i,
        bwea_i  => bwea_i,
        wea_i   => wea_i,
        aa_i    => aa_i,
        da_i    => da_i,
        qa_o    => qa_o,
        bweb_i  => bweb_i,
        web_i   => web_i,
        ab_i    => ab_i,
        db_i    => db_i,
        qb_o    => qb_o);
  end generate gen_splitram;

  gen_single_clk : if c_gen_sc generate
  U_RAM_SC: generic_dpram_sameclock
    generic map (
      g_data_width               => g_data_width,
      g_size                     => g_size,
      g_with_byte_enable         => g_with_byte_enable,
      g_addr_conflict_resolution => g_addr_conflict_resolution,
      g_init_file                => g_init_file,
      g_fail_if_file_not_found   => g_fail_if_file_not_found,
      g_implementation_hint      => g_implementation_hint)
    port map (
      rst_n_i => rst_n_i,
      clk_i   => clka_i,
      bwea_i  => bwea_i,
      wea_i   => wea_i,
      aa_i    => aa_i,
      da_i    => da_i,
      qa_o    => qa_o,
      bweb_i  => bweb_i,
      web_i   => web_i,
      ab_i    => ab_i,
      db_i    => db_i,
      qb_o    => qb_o); 

    
  end generate gen_single_clk;

  gen_dual_clk : if c_gen_dc generate
    U_RAM_DC: generic_dpram_dualclock
      generic map (
        g_data_width               => g_data_width,
        g_size                     => g_size,
        g_with_byte_enable         => g_with_byte_enable,
        g_addr_conflict_resolution => g_addr_conflict_resolution,
        g_init_file                => g_init_file,
        g_fail_if_file_not_found   => g_fail_if_file_not_found,
        g_implementation_hint      => g_implementation_hint)
      port map (
        rst_n_i => rst_n_i,
        clka_i  => clka_i,
        bwea_i  => bwea_i,
        wea_i   => wea_i,
        aa_i    => aa_i,
        da_i    => da_i,
        qa_o    => qa_o,
        clkb_i  => clkb_i,
        bweb_i  => bweb_i,
        web_i   => web_i,
        ab_i    => ab_i,
        db_i    => db_i,
        qb_o    => qb_o);
  end generate gen_dual_clk;

  gen_single_clk_macro : if c_gen_sc_macro generate
  U_RAM_SC_MACRO: generic_dpram_inst_7series
    generic map (
      g_data_width               => g_data_width,
      g_size                     => g_size,
      g_with_byte_enable         => g_with_byte_enable,
      g_addr_conflict_resolution => g_addr_conflict_resolution,
      g_init_file                => g_init_file,
      g_fail_if_file_not_found   => g_fail_if_file_not_found,
      g_implementation_hint      => g_implementation_hint,
      g_fpga_family              => g_fpga_family)
    port map (
      rst_n_i => rst_n_i,
      clka_i  => clka_i,
      bwea_i  => bwea_i,
      wea_i   => wea_i,
      aa_i    => aa_i,
      da_i    => da_i,
      qa_o    => qa_o,
      clkb_i  => clka_i,
      bweb_i  => bweb_i,
      web_i   => web_i,
      ab_i    => ab_i,
      db_i    => db_i,
      qb_o    => qb_o);
  end generate gen_single_clk_macro;

  gen_dual_clk_macro : if c_gen_dc_macro generate
    U_RAM_DC_MACRO: generic_dpram_inst_7series
      generic map (
        g_data_width               => g_data_width,
        g_size                     => g_size,
        g_with_byte_enable         => g_with_byte_enable,
        g_addr_conflict_resolution => g_addr_conflict_resolution,
        g_init_file                => g_init_file,
        g_fail_if_file_not_found   => g_fail_if_file_not_found,
        g_implementation_hint      => g_implementation_hint,
        g_fpga_family              => g_fpga_family)
      port map (
        rst_n_i => rst_n_i,
        clka_i  => clka_i,
        bwea_i  => bwea_i,
        wea_i   => wea_i,
        aa_i    => aa_i,
        da_i    => da_i,
        qa_o    => qa_o,
        clkb_i  => clkb_i,
        bweb_i  => bweb_i,
        web_i   => web_i,
        ab_i    => ab_i,
        db_i    => db_i,
        qb_o    => qb_o);
  end generate gen_dual_clk_macro;

end syn;
