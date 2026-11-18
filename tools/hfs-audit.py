#!/usr/bin/env python3
"""Audit the iOS root image the way the kernel will see it at mount.

`fsck.hfsplus` says a volume is fine when the allocation bitmap matches the
union of every fork's extents. It does not check the other records of the same
facts, and this port spends boots on disagreements it reports as "Runtime
corruption detected": the free count in the volume header, two forks claiming
one block, and a fork whose size needs more blocks than it owns (which
`hfs_getnewvnode` treats as corruption and fails the lookup with EINVAL).

Run it on the expanded partition -- the file `tools/flash-root.sh` writes before
`simg2img`, or its expansion -- so a boot is spent on the kernel rather than on
a question this answers in seconds:

    simg2img backup/ios-root-repaired.simg /root/root.raw
    python3 tools/hfs-audit.py /root/root.raw
    python3 tools/hfs-audit.py /root/root.raw --claim 160696+999

The image is opened read-only and never written.
"""
import struct
import sys

VOLUME_HEADER = 1024
MAXPATHLEN = 1024
S_IFMT = 0o170000
S_IFLNK = 0o120000
FILE_RECORD = 2
FORK_DATA = 0
FORK_RSRC = 0xFF


def usage():
	print(__doc__.strip())
	sys.exit(2)


def walk_leaves(volume, fork):
	"""Yield (node, node_size, record offsets) for every leaf of a B-tree."""
	head = volume.read(fork, 0, 512)
	node_size = struct.unpack(">H", head[32:34])[0]
	total_nodes = struct.unpack(">I", head[36:40])[0]
	if node_size < 512 or node_size > 65536 or total_nodes > 1000000:
		sys.exit("B-tree header looks wrong (node size %u, %u nodes)"
		         % (node_size, total_nodes))
	for index in range(total_nodes):
		buf = volume.read(fork, index * node_size, node_size)
		if len(buf) < node_size:
			return
		if struct.unpack(">b", buf[8:9])[0] != -1:
			continue
		count = struct.unpack(">H", buf[10:12])[0]
		if count == 0 or count > 4000:
			continue
		yield buf, node_size, struct.unpack(">%dH" % count,
		                                    buf[node_size - 2 * count:node_size])


