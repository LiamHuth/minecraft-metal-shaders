package mcopt.pacingbench.mixin;

import mcopt.pacingbench.GpuLoad;
import org.spongepowered.asm.mixin.*;
import org.spongepowered.asm.mixin.injection.*;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(targets = "mcopt.metal.MetalEncoder", remap = false)
abstract class GpuLoadMixin {
    @Shadow @Final long enc;
    @Shadow private boolean presentedThisSubmit;
    @Unique private boolean bench$presenting;
    @Inject(method = "submit", at = @At("HEAD"))
    private void bench$capture(CallbackInfo ci) { bench$presenting = presentedThisSubmit; }
    @Inject(method = "submit", at = @At(value = "INVOKE", target = "Lmcopt/metal/Native;encCommit(J)J"))
    private void bench$load(CallbackInfo ci) { if (bench$presenting) GpuLoad.append(enc); }
}
