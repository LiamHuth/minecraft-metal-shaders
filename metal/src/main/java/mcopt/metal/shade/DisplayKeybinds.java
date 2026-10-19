package mcopt.metal.shade;

import com.mojang.blaze3d.platform.InputConstants;
import java.util.Arrays;
import mcopt.metal.DisplayLink;
import mcopt.metal.shade.dims.ShadeXdr;
import net.minecraft.client.KeyMapping;
import net.minecraft.client.Minecraft;
import net.minecraft.network.chat.Component;
import net.minecraft.resources.Identifier;

/** Optional in-world comparisons, using vanilla Controls without a Fabric API dependency. */
public final class DisplayKeybinds {
	private static final KeyMapping.Category CATEGORY = KeyMapping.Category.register(Identifier.fromNamespaceAndPath("mcopt", "display"));
	public static final KeyMapping HDR = unbound("key.mcopt.full_scene_hdr");
	public static final KeyMapping PROMOTION = unbound("key.mcopt.promotion");
	private static final String HDR_MODE = "mcopt.shade.hdrMode";

	private DisplayKeybinds() {}

	private static KeyMapping unbound(String name) {
		return new KeyMapping(name, InputConstants.UNKNOWN.getType(), InputConstants.UNKNOWN.getValue(), CATEGORY);
	}

	public static KeyMapping[] append(KeyMapping[] existing) {
		KeyMapping[] keys = Arrays.copyOf(existing, existing.length + 2);
		keys[existing.length] = HDR;
		keys[existing.length + 1] = PROMOTION;
		return keys;
	}

	public static void tick(Minecraft mc) {
		// Always drain clicks: typing in chat or assigning a shortcut must not queue a later toggle.
		boolean hdr = clicked(HDR), promotion = clicked(PROMOTION);
		if (mc.level == null || mc.gui.screen() != null || mc.gui.overlay() != null) return;
		if (hdr) toggleHdr(mc);
		if (promotion) togglePromotion(mc);
		if (hdr || promotion) ShadeSettings.save(mc.gameDirectory.toPath());
	}

	private static boolean clicked(KeyMapping key) {
		boolean clicked = false;
		while (key.consumeClick()) clicked = true;
		return clicked;
	}

	private static void toggleHdr(Minecraft mc) {
		boolean scene = !ShadeXdr.fullScene();
		set(HDR_MODE, scene ? "scene" : "highlights");
		String message = !Shade.ENABLED || !ShadeXdr.active() ? "message.mcopt.hdr_unavailable"
			: scene ? "message.mcopt.hdr_scene" : "message.mcopt.hdr_highlights";
		mc.gui.hud.setOverlayMessage(Component.translatable(message), false);
	}

	private static void togglePromotion(Minecraft mc) {
		boolean enabled = !DisplayLink.enabled();
		set(DisplayLink.KEY, Boolean.toString(enabled));
		// Only request the mode here. The current drawable/limiter stays valid until next frame.
		String message = !enabled ? "message.mcopt.promotion_off"
			: !mc.options.enableVsync().get() ? "message.mcopt.promotion_vsync" : "message.mcopt.promotion_on";
		mc.gui.hud.setOverlayMessage(Component.translatable(message), false);
	}

	private static void set(String key, String value) {
		System.setProperty(key, value);
		ShadeSettings.changed(key, value);
	}
}
