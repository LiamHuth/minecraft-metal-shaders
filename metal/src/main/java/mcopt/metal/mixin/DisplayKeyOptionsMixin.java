package mcopt.metal.mixin;

import mcopt.metal.shade.DisplayKeybinds;
import net.minecraft.client.KeyMapping;
import net.minecraft.client.Options;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Mutable;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(Options.class)
abstract class DisplayKeyOptionsMixin {
	@Shadow @Final @Mutable public KeyMapping[] keyMappings;

	// Register before options.txt is read, so vanilla loads/saves assignments and handles conflicts/reset.
	@Inject(method = "<init>", at = @At(value = "INVOKE", target = "Lnet/minecraft/client/Options;load()V"))
	private void mcopt$displayKeys(CallbackInfo ci) {
		this.keyMappings = DisplayKeybinds.append(this.keyMappings);
	}
}
