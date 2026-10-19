import net.fabricmc.api.ClientModInitializer;
import net.minecraft.client.Minecraft;
import net.minecraft.client.KeyMapping;
import net.minecraft.core.registries.Registries;
import net.minecraft.world.level.LevelSettings;
import net.minecraft.world.level.GameType;
import net.minecraft.world.Difficulty;
import net.minecraft.world.level.WorldDataConfiguration;
import net.minecraft.world.level.levelgen.WorldOptions;
import net.minecraft.world.level.levelgen.presets.WorldPresets;
import com.mojang.blaze3d.platform.InputConstants;
import mcopt.metal.DisplayLink;
import mcopt.metal.shade.DisplayKeybinds;
import mcopt.metal.shade.dims.ShadeXdr;
import org.lwjgl.sdl.SDLVideo;
import java.util.concurrent.TimeUnit;

/** Isolated one-cycle fullscreen test. No repeated stress loop, user profile or server. */
public class FullscreenSmoke implements ClientModInitializer {
    static Minecraft mc;
    static boolean guarded;
    static final InputConstants.Key KEY = InputConstants.Type.KEYBOARD.getOrCreate(InputConstants.KEY_F7);
    static void check(boolean ok, String message) { if (!ok) throw new AssertionError(message); }
    static void game(Runnable work) throws Exception { mc.submit(work).get(guarded ? 3 : 30, TimeUnit.SECONDS); }
    static void note(String message) { DisplayLink.trace("fullscreen-test " + message); System.out.println("FULLSCREEN_TEST " + message); }
    static void steady(DisplayLink.Status expected, int seconds) throws Exception {
        for (int i = 0; i < seconds * 4; i++) {
            game(() -> check(DisplayLink.status() == expected, "Expected " + expected + ", got " + DisplayLink.status()));
            Thread.sleep(250);
        }
    }
    static void toggle(boolean enabled) throws Exception {
        game(() -> { note("toggle-request " + enabled); KeyMapping.click(KEY); });
        DisplayLink.Status expected = enabled ? DisplayLink.Status.ACTIVE : DisplayLink.Status.OFF;
        for (int i = 0; i < 20; i++) {
            Thread.sleep(100);
            if (mc.submit(() -> DisplayLink.status() == expected).get(3, TimeUnit.SECONDS)) {
                game(() -> note("toggle-complete " + expected)); return;
            }
        }
        throw new AssertionError("Transition did not settle: " + expected);
    }
    public void onInitializeClient() {
        Thread.ofPlatform().daemon().start(() -> {
            try {
                Thread.sleep(18000);
                mc = Minecraft.getInstance();
                game(() -> {
                    check(!DisplayLink.enabled(), "Starts with ProMotion off");
                    mc.options.framerateLimit().set(120); mc.options.enableVsync().set(true);
                    DisplayKeybinds.PROMOTION.setKey(KEY); KeyMapping.resetMapping();
                    mc.createWorldOpenFlows().createFreshLevel("fullscreen-smoke",
                        new LevelSettings("Presentation test", GameType.CREATIVE,
                            new LevelSettings.DifficultySettings(Difficulty.PEACEFUL,false,false), true, WorldDataConfiguration.DEFAULT),
                        new WorldOptions(1234L,false,false),
                        p -> p.lookupOrThrow(Registries.WORLD_PRESET).getOrThrow(WorldPresets.FLAT).value().createWorldDimensions(), mc.gui.screen());
                });
                boolean ready = false;
                for (int i=0; i<60; i++) {
                    Thread.sleep(500);
                    if (mc.submit(() -> mc.level != null && mc.player != null && mc.gui.screen() == null && mc.gui.overlay() == null).get(30, TimeUnit.SECONDS)) { ready=true; break; }
                }
                check(ready,"World loaded");
                Thread.sleep(2000);
                game(() -> {
                    note("enter-fullscreen");
                    mc.getWindow().setExclusiveFullscreen(true);
                    mc.getWindow().setFullscreen(true);
                });
                Thread.sleep(2000);
                game(() -> {
                    long flags = SDLVideo.SDL_GetWindowFlags(mc.getWindow().handle());
                    check((flags & SDLVideo.SDL_WINDOW_FULLSCREEN) != 0, "SDL fullscreen active");
                    check(mc.getWindow().isExclusiveFullscreen(), "Exclusive fullscreen requested");
                    check(ShadeXdr.active() && ShadeXdr.fullScene(), "Full-scene HDR active");
                    note("fullscreen-confirmed pixels=" + mc.getWindow().getWidth() + "x" + mc.getWindow().getHeight() + " flags=" + flags);
                });
                guarded = true;
                steady(DisplayLink.Status.OFF, 2);
                if (Boolean.getBoolean("mcopt.smoke.toggle")) {
                    toggle(true); steady(DisplayLink.Status.ACTIVE, 3);
                    toggle(false); steady(DisplayLink.Status.OFF, 3);
                }
                game(() -> { note("exit-fullscreen"); mc.getWindow().setFullscreen(false); });
                Thread.sleep(1500);
                game(() -> {
                    check((SDLVideo.SDL_GetWindowFlags(mc.getWindow().handle()) & SDLVideo.SDL_WINDOW_FULLSCREEN) == 0, "Returned to windowed mode");
                    note("PASS"); mc.stop();
                });
            } catch (Throwable e) {
                e.printStackTrace(); System.err.println("FULLSCREEN_TEST FAIL");
                // A timed-out render thread cannot execute a queued stop request. Exit only
                // this disposable test process. This cannot guarantee recovery of WindowServer.
                Runtime.getRuntime().halt(70);
            }
        });
    }
}
