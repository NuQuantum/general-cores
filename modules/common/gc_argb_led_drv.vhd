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

entity gc_argb_led_drv is
  generic (
    g_clk_freq : natural
  );
  port (
    clk_i   : in std_logic;
    rst_n_i : in std_logic;

    --  Input: color + valid bit.
    --  The input is read when both ready_o and valid_i are set.
    --  It is then transmitted, and during the transmission, ready_o
    --  is false.
    g_i     : in std_logic_vector(7 downto 0);
    r_i     : in std_logic_vector(7 downto 0);
    b_i     : in std_logic_vector(7 downto 0);
    valid_i : in std_logic;

    --  Output to the first led.
    dout_o  : out std_logic;

    --  Set when ready to use the input.
    ready_o : out std_logic;

    --  If no new inputs are valid for 50us while ready_o is set,
    --  res_o raises to indicate the led are reset.  The next input
    --  will be used by the first led.
    res_o   : out std_logic
  );
end gc_argb_led_drv;

architecture arch of gc_argb_led_drv is
  constant C_T0H : natural := g_clk_freq * 8  / 20_000_000 - 1; -- 0.4us
  constant C_T0L : natural := g_clk_freq * 17 / 20_000_000 - 1; -- 0.85us

  constant C_T1H : natural := g_clk_freq * 16 / 20_000_000 - 1; -- 0.8us
  constant C_T1L : natural := g_clk_freq * 9  / 20_000_000 - 1; -- 0.45us

  signal frame : std_logic_vector(23 downto 0);
  signal counter : natural range 0 to C_T0L;
  subtype t_reset is natural range 0 to g_clk_freq * 5 / 100_000 - 1;
  signal res_counter : t_reset;
  signal shift_cnt : natural range 0 to 23;
  signal hi_lo : std_logic;
  signal tx : std_logic;
  signal msb : std_logic;
begin
  ready_o <= not tx;

  msb <= frame(23);
  dout_o <= hi_lo;

  process (clk_i)
  begin
    if rising_edge(clk_i) then
      if rst_n_i = '0' then
        res_o <= '0';
        res_counter <= 0;
      else
        if tx = '1' then
          res_counter <= 0;
          res_o <= '0';
        elsif res_counter = t_reset'high then
          res_o <= '1';
        else
          res_counter <= res_counter + 1;
        end if;
      end if;
    end if;
  end process;

  process (clk_i)
  begin
    if rising_edge(clk_i) then
      if rst_n_i = '0' then
        tx <= '0';
        frame <= (others => '0');
        hi_lo <= '0';
      else
        if tx = '0' then
          if valid_i = '1' then
            --  Note: the order depends on the manufacturer.
            frame <= r_i & g_i & b_i;
            tx <= '1';
            shift_cnt <= 0;
            counter <= 0;
            hi_lo <= '1';
          end if;
        else
          if hi_lo = '1'
           and ((msb = '1' and counter = C_T1H) or (msb = '0' and counter = C_T0H))
          then
            hi_lo <= '0';
            counter <= 0;
          elsif hi_lo = '0'
            and ((msb = '1' and counter = C_T1L) or (msb = '0' and counter = C_T0L))
          then
            if shift_cnt = 23 then
              tx <= '0';
            else
              shift_cnt <= shift_cnt + 1;
              frame <= frame(22 downto 0) & '0';
              counter <= 0;
              hi_lo <= '1';
            end if;
          else
            counter <= counter + 1;
          end if;
        end if;
      end if;
    end if;
  end process;
end arch;