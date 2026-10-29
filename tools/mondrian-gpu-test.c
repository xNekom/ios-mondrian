/*
 * MondrianGPU smoke test: the whole msm DRM path from user space with no
 * Mesa in the way. It waits for the service, asks for the chip id, allocates
 * a buffer, writes a two packet command stream that has the GPU write a
 * canary next to itself, submits it, waits on the fence and reads the result
 * back through the same mapping.
 *
 * Built as a dylib (tools/build-mondrian-gpu-test.sh) and loaded in a
 * process that runs after the GPU is up, e.g. from mondrian-ui-hook.dylib
 * with dlopen("/usr/libexec/mondrian-gpu-test.dylib", RTLD_NOW).
 *
 * The structures are Linux's include/uapi/drm/msm_drm.h, the same ones the
 * kernel's user client takes; the selector of each request is the low byte
 * of the ioctl code.
 */
#include <IOKit/IOKitLib.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

struct msm_timespec {
	int64_t tv_sec, tv_nsec;
};
struct msm_param {
	uint32_t pipe, param;
	uint64_t value;
	uint32_t len, pad;
};
struct msm_gem_new {
	uint64_t size;
	uint32_t flags, handle;
};
struct msm_gem_info {
	uint32_t handle, info;
	uint64_t value;
	uint32_t len, pad;
};
struct msm_gem_submit_cmd {
	uint32_t type, submit_idx, submit_offset, size, pad, nr_relocs;
	uint64_t relocs;
};
struct msm_gem_submit_bo {
	uint32_t flags, handle;
	uint64_t presumed;
};
struct msm_gem_submit {
	uint32_t flags, fence, nr_bos, nr_cmds;
	uint64_t bos, cmds;
	int32_t fence_fd;
	uint32_t queueid;
	uint64_t in_syncobjs, out_syncobjs;
	uint32_t nr_in_syncobjs, nr_out_syncobjs, syncobj_stride, pad;
};
struct msm_wait_fence {
	uint32_t fence, flags;
	struct msm_timespec timeout;
	uint32_t queueid;
};

#define kMsmGetParam	0x40
#define kMsmGemNew	0x42
#define kMsmGemInfo	0x43
#define kMsmGemSubmit	0x46
#define kMsmWaitFence	0x47
#define kMsmGemClose	0x09
#define kMsmParamChipId	0x03
#define kMsmInfoGetIova	0x01
#define kMsmSubmitCmdBuf 1
#define kMsmPipe3D0	0x10

#define kCanary		0x600df00du
#define kFence		0x600df00eu
#define kCanaryOffset	0x8000u
#define kFenceOffset	0x8004u

static int console_fd = -1;

static void
say(const char *format, ...)
{
	char buffer[256];
	va_list arguments;
	int length;

	va_start(arguments, format);
	length = vsnprintf(buffer, sizeof(buffer), format, arguments);
	va_end(arguments);
	if (length <= 0) {
		return;
	}
	if (length > (int)sizeof(buffer)) {
		length = (int)sizeof(buffer);
	}
	(void)write(STDERR_FILENO, buffer, (size_t)length);
	if (console_fd >= 0) {
		(void)write(console_fd, buffer, (size_t)length);
	}
}

static int
call(io_connect_t connection, unsigned selector, void *data, size_t size)
{
	size_t returned = size;
	kern_return_t result = IOConnectCallStructMethod(connection, selector,
	    data, size, data, &returned);

	return result == KERN_SUCCESS ? 0 : -1;
}

