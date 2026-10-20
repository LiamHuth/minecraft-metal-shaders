package mcopt.pacingbench;

import com.google.gson.GsonBuilder;
import mcopt.metal.DisplayLink;
import mcopt.metal.GpuTimes;
import mcopt.metal.Latency;
import mcopt.metal.shade.dims.ShadeXdr;
import net.fabricmc.api.ClientModInitializer;
import net.minecraft.client.Minecraft;
import net.minecraft.client.InactivityFpsLimit;
import net.minecraft.core.registries.Registries;
import net.minecraft.world.Difficulty;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.LevelSettings;
import net.minecraft.world.level.WorldDataConfiguration;
import net.minecraft.world.level.levelgen.WorldOptions;
import net.minecraft.world.level.levelgen.presets.WorldPresets;
import org.lwjgl.sdl.SDLVideo;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/** Windowed-only cadence comparison in a disposable flat world. No real profile or server. */
public class PacingBench implements ClientModInitializer {
    static Minecraft mc;
    static final Map<String, Map<String, Object>> phases = new LinkedHashMap<>();
    static Map<String, Object> current;
    static Map<String, Integer> states;
    static Map<Integer, Integer> actualCaps;
    static int unfocused, fullscreen, frames;
    static boolean guarded;
    static boolean variableLoad;
    static int loadFrame;
    static final boolean presentationSuite = "presentation".equals(System.getProperty("mcopt.bench.suite"));

    static void check(boolean ok, String why) { if (!ok) throw new AssertionError(why); }
    static void game(Runnable work) throws Exception { mc.submit(work).get(guarded ? 5 : 30, TimeUnit.SECONDS); }
    static void note(String message) { System.out.println("PACING_BENCH " + message); }

    /** Called immediately after SDL input polling on the render thread, equally in both modes. */
    public static void polled() {
        Latency.lastPollNs = System.nanoTime();
        if (current == null) return;
        frames++;
        states.merge(DisplayLink.status().name(), 1, Integer::sum);
        actualCaps.merge(mc.getFramerateLimitTracker().getFramerateLimit(), 1, Integer::sum);
        long flags = SDLVideo.SDL_GetWindowFlags(mc.getWindow().handle());
        if ((flags & SDLVideo.SDL_WINDOW_INPUT_FOCUS) == 0) unfocused++;
        if ((flags & SDLVideo.SDL_WINDOW_FULLSCREEN) != 0) fullscreen++;
    }

    static void phase(int index, int cap, boolean enabled, boolean load) throws Exception {
        phase(index, cap, enabled, load, "clock", 0);
    }

    static void phase(int index, int cap, boolean enabled, boolean load, String policy, int queue) throws Exception {
        game(() -> {
            check(mc.gui.screen() == null && mc.gui.overlay() == null, "Gameplay must remain visible");
            mc.options.framerateLimit().set(cap);
            variableLoad = load;
            loadFrame = 0;
            System.setProperty(DisplayLink.KEY, Boolean.toString(enabled));
            System.setProperty(DisplayLink.KEY + ".presentation", policy);
            System.setProperty(DisplayLink.KEY + ".queue", Integer.toString(queue));
            note("prepare " + index + " cap=" + cap + " enabled=" + enabled + " policy=" + policy + " queue=" + queue);
        });
        Thread.sleep(presentationSuite ? 3000 : 4000); // exclude handoff and rate negotiation
        game(() -> {
            current = new LinkedHashMap<>();
            current.put("cap", cap);
            current.put("enabled", enabled);
            current.put("variableGpuLoad", load);
            current.put("presentationPolicy", policy);
            current.put("queueLimit", queue);
            current.put("width", mc.getWindow().getWidth());
            current.put("height", mc.getWindow().getHeight());
            current.put("hdr", ShadeXdr.active() && ShadeXdr.fullScene());
            current.put("nanoRange", new long[] {System.nanoTime(), 0});
            current.put("epochStartMs", System.currentTimeMillis());
            states = new LinkedHashMap<>();
            actualCaps = new LinkedHashMap<>();
            unfocused = fullscreen = frames = 0;
            phases.put(index + "-" + cap + "-" + (enabled ? "on" : "off"), current);
            note("measure " + index);
        });
        Thread.sleep(presentationSuite ? 8000 : 12000);
        game(() -> {
            ((long[])current.get("nanoRange"))[1] = System.nanoTime();
            current.put("states", states);
            current.put("actualCaps", actualCaps);
            current.put("frames", frames);
            current.put("unfocusedFrames", unfocused);
            current.put("fullscreenFrames", fullscreen);
            current = null;
            note("complete " + index + " states=" + states + " caps=" + actualCaps + " unfocused=" + unfocused);
            check(fullscreen == 0, "Windowed only");
        });
    }

