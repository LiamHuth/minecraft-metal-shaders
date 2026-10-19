package mcopt.metal.mixin;

import mcopt.metal.shade.DisplayKeybinds;
import net.minecraft.client.Minecraft;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(Minecraft.class)
abstract class DisplayKeysMixin {
	@Inject(method = "tick", at = @At("HEAD"))
	private void mcopt$displayKeys(CallbackInfo ci) {
		DisplayKeybinds.tick((Minecraft) (Object) this);
	}
}
