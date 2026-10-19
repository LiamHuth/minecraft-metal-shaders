package mcopt.metal.mixin;

import mcopt.metal.FrameWait;
import net.minecraft.client.FramerateLimiter;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * Vanilla's frame cap parks the render thread with parkNanos, then spins until the frame's deadline. On macOS that park is
 * a coalescable timer that wakes up to a quarter or more of the wait late (a 60 fps cap ran at 51 fps with Sodium), and the
 * spin burns a core for nothing. Same deadline, same bookkeeping (the next frame is timed from when this one's wait ends),
 * but one wait on a timer that fires on time and no spin. Applies to every cap: the fps option, menus, AFK and minimized.
 */
@Mixin(FramerateLimiter.class)
abstract class FramerateLimiterMixin {
	@Shadow
	private static long lastFrameTime;

	@Inject(method = "limitDisplayFPS", at = @At("HEAD"), cancellable = true)
	private static void mcopt$preciseWait(int framerateLimit, CallbackInfo ci) {
		if (mcopt.metal.DisplayLink.paced(framerateLimit)) {
			lastFrameTime = System.nanoTime();
			ci.cancel();
			return;
		}
		if (!FrameWait.ENABLED) return;
		long remaining = lastFrameTime + 1_000_000_000L / framerateLimit - System.nanoTime();
		if (remaining > 0) FrameWait.sleep(remaining);
		lastFrameTime = System.nanoTime();
		ci.cancel();
	}
}
