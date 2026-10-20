#include "lz4.h"

#define LZ4_FRAME_MAGIC 0x184D2204UL

/* The frame that "lz4" writes: a header, then blocks of 64KB, each one an
 * independent LZ4 block, then a zero size and the stream checksum. */
long lz4_decompress_frame(const uint8_t *src, size_t src_len, uint8_t *dst, size_t dst_cap)
{
	const uint8_t *ip = src;
	const uint8_t *in_end = src + src_len;
	uint8_t *op = dst;
	uint8_t *out_end = dst + dst_cap;

	if (src_len < 7)
		return -1;
	if ((ip[0] | (ip[1] << 8) | (ip[2] << 16) | ((uint32_t)ip[3] << 24)) != LZ4_FRAME_MAGIC)
		return -1;
	uint8_t flg = ip[4];
	ip += 7;				/* magic, FLG, BD, HC */
	if (flg & 0x08)			/* content size */
		ip += 8;
	if (flg & 0x01)			/* dictionary id */
		ip += 4;

	while (ip + 4 <= in_end) {
		uint32_t bsize = (uint32_t)ip[0] | ((uint32_t)ip[1] << 8) |
				 ((uint32_t)ip[2] << 16) | ((uint32_t)ip[3] << 24);
		ip += 4;
		if (bsize == 0)
			break;			/* the end mark */
		if (ip + bsize > in_end)
			return -1;
		long n = lz4_decompress(ip, bsize, op, (size_t)(out_end - op));
		if (n < 0)
			return -1;
		op += n;
		ip += bsize;
	}
	return (long)(op - dst);
}

long lz4_decompress(const uint8_t *src, size_t src_len, uint8_t *dst, size_t dst_cap)
{
	const uint8_t *ip = src;
	const uint8_t *in_end = src + src_len;
	uint8_t *op = dst;
	uint8_t *out_end = dst + dst_cap;

	while (ip < in_end) {
		uint32_t token = *ip++;
		size_t lit = token >> 4;

		/* Literals: the length is in the token, 15 means "more". */
		if (lit == 15) {
			uint8_t s;
			do {
				if (ip >= in_end)
					return -1;
				s = *ip++;
				lit += s;
			} while (s == 255);
		}
		if ((size_t)(in_end - ip) < lit || (size_t)(out_end - op) < lit)
			return -1;
		for (size_t i = 0; i < lit; i++)
			op[i] = ip[i];
		op += lit;
		ip += lit;

		/* The last sequence of a block is literals only. */
		if (ip == in_end)
			break;

		/* The match: a 16 bit distance and a length of 4 bytes or more. */
		if (in_end - ip < 2)
			return -1;
		size_t offset = (size_t)ip[0] | ((size_t)ip[1] << 8);
		ip += 2;
		if (offset == 0 || offset > (size_t)(op - dst))
			return -1;
		size_t match = (token & 0xf) + 4;
		if ((token & 0xf) == 15) {
			uint8_t s;
			do {
				if (ip >= in_end)
					return -1;
				s = *ip++;
				match += s;
			} while (s == 255);
		}
		if ((size_t)(out_end - op) < match)
			return -1;
		/* The copy may overlap, so it has to go byte by byte. */
		const uint8_t *m = op - offset;
		for (size_t i = 0; i < match; i++)
			op[i] = m[i];
		op += match;
	}
	return (long)(op - dst);
}
