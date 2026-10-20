/*
 * LZ4 block decompression for the shim.
 *
 * The xnu payload is 15MB and the USB link of this phone drops in the
 * middle of a transfer that long, so the build compresses it and the
 * shim unpacks it here. Only the "block" format is supported (what
 * "lz4 -BD" writes): a sequence of sequences, each one a run of
 * literals followed by a back reference.
 */
#pragma once
#include <stdint.h>
#include <stddef.h>

/*
 * Decompress an LZ4 block into dst.
 * Returns the number of bytes written, or -1 if the input is malformed
 * or dst is too small.
 */
long lz4_decompress(const uint8_t *src, size_t src_len, uint8_t *dst, size_t dst_cap);

/*
 * Decompress an LZ4 frame (what the lz4 tool writes) into dst.
 * Returns the number of bytes written, or -1 on a malformed input.
 */
long lz4_decompress_frame(const uint8_t *src, size_t src_len, uint8_t *dst, size_t dst_cap);
