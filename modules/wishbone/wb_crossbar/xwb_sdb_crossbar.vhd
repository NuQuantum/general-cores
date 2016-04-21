library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.wishbone_pkg.all;

entity xwb_sdb_crossbar is
  generic(
    g_num_masters : natural := 1;
    g_num_slaves  : natural := 1;
    g_registered  : boolean := false;
    g_wraparound  : boolean := true;
    g_layout      : t_sdb_record_array;
    g_sdb_addr    : t_wishbone_address);
  port(
    clk_sys_i     : in  std_logic;
    rst_n_i       : in  std_logic;
    -- Master connections (INTERCON is a slave)
    slave_i       : in  t_wishbone_slave_in_array(g_num_masters-1 downto 0);
    slave_o       : out t_wishbone_slave_out_array(g_num_masters-1 downto 0);
    -- Slave connections (INTERCON is a master)
    master_i      : in  t_wishbone_master_in_array(g_num_slaves-1 downto 0);
    master_o      : out t_wishbone_master_out_array(g_num_slaves-1 downto 0));
end xwb_sdb_crossbar;

architecture rtl of xwb_sdb_crossbar is
  alias c_layout : t_sdb_record_array(g_layout'length-1 downto 0) is g_layout;
  
  -- Pretty print device name
  function f_trim(s : string) return string is
    variable cut : natural;
  begin
    byte : for i in s'length downto 1 loop
      cut := i;
      exit byte when s(i) /= ' ';
    end loop;
    return s(1 to cut);
  end f_trim;

  -- Step 1. Place the SDB ROM on the bus
  -- How much space does the ROM need?
  constant c_used_entries   : natural := c_layout'length + 1;
  constant c_rom_entries    : natural := 2**f_ceil_log2(c_used_entries); -- next power of 2
  constant c_sdb_bytes      : natural := c_sdb_device_length / 8;
  constant c_rom_bytes      : natural := c_rom_entries * c_sdb_bytes;
  
  type t_sizes is record
    bus_last : unsigned(63 downto 0);
    msi_last : unsigned(63 downto 0);
  end record t_sizes;

  -- Step 2. Find the size of the bus
  function f_sizes return t_sizes is
    variable result : t_sizes;
    variable typ    : std_logic_vector(7 downto 0);
    variable last   : unsigned(63 downto 0);
    constant zero : t_wishbone_address := (others => '0');
  begin
    -- The SDB block must be aligned
    assert (g_sdb_addr and std_logic_vector(to_unsigned(c_rom_bytes - 1, c_wishbone_address_width))) = zero
    report "SDB address is not aligned (" & f_bits2string(g_sdb_addr) & "). This is not supported by the crossbar."
    severity Failure;

    -- The ROM will be an addressed slave as well
    result.bus_last := (others => '0');
    result.bus_last(g_sdb_addr'range) := unsigned(g_sdb_addr);
    result.bus_last := result.bus_last + to_unsigned(c_rom_bytes, 64) - 1;
    
    -- There are no MSI targets by default
    result.msi_last := (others => '0');

    for i in c_layout'range loop
      typ := c_layout(i)(7 downto 0);
      last := unsigned(f_sdb_extract_component(c_layout(i)(447 downto 8)).addr_last);
      case typ is
        when x"01" => if last > result.bus_last then result.bus_last := last; end if;
        when x"02" => if last > result.bus_last then result.bus_last := last; end if;
        when x"03" => if last > result.msi_last then result.msi_last := last; end if;
        when others => null;
      end case;
    end loop;
    
    -- round result up to a power of two -1
    for i in 62 downto 0 loop
      result.bus_last(i) := result.bus_last(i) or result.bus_last(i+1);
      result.msi_last(i) := result.msi_last(i) or result.msi_last(i+1);
    end loop;

    -- Not a wraparound bus? Ignore all that hard work.
    if not g_wraparound then
      result.bus_last := (others => '0');
      for i in 0 to c_wishbone_address_width-1 loop
        result.bus_last(i) := '1';
      end loop;
    end if;
    
    return result;
  end f_sizes;

  constant c_sizes : t_sizes := f_sizes;

  type t_addresses is record
    bus_address : t_wishbone_address_array(g_num_slaves -1 downto 0);
    bus_mask    : t_wishbone_address_array(g_num_slaves -1 downto 0);
    msi_address : t_wishbone_address_array(g_num_masters-1 downto 0);
    msi_mask    : t_wishbone_address_array(g_num_masters-1 downto 0);
  end record t_addresses;

  -- Step 3. Map device address begin values
  function f_addresses return t_addresses is
    variable result : t_addresses;
    
    variable typ     : std_logic_vector(7 downto 0);
    variable sdb_component : t_sdb_component;
    
    variable address : t_wishbone_address;
    variable extend  : std_logic_vector(63 downto 0) := (others => '0');
    variable size    : unsigned(63 downto 0);
    
    variable bus_index : natural := 0;
    variable msi_index : natural := 0;
  begin
    for i in c_layout'low to c_layout'high loop
      typ := c_layout(i)(7 downto 0);
      sdb_component := f_sdb_extract_component(c_layout(i)(447 downto 8));

      -- Range must be valid
      assert unsigned(sdb_component.addr_first) <= unsigned(sdb_component.addr_last)
      report "Wishbone slave device #" & Integer'image(i) & " (" & f_trim(sdb_component.product.name) & ") sdb_component.addr_first (" & f_bits2string(sdb_component.addr_first) & ") must precede sdb_component.addr_last address (" & f_bits2string(sdb_component.addr_last) & ")."
      severity Failure;

      -- Address must fit within Wishbone address width
      address := sdb_component.addr_first(address'range);
      extend(address'range) := address;
      assert sdb_component.addr_first = extend
      report "Wishbone slave device #" & Integer'image(i) & " (" & f_trim(sdb_component.product.name) & ") sdb_component.addr_first (" & f_bits2string(sdb_component.addr_first) & " does not fit in t_wishbone_address."
      severity Failure;
      
      size := unsigned(sdb_component.addr_last) - unsigned(sdb_component.addr_first);
      -- size must be of the form 000000...00001111...1
      assert (size and (size + 1)) = 0
      report "Wishbone slave device #" & Integer'image(i) & " (" & f_trim(sdb_component.product.name) & ") has an address range that is not a power of 2 minus one (" & f_bits2string(std_logic_vector(size)) & "). This is not supported by the crossbar."
      severity Warning;
      
      -- fix the size up to the form 000...0001111...11
      for j in c_wishbone_address_width-2 downto 0 loop
        size(j) := size(j) or size(j+1);
      end loop;
      
      -- the base address must be aligned to the size
      assert (unsigned(sdb_component.addr_first) and size) = 0
      report "Wishbone slave device #" & Integer'image(i) & " (" & f_trim(sdb_component.product.name) & ") sdb_component.addr_first (" & f_bits2string(sdb_component.addr_first) & ") is not aligned. This is not supported by the crossbar."
      severity Failure;

      -- Record the address for posterity
      case typ is
        when x"01" | x"02" =>
          assert bus_index < g_num_slaves
          report "Too many device and bridge records found in g_layout"
          severity Failure;
          
          size := c_sizes.bus_last - size;
          result.bus_address(bus_index) := address;
          result.bus_mask   (bus_index) := std_logic_vector(size(address'range));
          bus_index := bus_index + 1;
          
        when x"03" =>
          assert msi_index < g_num_masters
          report "Too many msi records found in g_layout"
          severity Failure;
          
          size := c_sizes.msi_last - size;
          result.msi_address(msi_index) := address;
          result.msi_mask   (msi_index) := std_logic_vector(size(address'range));
          msi_index := msi_index + 1;
        
        when x"ff" =>
          result.bus_address(bus_index) := (others => '1');
          result.bus_mask   (bus_index) := (others => '0');
          bus_index := bus_index + 1;
        
        when others => null;
      end case;
    end loop;
    
    -- There must be exactly the right number of slave SDB records
    assert bus_index = g_num_slaves
    report "Too few device and bridge records found in g_layout"
    severity Failure;
    
    -- It is OK to have no master records (backwards compat)
    if msi_index = 0 then
      result.msi_address := (others => (others => '1'));
      result.msi_mask    := (others => (others => '0'));
    else
      assert msi_index = g_num_masters
      report "Too few msi records found in g_layout"
      severity Failure;
    end if;
    
    return result;
  end f_addresses;
  
  constant c_addresses : t_addresses := f_addresses;

  -- Figure out the mask for the SDB slave
  constant c_rom_mask : unsigned(63 downto 0) := 
    c_sizes.bus_last - to_unsigned(c_rom_bytes-1, 64);
  constant c_sdb_mask : t_wishbone_address := 
    std_logic_vector(c_rom_mask(c_wishbone_address_width-1 downto 0));
  
  -- Fill bus crossbar parameters
  constant c_address : t_wishbone_address_array(g_num_slaves downto 0) :=
    g_sdb_addr & c_addresses.bus_address;
  constant c_mask : t_wishbone_address_array(g_num_slaves downto 0) :=
    c_sdb_mask & c_addresses.bus_mask;
  
  -- !!! to remove
  constant c_null : t_sdb_record_array(0 downto 1) := (others => (others => '0'));
  
  signal master_i_1 :  t_wishbone_master_in_array(g_num_slaves downto 0);
  signal master_o_1 : t_wishbone_master_out_array(g_num_slaves downto 0);

begin

  -- Pass-through all slave ports except SDB
  master_i_1(g_num_slaves-1 downto 0) <=  master_i;
  master_o <= master_o_1(g_num_slaves-1 downto 0);
  
  rom : sdb_rom
    generic map(
      g_slaves   => c_layout,
      g_masters  => c_null,
      g_bus_end  => c_sizes.bus_last)
    port map(
      clk_sys_i => clk_sys_i,
      master_i  => (others => '0'),
      slave_i   => master_o_1(g_num_slaves),
      slave_o   => master_i_1(g_num_slaves));
  
  crossbar : xwb_crossbar
    generic map(
      g_num_masters => g_num_masters,
      g_num_slaves  => g_num_slaves + 1,
      g_registered  => g_registered,
      g_address     => c_address,
      g_mask        => c_mask)
    port map(
      clk_sys_i     => clk_sys_i,
      rst_n_i       => rst_n_i,
      slave_i       => slave_i, 
      slave_o       => slave_o, 
      master_i      => master_i_1, 
      master_o      => master_o_1);

end rtl;
