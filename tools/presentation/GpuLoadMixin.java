package mcopt.pacingbench.mixin;

import mcopt.pacingbench.GpuLoad;
import org.spongepowered.asm.mixin.*;
import org.spongepowered.asm.mixin.injection.*;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(targets = "mcopt.metal.MetalEncoder", remap = false)
abstract class GpuLoadMixin {
    @Shadow @Final long enc;
    // Put the load BEFORE the finished image is copied/signaled to the worker.
    // Appending at submit would let presentation bypass the synthetic GPU work.
    @Inject(method = "presentAcquire", at = @At("HEAD"))
    private void bench$load(CallbackInfo ci) { GpuLoad.append(enc); }
}