    public void onInitializeClient() {
        Thread.ofPlatform().daemon().start(() -> {
            try {
                Thread.sleep(18000);
                mc = Minecraft.getInstance();
                game(() -> {
                    mc.options.framerateLimit().set(120);
                    mc.options.enableVsync().set(true);
                    mc.options.inactivityFpsLimit().set(InactivityFpsLimit.MINIMIZED);
                    mc.createWorldOpenFlows().createFreshLevel("pacing-benchmark",
                        new LevelSettings("Pacing benchmark", GameType.CREATIVE,
                            new LevelSettings.DifficultySettings(Difficulty.PEACEFUL, false, false),
                            true, WorldDataConfiguration.DEFAULT),
                        new WorldOptions(1234L, false, false),
                        p -> p.lookupOrThrow(Registries.WORLD_PRESET).getOrThrow(WorldPresets.FLAT).value().createWorldDimensions(),
                        mc.gui.screen());
                });
                boolean ready = false;
                for (int i = 0; i < 90; i++) {
                    Thread.sleep(500);
                    if (mc.submit(() -> mc.level != null && mc.player != null && mc.gui.screen() == null
                            && mc.gui.overlay() == null).get(30, TimeUnit.SECONDS)) { ready = true; break; }
                }
                check(ready, "World loaded");
                game(() -> {
                    check((SDLVideo.SDL_GetWindowFlags(mc.getWindow().handle()) & SDLVideo.SDL_WINDOW_FULLSCREEN) == 0, "Windowed only");
                    SDLVideo.SDL_RaiseWindow(mc.getWindow().handle());
                    mc.player.setXRot(15);
                    mc.player.setYRot(0);
                });
                Thread.sleep(5000);
                game(() -> check((SDLVideo.SDL_GetWindowFlags(mc.getWindow().handle()) & SDLVideo.SDL_WINDOW_INPUT_FOCUS) != 0, "Window must have focus"));
                guarded = true;
                if (presentationSuite) {
                    // Factor presentation and queue control independently; retain an
                    // unchanged legacy baseline. Reverse the loaded sweep to expose order effects.
                    String[] policy = {"legacy", "ready", "duration", "duration", "duration"};
                    int[] queue = {0, 0, 0, 2, 3};
                    int index = 0;
                    for (int cap : new int[]{50, 60, 120, 120}) {
                        boolean load = index >= 15;
                        for (int k = 0; k < policy.length; k++)
                            phase(index++, cap, k != 0, load, policy[k], queue[k]);
                    }
                    for (int k = policy.length - 1; k >= 0; k--)
                        phase(index++, 120, k != 0, true, policy[k], queue[k]);
                } else {
                    int[] caps = {50, 50, 50, 50, 60, 60, 120, 120, 120, 120, 120, 120};
                    boolean[] enabled = {false, true, true, false, true, false, false, true, false, true, true, false};
                    for (int i = 0; i < caps.length; i++) phase(i, caps[i], enabled[i], i >= 8);
                }
                Thread.sleep(1000); // allow last presented callbacks to arrive
                game(() -> {
                    Map<String, Object> report = new LinkedHashMap<>();
                    report.put("format", 1);
                    report.put("gpu", GpuTimes.snapshot(phases));
                    report.put("phases", phases);
                    report.put("latencyMeaning", "After SDL poll to Metal presentedTime, not physical input-to-photon latency");
                    try {
                        Files.writeString(Path.of(System.getProperty("mcopt.bench.output")),
                            new GsonBuilder().setPrettyPrinting().create().toJson(report));
                    } catch (Exception e) { throw new RuntimeException(e); }
                    note("PASS");
                    mc.stop();
                });
            } catch (Throwable t) {
                t.printStackTrace();
                note("FAIL");
                Runtime.getRuntime().halt(70);
            }
        });
    }
}
