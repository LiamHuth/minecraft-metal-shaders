package mcopt.metal.mixin;

import java.io.IOException;
import java.io.InputStream;
import java.util.HashMap;
import java.util.Map;
import mcopt.metal.shade.ShadeLang;
import net.minecraft.client.resources.language.ClientLanguage;
import net.minecraft.locale.Language;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

/** Fabric Loader alone does not add mod assets to Minecraft's resource packs. */
@Mixin(ClientLanguage.class)
abstract class DisplayLanguageMixin {
	@Shadow @Final private Map<String, String> storage;
	@Unique private static final Map<String, String> mcopt$english = mcopt$load("en_us");
	@Unique private static final Map<String, String> mcopt$spanish = mcopt$load("es_es");

	@Unique private static Map<String, String> mcopt$load(String language) {
		Map<String, String> strings = new HashMap<>();
		try (InputStream in = ShadeLang.class.getResourceAsStream("/assets/mcopt/lang/" + language + ".json")) {
			if (in != null) Language.loadFromJson(in, strings::put);
		} catch (IOException e) {
			System.err.println("[mcopt] could not load display shortcut labels: " + e);
		}
		return Map.copyOf(strings);
	}

	@Inject(method = "getOrDefault", at = @At("HEAD"), cancellable = true)
	private void mcopt$displayLabel(String key, String fallback, CallbackInfoReturnable<String> ci) {
		// Resource-pack translations, when available, always take precedence.
		if (mcopt$english.containsKey(key) && !this.storage.containsKey(key)) {
			ci.setReturnValue(ShadeLang.spanish() ? mcopt$spanish.getOrDefault(key, mcopt$english.get(key)) : mcopt$english.get(key));
		}
	}

	@Inject(method = "has", at = @At("HEAD"), cancellable = true)
	private void mcopt$hasDisplayLabel(String key, CallbackInfoReturnable<Boolean> ci) {
		if (mcopt$english.containsKey(key)) ci.setReturnValue(true);
	}
}
