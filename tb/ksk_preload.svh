// Sim-only KSK preload for ks32's lane groups (rtl/ks_lanes.sv): the testbench reads the full-row
// image (L x 32 bits per row, dump_engine's ksk.hex) into ksk_img, sets ksk_img_ready, and each
// group's ksk_ram gets its lanes. The split matches ks32's glen/goff for G = 3 groups.
`define KSK_PRELOAD(KS, LANES) \
  localparam int KP_G = 3; \
  logic [(LANES)*32-1:0] ksk_img [8192 * ((918 + (LANES)) / (LANES))]; \
  bit ksk_img_ready = 0; \
  for (genvar g = 0; g < KP_G; g++) begin : g_kskld \
    localparam int LG  = (LANES) / KP_G + ((g < (LANES) % KP_G) ? 1 : 0); \
    localparam int OFF = g * ((LANES) / KP_G) + ((g < (LANES) % KP_G) ? g : (LANES) % KP_G); \
    initial begin \
      wait (ksk_img_ready); \
      for (int r = 0; r < $size(ksk_img); r++) KS.g_grp[g].u_l.u_ksk.mem[r] = ksk_img[r][OFF*32 +: LG*32]; \
    end \
  end
