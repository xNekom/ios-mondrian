/*
 * Smoke test for the kernel cdevs the audio/haptics HAL writes to.
 *
 * Built as a small iOS executable and run through tools/wsl/run-test.sh. The
 * console is the kernel ring, so printf lines say exactly which open/write/
 * close succeeded. This isolates the kernel nodes from CoreAudio's routing.
 */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>

static void
try_device(const char *path, unsigned frames)
{
	int fd;
	uint8_t buf[4096];
	ssize_t wrote;

	printf("MONDRIAN NODE TEST: opening %s\n", path);
	fd = open(path, O_WRONLY);
	if (fd < 0) {
		printf("MONDRIAN NODE TEST: %s open FAILED\n", path);
		return;
	}
	printf("MONDRIAN NODE TEST: %s open fd %d\n", path, fd);
	memset(buf, 0x30, sizeof(buf));
	/* Two bytes a frame for the haptic node, four for the audio node. */
	for (unsigned i = 0; i < sizeof(buf); i += 2) {
		buf[i] = (uint8_t)(0x20 + (i & 7));
		buf[i + 1] = 0x7f;
	}
	wrote = write(fd, buf, (size_t)frames * 4 <= sizeof(buf) ?
	    (size_t)frames * 4 : sizeof(buf));
	printf("MONDRIAN NODE TEST: %s write %zd\n", path, wrote);
	fflush(stdout);
	/* Closing is what makes the haptic cdev play the burst. */
	printf("MONDRIAN NODE TEST: %s close %d\n", path, close(fd));
}

int
main(void)
{
	printf("MONDRIAN NODE TEST: start\n");
	try_device("/dev/mondrian-audio", 240);
	try_device("/dev/mondrian-haptic", 240);
	printf("MONDRIAN NODE TEST: done\n");
	fflush(stdout);
	return 0;
}
