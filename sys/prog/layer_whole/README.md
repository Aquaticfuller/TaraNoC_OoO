One transformer layer (128 tokens of 64 features, one attention head, 128 hidden features) as eleven tasks of 64
blocks, one per step: norm, QKV projection, pack, scores, softmax, P@V, output projection, norm, up projection,
SiLU, down projection. The input and the weights of four steps are loads. Each task waits for the whole task before
it. Then the output is checked against the reference. Made with `scripts/layer_prog.py layer_whole`.
