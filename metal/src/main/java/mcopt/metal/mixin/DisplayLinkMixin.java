package mcopt.metal.mixin;

import mcopt.metal.DisplayLink;
import net.minecraft.client.Minecraft;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(Minecraft.class)
abstract class DisplayLinkMixin {
	@Unique private long mcopt$windowFlags = -1;
	@Unique private int mcopt$width = -1, mcopt$height = -1;
	@Inject(method = "run", at = @At(value = "INVOKE", target = "Lcom/mojang/blaze3d/systems/RenderSystem;pollEvents(Lcom/mojang/blaze3d/platform/SDLEventHandler;)V"))
	private void mcopt$displayFrame(CallbackInfo ci) {
		var mc = Minecraft.getInstance();
		DisplayLink.initializeTrace(mc.gameDirectory.toPath());
		var window = mc.getWindow();
		long flags = org.lwjgl.sdl.SDLVideo.SDL_GetWindowFlags(window.handle());
		if (flags != this.mcopt$windowFlags || window.getWidth() != this.mcopt$width || window.getHeight() != this.mcopt$height) {
			DisplayLink.trace("window flags=0x" + Long.toHexString(flags)
				+ " fullscreen=" + ((flags & org.lwjgl.sdl.SDLVideo.SDL_WINDOW_FULLSCREEN) != 0)
				+ " exclusive=" + window.isExclusiveFullscreen() + " pixels=" + window.getWidth() + "x" + window.getHeight());
			this.mcopt$windowFlags = flags;
			this.mcopt$width = window.getWidth(); this.mcopt$height = window.getHeight();
		}
		DisplayLink.beforeInput(Minecraft.getInstance().getFramerateLimitTracker().getFramerateLimit());
	}
}
