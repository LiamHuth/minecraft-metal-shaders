package mcopt.metal.mixin;

import mcopt.metal.DisplayLink;
import net.minecraft.client.Minecraft;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(Minecraft.class)
abstract class DisplayLinkMixin {
	@Inject(method = "run", at = @At(value = "INVOKE", target = "Lcom/mojang/blaze3d/systems/RenderSystem;pollEvents(Lcom/mojang/blaze3d/platform/SDLEventHandler;)V"))
	private void mcopt$displayFrame(CallbackInfo ci) {
		DisplayLink.beforeInput(Minecraft.getInstance().getFramerateLimitTracker().getFramerateLimit());
	}
}