__attribute__((constructor))
static void
mondrian_gpu_test(void)
{
	io_service_t service = 0;
	io_connect_t connection = 0;
	mach_vm_address_t address = 0;
	mach_vm_size_t mapped = 0;
	struct msm_param param;
	struct msm_gem_new gemNew;
	struct msm_gem_info gemInfo;
	struct msm_gem_submit_bo bos[1];
	struct msm_gem_submit_cmd cmds[1];
	struct msm_gem_submit submit;
	struct msm_wait_fence wait;
	volatile uint32_t *words;
	uint32_t *stream;
	uint32_t count = 0;
	int i;

	console_fd = open("/dev/console", O_WRONLY);
	for (i = 0; i < 150 && service == 0; i++) {
		service = IOServiceGetMatchingService(0,
		    IOServiceMatching("MondrianGPU"));
		if (service == 0) {
			usleep(200 * 1000);
		}
	}
	if (service == 0) {
		say("MONDRIAN GPU TEST: no MondrianGPU service after 30 s\n");
		goto out;
	}
	if (IOServiceOpen(service, mach_task_self(), 0, &connection) != 0) {
		say("MONDRIAN GPU TEST: IOServiceOpen failed\n");
		goto out;
	}
	say("MONDRIAN GPU TEST: connected\n");

	memset(&param, 0, sizeof(param));
	param.pipe = kMsmPipe3D0;
	param.param = kMsmParamChipId;
	if (call(connection, kMsmGetParam, &param, sizeof(param)) != 0) {
		say("MONDRIAN GPU TEST: GET_PARAM failed\n");
		goto out;
	}
	say("MONDRIAN GPU TEST: chip id 0x%llx\n",
	    (unsigned long long)param.value);
	if (param.value != 0x07030002ull) {
		say("MONDRIAN GPU TEST: unexpected chip id\n");
		goto out;
	}

	memset(&gemNew, 0, sizeof(gemNew));
	gemNew.size = 0x10000;
	if (call(connection, kMsmGemNew, &gemNew, sizeof(gemNew)) != 0) {
		say("MONDRIAN GPU TEST: GEM_NEW failed\n");
		goto out;
	}
	memset(&gemInfo, 0, sizeof(gemInfo));
	gemInfo.handle = gemNew.handle;
	gemInfo.info = kMsmInfoGetIova;
	if (call(connection, kMsmGemInfo, &gemInfo, sizeof(gemInfo)) != 0) {
		say("MONDRIAN GPU TEST: GEM_INFO failed\n");
		goto out;
	}
	if (IOConnectMapMemory64(connection, gemNew.handle, mach_task_self(),
	    &address, &mapped, kIOMapAnywhere) != 0 || mapped < 0x10000) {
		say("MONDRIAN GPU TEST: mapping the buffer failed\n");
		goto out;
	}
	words = (volatile uint32_t *)(uintptr_t)address;
	say("MONDRIAN GPU TEST: buffer handle %u at iova 0x%llx, %llu bytes\n",
	    gemNew.handle, (unsigned long long)gemInfo.value,
	    (unsigned long long)mapped);

	/* CP_MEM_WRITE the canary beside the stream, then fence it. */
	stream = (uint32_t *)(uintptr_t)address;
	stream[count++] = 0x703d8003u;			/* CP_MEM_WRITE, 3 */
	stream[count++] = (uint32_t)(gemInfo.value + kCanaryOffset);
	stream[count++] = (uint32_t)((gemInfo.value + kCanaryOffset) >> 32);
	stream[count++] = kCanary;
	stream[count++] = 0x70460004u;			/* CP_EVENT_WRITE, 4 */
	stream[count++] = 0x31u | (1u << 27);		/* cache clean */
	stream[count++] = (uint32_t)(gemInfo.value + kFenceOffset);
	stream[count++] = (uint32_t)((gemInfo.value + kFenceOffset) >> 32);
	stream[count++] = kFence;

	memset(bos, 0, sizeof(bos));
	bos[0].flags = 3;
	bos[0].handle = gemNew.handle;
	memset(cmds, 0, sizeof(cmds));
	cmds[0].type = kMsmSubmitCmdBuf;
	cmds[0].submit_idx = 0;
	cmds[0].submit_offset = 0;
	cmds[0].size = count * 4;
	memset(&submit, 0, sizeof(submit));
	submit.flags = 0x80000000u;			/* no implicit sync */
	submit.nr_bos = 1;
	submit.nr_cmds = 1;
	submit.bos = (uint64_t)(uintptr_t)bos;
	submit.cmds = (uint64_t)(uintptr_t)cmds;
	if (call(connection, kMsmGemSubmit, &submit, sizeof(submit)) != 0) {
		say("MONDRIAN GPU TEST: GEM_SUBMIT failed\n");
		goto out;
	}
	say("MONDRIAN GPU TEST: submitted, fence %u\n", submit.fence);

	memset(&wait, 0, sizeof(wait));
	wait.fence = submit.fence;
	wait.timeout.tv_sec = 5;
	if (call(connection, kMsmWaitFence, &wait, sizeof(wait)) != 0) {
		say("MONDRIAN GPU TEST: WAIT_FENCE timed out\n");
		goto out;
	}
	if (words[kCanaryOffset / 4] != kCanary ||
	    words[kFenceOffset / 4] != kFence) {
		say("MONDRIAN GPU TEST: fence done, canary 0x%x fence 0x%x\n",
		    words[kCanaryOffset / 4], words[kFenceOffset / 4]);
		say("MONDRIAN GPU TEST: FAILED\n");
		goto out;
	}
	say("MONDRIAN GPU TEST: canary 0x%x fence 0x%x\n",
	    words[kCanaryOffset / 4], words[kFenceOffset / 4]);
	say("MONDRIAN GPU TEST: PASSED\n");

out:
	if (address != 0) {
		IOConnectUnmapMemory64(connection, gemNew.handle,
		    mach_task_self(), address);
	}
	if (connection != 0) {
		IOServiceClose(connection);
	}
	if (service != 0) {
		IOObjectRelease(service);
	}
	if (console_fd >= 0) {
		close(console_fd);
	}
}
