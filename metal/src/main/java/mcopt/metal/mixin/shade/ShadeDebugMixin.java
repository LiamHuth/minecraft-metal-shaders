/*
 * Copyright 2026 mcopt-shade contributors
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
 * License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
 * law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
 * OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
 * limitations under the License.
 */
package mcopt.metal.mixin.shade;

import mcopt.metal.shade.ShadeResolution;
import net.minecraft.client.gui.components.debug.DebugEntryFps;
import net.minecraft.client.gui.components.debug.DebugScreenDisplayer;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.chunk.LevelChunk;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * M3.3: a priority line with the world's real render resolution (ShadeResolution.debugLine; F3 alternates priority lines
 * between its columns, so it shows at the top of the right one, next to the fps line): F3's "Display" is the
 * window's size, which the pause menu's resolution choice and the dynamic resolution never change. The fps entry is in both
 * of F3's default profiles. Only with mcopt.shade=true (ShadeMixinPlugin); mcopt.shade.f3=false: no line.
 */
@Mixin(DebugEntryFps.class)
abstract class ShadeDebugMixin {
	@Inject(method = "display", at = @At("TAIL"))
	private void mcopt$worldResolution(DebugScreenDisplayer displayer, Level level, LevelChunk clientChunk, LevelChunk serverChunk, CallbackInfo ci) {
		if (!"false".equals(System.getProperty("mcopt.shade.f3"))) displayer.addPriorityLine(ShadeResolution.debugLine());
		displayer.addPriorityLine(net.minecraft.network.chat.Component.translatable(mcopt.metal.DisplayLink.status().messageKey).getString());
	}
}
