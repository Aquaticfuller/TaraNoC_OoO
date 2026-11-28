# Waves of the merge slices of group 0 (QuestaSim, `make -f domain.mk gui`).
# One clock cycle is 2 ns. Everything below group 0's merge logic and tile 0 is recorded, so further
# signals of these can be added after the run; the rest of the design is not recorded.
onerror {resume}
set G {/mempool_tb/dut/i_mempool_cluster/gen_groups_x[0]/gen_groups_y[0]/gen_rtl_group/i_group/i_mempool_group}
set W $G/gen_mcast_wide/i_mcast_group_wide
set N $G/gen_mcast_narrow[0]/gen_on/i_mcast_tile_narrow

log -r $W/*
log -r $N/*
log -r $G/gen_tiles[0]/i_tile/*

add wave -group clk /mempool_tb/clk /mempool_tb/rst_n
# Registers written by the kernel: per tile [3:0] word merging on per Spatz, [7:4] burst merging on,
# [11:8] sharers of a word, [15:12] sharers of a burst. Status per tile: [0] busy, [1] window expired.
add wave -group config -radix hex $G/mcast_cfg $G/mcast_stat

foreach v {0 1} {
  set S $W/gen_slice[$v]/i_slice
  add wave -group "wide slice $v" -group requests  $S/req_valid_i $S/req_ready_o $S/take $S/hit_any -radix hex $S/in_key
  add wave -group "wide slice $v" -group entries   $S/valid_q $S/closed_q $S/issued_q -radix unsigned $S/cnt_q $S/hold_q -radix hex $S/key_q
  add wave -group "wide slice $v" -group fetch     $S/fetch_valid_o $S/fetch_ready_i -radix hex $S/fetch_key_o $S/fetch_tag_o
  add wave -group "wide slice $v" -group response  $S/resp_valid_i $S/resp_ready_o -radix hex $S/resp_tag_i
  add wave -group "wide slice $v" -group cast      $S/dv_q $S/pend_q $S/dlv_valid_o $S/dlv_ready_i $S/timeout_o
}
add wave -group "wide ports" $W/en_i -radix unsigned $W/target_i $W/tile_req_valid_i $W/tile_req_ready_o $W/merge \
  $W/noc_req_valid_o $W/noc_req_ready_i $W/noc_resp_valid_i $W/resp_mine $W/tile_resp_valid_o $W/tile_resp_ready_i

set S $N/i_slice
add wave -group "narrow slice tile 0" -group requests  $N/tile_req_valid_i $N/tile_req_ready_o $N/merge $S/take $S/hit_any -radix hex $S/in_key
add wave -group "narrow slice tile 0" -group entries   $S/valid_q $S/closed_q $S/issued_q -radix unsigned $S/cnt_q $S/hold_q -radix hex $S/key_q
add wave -group "narrow slice tile 0" -group fetch     $S/fetch_valid_o $S/fetch_ready_i -radix hex $S/fetch_key_o $N/noc_req_valid_o $N/noc_req_ready_i
add wave -group "narrow slice tile 0" -group response  $N/noc_resp_valid_i $N/resp_mine $S/resp_valid_i $S/resp_ready_o
add wave -group "narrow slice tile 0" -group cast      $S/dv_q $S/pend_q $S/dlv_valid_o $S/dlv_ready_i $N/tile_resp_valid_o $N/tile_resp_ready_i $S/timeout_o
configure wave -signalnamewidth 1
