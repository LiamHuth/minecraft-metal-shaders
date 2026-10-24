// Headless integration test. Include the real producer/selection implementation
// so no test-only exports or hooks are needed in the shipped native library.
#include "../../metal/src/main/native/mcmetal.m"
#include <assert.h>

void mc_xdr_enable(int on);

static Ctx *testCtx;
static Enc *testEnc;

static void check(int ok, const char *why) {
	if (!ok) { fprintf(stderr, "FAIL: %s\n", why); exit(1); }
}

static void finish(id<MTLCommandBuffer> cb) {
	[cb waitUntilCompleted];
	check(cb.status == MTLCommandBufferStatusCompleted, cb.error.description.UTF8String ?: "GPU completion");
	[cb release];
}

static uint64_t frame(int colour, int size, long identity, id<MTLSharedEvent> gate, id<MTLCommandBuffer> *submitted) {
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
		width:size height:size mipmapped:NO];
	d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	id<MTLTexture> src = [testCtx->device newTextureWithDescriptor:d];
	id<MTLCommandBuffer> cb = cmd(testEnc);
	if (gate) [cb encodeWaitForEvent:gate value:1];
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = src;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	rp.colorAttachments[0].clearColor = MTLClearColorMake(colour == 0, colour == 1, colour == 2, 1);
	[[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
	check(mc_present_queued_acquire(testEnc, nil, src, identity), "staging slot available");
	uint64_t h = pqAcq;
	// Test the actual fill and selection without creating a window. The harness
	// owns the hand-off instead of scheduling the display worker on commit.
	pqAcq = 0;
	*submitted = mc_enc_commit(testEnc);
	[src release];
	return h;
}

static void publish(uint64_t h) {
	uint64_t old = atomic_exchange(&pqHandoff, h);
	if (old) atomic_store(&pqBusy[old & 3], 0);
}

static void pixel(uint64_t h, int expectedColour, long identity, int hdr) {
	check(pqCadence[h & 3] == identity, "selected frame retains its own measurement identity");
	id<MTLTexture> tex = pqStaging[h & 3];
	check(tex.pixelFormat == (hdr ? MTLPixelFormatRGB9E5Float : MTLPixelFormatRGBA8Unorm), "SDR/HDR staging format");
	id<MTLBuffer> b = [testCtx->device newBufferWithLength:256 options:MTLResourceStorageModeShared];
	id<MTLCommandBuffer> cb = [[pqQueue commandBuffer] retain];
	[cb encodeWaitForEvent:pqEvent value:h >> 2];
	id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
	[blit copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(1, 1, 1)
		toBuffer:b destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256];
	[blit endEncoding];
	[cb commit]; finish(cb);
	float rgb[3];
	if (hdr) {
		uint32_t v = *(uint32_t *)b.contents;
		for (int c = 0; c < 3; c++) rgb[c] = ((v >> (c * 9)) & 511) * exp2f((v >> 27) - 24.0f);
	} else {
		for (int c = 0; c < 3; c++) rgb[c] = ((uint8_t *)b.contents)[c] / 255.f;
	}
	for (int c = 0; c < 3; c++) check(c == expectedColour ? rgb[c] > .5f : rgb[c] < .25f, "selected staging pixels match selected frame");
	[b release];
}

int main(int argc, char **argv) { @autoreleasepool {
	check(argc == 2, "pass 0 for baseline or 1 for candidate");
	int enabled = atoi(argv[1]);
	alarm(30); // bounds a failed GPU wait; no display layer or fullscreen involved
	char name[256], error[1024];
	testCtx = mc_create(name, sizeof name, error, sizeof error);
	check(testCtx != NULL, error);
	testEnc = mc_enc_new(testCtx);
	mc_present_fresh(enabled);
	for (int hdr = 0; hdr < 2; hdr++) {
		mc_xdr_enable(hdr);
		for (int round = 0; round < 24; round++) {
			id<MTLCommandBuffer> a, b, c;
			uint64_t current = frame(0, 8 + round % 3, 100, nil, &a); finish(a);
			check(pqRefresh(current) == current, "empty hand-off retains current frame");
			id<MTLSharedEvent> gate = [testCtx->device newSharedEvent];
			uint64_t newer = frame(1, 11 + round % 3, 200, gate, &b);
			publish(newer);
			double start = CACurrentMediaTime();
			uint64_t selected = pqRefresh(current);
			double elapsed = CACurrentMediaTime() - start;
			gate.signaledValue = 1; finish(b); [gate release];
			check(selected == current && elapsed < .05, "unfinished replacement never blocks or replaces current");
			check(atomic_load(&pqHandoff) == newer, "unfinished hand-off preserved");
			// A third frame replaces the mailbox while the worker owns current.
			uint64_t newest = frame(2, 14 + round % 3, 300, nil, &c); finish(c);
			publish(newest);
			selected = pqRefresh(current);
			check(selected == (enabled ? newest : current), "ready frame selection respects opt-in");
			pixel(selected, enabled ? 2 : 0, enabled ? 300 : 100, hdr);
			if (enabled) {
				check(!atomic_load(&pqBusy[current & 3]), "discarded current slot released exactly once");
				check(mc_cadence_state(100) == 3, "discarded frame has an explicit diagnostic outcome");
			}
			atomic_store(&pqBusy[selected & 3], 0);
			uint64_t pending = atomic_exchange(&pqHandoff, 0);
			if (pending) atomic_store(&pqBusy[pending & 3], 0);
			for (int k = 0; k < 3; k++) check(!atomic_load(&pqBusy[k]), "all slots reusable after selection");
		}
	}
	check(mc_present_fresh_stat(2) == (enabled ? 48 : 0), "replacement diagnostics count actual changes");
	printf("PASS: %s; 48 SDR/HDR selection cycles, pending GPU fences, resized/reused slots, frame identity and pixel readback; %ld replacements\n",
		enabled ? "candidate" : "baseline", mc_present_fresh_stat(2));
} return 0; }
