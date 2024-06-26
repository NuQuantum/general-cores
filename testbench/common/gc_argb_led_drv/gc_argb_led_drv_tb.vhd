--------------------------------------------------------------------------------
-- CERN BE-CO-HT
-- Project    : General Cores Collection library
--------------------------------------------------------------------------------
--
-- unit name:   gc_argb_led_drv
--
-- description: Driver for argb (or intelligent) led like ws2812b
--
--------------------------------------------------------------------------------
-- Copyright CERN 2024
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

entity gc_argb_led_drv_tb is
end;

architecture arch of gc_argb_led_drv_tb is
  constant C_CLK_FREQ : natural := 62_500_000;
  signal clk   : std_logic := '0';
  signal rst_n : std_logic := '0';
  signal b_g   : std_logic_vector(7 downto 0);
  signal b_r   : std_logic_vector(7 downto 0);
  signal b_b   : std_logic_vector(7 downto 0);
  signal valid : std_logic;
  signal dout  : std_logic;
  signal ready : std_logic;
  signal res   : std_logic;
begin
  DUT: entity work.gc_argb_led_drv
    generic map (
      g_clk_freq => C_clk_freq
    )
    port map (
      clk_i => clk,
      rst_n_i => rst_n,
      g_i => b_g,
      r_i => b_r,
      b_i => b_b,
      valid_i => valid,
      dout_o => dout,
      ready_o => ready,
      res_o => res
    );

  process
  begin
    clk <= not clk;
    wait for (1_000_000_000 / C_CLK_FREQ / 2) * 1 ns;
  end process;

  process
  begin
    wait until rising_edge(clk);
    rst_n <= '1';
    wait;
  end process;

  process
  begin
    valid <= '0';
    loop
      wait until rising_edge(clk);
      exit when ready = '1';
    end loop;
    b_g <= x"80";
    b_r <= x"7f";
    b_b <= x"c8";
    valid <= '1';
    wait until rising_edge(clk);
    valid <= '0';
    wait;
  end process;
end arch;