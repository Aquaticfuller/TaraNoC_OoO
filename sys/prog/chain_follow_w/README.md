The chained program of `../chain_follow`, with weights of its own for stage 3: a second TLoad brings W into a slot,
which the scheduler places in another domain when there are several. Stage 3 then lives in that domain and follows
the softmax, which runs in the domain of stage 1, through progress messages. Made with
`scripts/chain_prog.py chain_follow_w --follow 1 --wload 1`.
