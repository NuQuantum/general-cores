action   = "simulation"
sim_tool = "ghdl"

target      = "xilinx"
syn_device  = "xc6slx45t"

sim_top = "gc_argb_led_drv_tb"

files = [
        "gc_argb_led_drv_tb.vhd",
    ]

modules = {
    "local" :  [
        "../../../",
    ],
}
