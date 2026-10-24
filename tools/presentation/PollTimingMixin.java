package mcopt.pacingbench.mixin;

import mcopt.pacingbench.PacingBench;
import net.minecraft.client.Minecraft;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(Minecraft.class)
abstract class PollTimingMixin {
    @Inject(method = "run", at = @At(value = "INVOKE",
        target = "Lcom/mojang/blaze3d/systems/RenderSystem;pollEvents(Lcom/mojang/blaze3d/platform/SDLEventHandler;)V",
        shift = At.Shift.AFTER))
    private void bench$polled(CallbackInfo ci) { PacingBench.polled(); }
}