class Volume:
	def __init__(self, path):
		self.img = open(path, "rb")
		self.img.seek(VOLUME_HEADER)
		h = self.img.read(512)
		sig, version, attrs = struct.unpack(">HHI", h[0:8])
		if sig not in (0x482B, 0x4858):
			sys.exit("%s: no HFS+ volume header at %d (signature 0x%04x)"
			         % (path, VOLUME_HEADER, sig))
		(self.block_size, self.total_blocks,
		 self.free_blocks) = struct.unpack(">III", h[40:52])
		(self.next_allocation, _, _) = struct.unpack(">III", h[52:64])
		(self.next_cnid, self.write_count) = struct.unpack(">II", h[64:72])
		self.hfsx = sig == 0x4858
		self.forks = {}
		for i, name in enumerate(["allocation", "extents", "catalog",
		                          "attributes", "startup"]):
			self.forks[name] = self.read_fork_header(h, 112 + i * 80)

	@staticmethod
	def read_fork_header(h, base):
		logical, clump, blocks = struct.unpack(">QII", h[base:base + 16])
		extents = []
		for e in range(8):
			start, count = struct.unpack(">II",
			                             h[base + 16 + 8 * e:base + 24 + 8 * e])
			if count:
				extents.append((start, count))
		return {"logical": logical, "clump": clump, "blocks": blocks,
		        "extents": extents}

	def read(self, fork, offset, size):
		"""Read from a fork's logical space through its extents."""
		out = bytearray()
		while size > 0 and offset < fork["logical"]:
			off = offset
			physical = None
			for start, count in fork["extents"]:
				if off < count * self.block_size:
					physical = start * self.block_size + off
					break
				off -= count * self.block_size
			if physical is None:
				break
			n = min(size, self.block_size - (physical % self.block_size),
			        fork["logical"] - offset)
			self.img.seek(physical)
			chunk = self.img.read(n)
			if not chunk:
				break
			out += chunk
			offset += len(chunk)
			size -= len(chunk)
		return bytes(out)

	def bitmap(self):
		return self.read(self.forks["allocation"], 0,
		                 self.forks["allocation"]["logical"])

	@staticmethod
	def owner_of_bitmap(bitmap, block):
		return ("allocated" if bitmap[block // 8] & (0x80 >> (block % 8))
		        else "free")

	def overflow(self):
		"""Extents in the extents overflow file, keyed by fork.

		Each entry carries the key's starting allocation block. A fork whose
		`totalBlocks` does not reach that block never looks at the record --
		`SearchExtentFile` stops there -- so an extent record left behind by a
		truncate that failed to delete it is invisible to the kernel. Reading
		those records anyway invents overlaps with whichever files own the
		blocks today, which is not a defect of the volume.
		"""
		out = {}
		fork = self.forks["extents"]
		if fork["blocks"] == 0:
			return out
		for node, node_size, offsets in walk_leaves(self, fork):
			for off in offsets:
				if off + 2 > node_size:
					continue
				key_length = struct.unpack(">H", node[off:off + 2])[0]
				if key_length != 10 or off + 12 + 64 > node_size:
					continue
				key = node[off + 2:off + 12]
				fork_type = key[0]
				file_id = struct.unpack(">I", key[2:6])[0]
				first = struct.unpack(">I", key[6:10])[0]
				extents = []
				for e in range(8):
					start, count = struct.unpack(">II", node[off + 12 + 8 * e:
					                                          off + 20 + 8 * e])
					if count:
						extents.append((start, count))
				out.setdefault((file_id, fork_type), []).append((first, extents))
		return out

	def files(self):
		"""Yield every file record of the catalog with its two forks."""
		fork = self.forks["catalog"]
		for node, node_size, offsets in walk_leaves(self, fork):
			for off in offsets:
				record = parse_file(node, node_size, off)
				if record is not None:
					yield record


def parse_file(node, node_size, off):
	if off + 2 > node_size:
		return None
	key_length = struct.unpack(">H", node[off:off + 2])[0]
	if key_length < 6 or off + 2 + key_length > node_size:
		return None
	key = node[off + 2:off + 2 + key_length]
	data = off + 2 + key_length
	if data % 2:
		data += 1
	if data + 248 > node_size:
		return None
	if struct.unpack(">H", node[data:data + 2])[0] != FILE_RECORD:
		return None
	rec = node[data:data + 248]
	name_length = struct.unpack(">H", key[4:6])[0]
	name = (key[6:6 + name_length * 2].decode("utf-16-be", "replace")
	        if name_length < 256 else "?")
	forks = {}
	for which, chunk in (("data", rec[88:168]), ("rsrc", rec[168:248])):
		logical, clump, blocks = struct.unpack(">QII", chunk[0:16])
		extents = []
		for e in range(8):
			start, count = struct.unpack(">II", chunk[16 + 8 * e:24 + 8 * e])
			if count:
				extents.append((start, count))
		forks[which] = {"logical": logical, "blocks": blocks,
		                "extents": extents}
	return {"cnid": struct.unpack(">I", rec[8:12])[0],
	        "mode": struct.unpack(">H", rec[42:44])[0],
	        "name": name, "fork": forks}


def main(argv):
	if len(argv) < 2:
		usage()
	path = argv[1]
	claims = []
	i = 2
	while i < len(argv):
		if argv[i] == "--claim" and i + 1 < len(argv):
			start, _, count = argv[i + 1].partition("+")
			claims.append((int(start), int(count or "1")))
			i += 2
		else:
			usage()

	volume = Volume(path)
	bitmap = volume.bitmap()
	print("%s: %s, %u-byte blocks, %u blocks (%.2f GiB)"
	      % (path, "HFSX" if volume.hfsx else "HFS+", volume.block_size,
	         volume.total_blocks,
	         volume.total_blocks * volume.block_size / 2**30))
	print("  volume header: %u free, next allocation %u, next cnid %u"
	      % (volume.free_blocks, volume.next_allocation, volume.next_cnid))
	print("  allocation file: %u blocks, covers %u bits of %u"
	      % (volume.forks["allocation"]["blocks"],
	         volume.forks["allocation"]["logical"] * 8, volume.total_blocks))
	counted = sum(8 - bin(byte).count("1") for byte in bitmap)
	print("  free by count %u%s"
	      % (counted, "" if counted == volume.free_blocks else
	         "  MISMATCH: %+d against the header" % (counted - volume.free_blocks)))

	overflow = volume.overflow()
	records = 0
	too_big = []
	long_links = []
	with_overflow = 0
	stale_records = 0
	spans = []
	for rec in volume.files():
		records += 1
		data = rec["fork"]["data"]
		need = (data["logical"] + volume.block_size - 1) // volume.block_size
		if need > data["blocks"]:
			too_big.append(rec)
			if rec["mode"] & S_IFMT == S_IFLNK and data["logical"] > MAXPATHLEN:
				long_links.append(rec)
		for which, fork_type in (("data", FORK_DATA), ("rsrc", FORK_RSRC)):
			fork = rec["fork"][which]
			extra = []
			for first, extents in overflow.get((rec["cnid"], fork_type), []):
				if first >= fork["blocks"]:
					# past the end of the fork: the kernel never reads it
					stale_records += 1
					continue
				extra.extend(extents)
			if extra:
				with_overflow += 1
			for start, count in fork["extents"] + extra:
				spans.append((start, count, rec["cnid"], which, rec["name"]))

	print("  catalog: %u file records, %u extents (%u forks continue in the "
	      "extents overflow file)" % (records, len(spans), with_overflow))
	if stale_records:
		print("  %u extent records sit past the end of their fork and are "
		      "never read" % stale_records)

	if too_big:
		print("  %u records need more blocks than their data fork owns:"
		      % len(too_big))
		for rec in too_big[:8]:
			d = rec["fork"]["data"]
			print("    id %-9u '%s' size %u, %u blocks"
			      % (rec["cnid"], rec["name"][:40], d["logical"], d["blocks"]))
	else:
		print("  every record's size fits the blocks it owns")
	if long_links:
		print("  %u symlinks longer than %d bytes"
		      % (len(long_links), MAXPATHLEN))

	spans.sort()
	overlaps = 0
	reach_start, reach_end, reach_id, reach_which, reach_name = spans[0]
	for start, count, cnid, which, name in spans[1:]:
		if start < reach_end:
			overlaps += 1
			if overlaps <= 12:
				print("    overlap: id %u %s '%s' at %u+%u into id %u %s "
				      "'%s' at %u+%u"
				      % (cnid, which, name[:28], start, count, reach_id,
				         reach_which, reach_name[:28], reach_start,
				         reach_end - reach_start))
		if start + count > reach_end:
			reach_start, reach_end = start, start + count
			reach_id, reach_which, reach_name = cnid, which, name
	print("  forks sharing blocks: %d" % overlaps)

	for start, count in claims:
		state = volume.owner_of_bitmap(bitmap, start)
		print("  %u+%u is %s in the bitmap; claimed by:"
		      % (start, count, state))
		found = 0
		for span_start, span_count, cnid, which, name in spans:
			if span_start + span_count > start and start + count > span_start:
				print("    id %-9u %-5s %u+%u  '%s'"
				      % (cnid, which, span_start, span_count, name[:40]))
				found += 1
		if not found:
			print("    nobody")


if __name__ == "__main__":
	main(sys.argv)
