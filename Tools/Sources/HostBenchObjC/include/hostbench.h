#pragma once
#ifdef __cplusplus
extern "C" {
#endif
// Encodes `dispatches` dispatches (2 buffers + 16 bytes of constants each, like the decoder) into one command
// buffer, `iters` times; returns median CPU seconds for encoding only (*rt: median commit-to-completion).
double hb_encode_objcpp(void *queue, void *pipeline, void *buffer, int dispatches, int iters, double *rt);
#ifdef __cplusplus
}
#endif
