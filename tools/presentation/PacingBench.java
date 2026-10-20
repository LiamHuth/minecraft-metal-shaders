package mcopt.pacingbench;

import com.google.gson.GsonBuilder;
import mcopt.metal.DisplayLink;
import mcopt.metal.GpuTimes;
import mcopt.metal.Latency;
import mcopt.metal.shade.dims.ShadeXdr;
import net.fabricmc.api.ClientModInitializer;
import net.minecraft.client.Minecraft;
import net.minecraft.client.InactivityFpsLimit;
import net.minecraft.network.chat.Component;
import net.minecraft.core.registries.Registries;
import net.minecraft.world.Difficulty;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.LevelSettings;
import net.minecraft.world.level.WorldDataConfiguration;
import net.minecraft.world.level.levelgen.WorldOptions;
import net.minecraft.world.level.levelgen.presets.WorldPresets;
import net.minecraft.world.level.levelgen.Heightmap;
import net.minecraft.world.level.gamerules.GameRules;
import org.lwjgl.sdl.SDLVideo;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/** Cadence comparison in a disposable flat world. No real profile or server. */
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
    static long loadStartedNs;
    static int changedSize, movedCamera;
    static final boolean presentationSuite = "presentation".equals(System.getProperty("mcopt.bench.suite"));
    static final boolean fullscreenSuite = "fullscreen".equals(System.getProperty("mcopt.bench.suite"));
    static final String fixedPolicy = System.getProperty("mcopt.bench.policy", "legacy");
    static final boolean expectedVsync = Boolean.parseBoolean(System.getProperty("mcopt.bench.vsync", "true"));
    static final String motion = System.getProperty("mcopt.bench.motion", "none");
    static boolean motionActive;
    static long motionStartedNs, nextLabelNs;

    static void check(boolean ok, String why) { if (!ok) throw new AssertionError(why); }
    static void game(Runnable work) throws Exception { mc.submit(work).get(guarded ? 5 : 30, TimeUnit.SECONDS); }
    static void note(String message) { System.out.println("PACING_BENCH " + message); }

    /** Called immediately after SDL input polling on the render thread, equally in both modes. */
    public static void polled() {
        Latency.lastPollNs = System.nanoTime();
        if (motionActive) {
            double seconds = (Latency.lastPollNs - motionStartedNs) / 1e9;
            double cycle = seconds % 4;
            float yaw = (float)(cycle < 2 ? -30 + 30 * cycle : 90 - 30 * cycle);
            mc.player.setYRot(yaw);
            mc.player.yRotO = yaw;
            mc.player.setXRot(0);
            mc.player.xRotO = 0;
            if (Latency.lastPollNs >= nextLabelNs) {
                String label = fixedPolicy.equals("legacy") ? "Existing renderer" : "Revised timer";
                mc.gui.hud.setOverlayMessage(Component.literal("Tearing check: " + label
                    + " | VSync " + (expectedVsync ? "ON" : "OFF") + " | watch vertical edges for splits"), false);
                nextLabelNs = Latency.lastPollNs + 1_000_000_000L;
            }
        }
        if (current == null) return;
        frames++;
        states.merge(DisplayLink.status().name(), 1, Integer::sum);
        actualCaps.merge(mc.getFramerateLimitTracker().getFramerateLimit(), 1, Integer::sum);
        long flags = SDLVideo.SDL_GetWindowFlags(mc.getWindow().handle());
        if ((flags & SDLVideo.SDL_WINDOW_INPUT_FOCUS) == 0) unfocused++;
        if ((flags & SDLVideo.SDL_WINDOW_FULLSCREEN) != 0) fullscreen++;
        if (mc.getWindow().getWidth() != (int)current.get("width") || mc.getWindow().getHeight() != (int)current.get("height")) changedSize++;
        if (fullscreenSuite && (Math.abs(mc.player.getX() - .5) > .1 || Math.abs(mc.player.getZ() - .5) > .1
                || (!motionActive && (Math.abs(mc.player.getXRot() - 15) > 1 || Math.abs(mc.player.getYRot()) > 1)))) movedCamera++;
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
            loadStartedNs = System.nanoTime();
            if (fullscreenSuite) {
                check(enabled == DisplayLink.enabled(), "Fullscreen policy must stay fixed for the entire process");
            } else {
                System.setProperty(DisplayLink.KEY, Boolean.toString(enabled));
                System.setProperty(DisplayLink.KEY + ".presentation", policy);
                System.setProperty(DisplayLink.KEY + ".queue", Integer.toString(queue));
            }
            note("prepare " + index + " cap=" + cap + " enabled=" + enabled + " policy=" + policy + " queue=" + queue);
        });
        Thread.sleep(presentationSuite || fullscreenSuite ? 3000 : 4000); // exclude rate negotiation
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
            current.put("vsync", mc.options.enableVsync().get());
            current.put("expectedVsync", expectedVsync);
            current.put("visualMotion", motionActive);
            if (motionActive) {
                current.put("motionStartedNs", motionStartedNs);
                current.put("motionProfile", "linear +/-30 degrees, four-second cycle, reversal at ends");
            }
            current.put("expectedFullscreen", fullscreenSuite);
            if (fullscreenSuite) current.put("windowContext", BenchContext.capture(mc.getWindow().handle(), expectedVsync));
            current.put("camera", new double[]{mc.player.getX(), mc.player.getY(), mc.player.getZ(), mc.player.getXRot(), mc.player.getYRot()});
            current.put("nanoRange", new long[] {System.nanoTime(), 0});
            loadStartedNs = System.nanoTime();
            current.put("epochStartMs", System.currentTimeMillis());
            states = new LinkedHashMap<>();
            actualCaps = new LinkedHashMap<>();
            unfocused = fullscreen = frames = changedSize = movedCamera = 0;
            phases.put(index + "-" + cap + "-" + (enabled ? "on" : "off"), current);
            note("measure " + index);
        });
        Thread.sleep(fullscreenSuite ? 10000 : presentationSuite ? 8000 : 12000);
        game(() -> {
            ((long[])current.get("nanoRange"))[1] = System.nanoTime();
            current.put("states", states);
            current.put("actualCaps", actualCaps);
            current.put("frames", frames);
            current.put("unfocusedFrames", unfocused);
            current.put("fullscreenFrames", fullscreen);
            current.put("changedSizeFrames", changedSize);
            current.put("movedCameraFrames", movedCamera);
            current = null;
            note("complete " + index + " states=" + states + " caps=" + actualCaps + " unfocused=" + unfocused);
            check(fullscreen == (fullscreenSuite ? frames : 0), "Requested window mode must stay fixed");
        });
    }

    static void motionCheck(int index) throws Exception {
        // Build the visual target after stationary measurements, so it cannot
        // change the existing flat-world timing workload. Only the disposable world is edited.
        game(() -> variableLoad = false);
        var server = mc.getSingleplayerServer();
        server.submit(() -> {
            var source = server.createCommandSourceStack();
            server.getCommands().performPrefixedCommand(source,
                "fill -24 -60 12 24 -40 12 minecraft:white_concrete");
            for (int x = -24; x <= 24; x += 4)
                server.getCommands().performPrefixedCommand(source,
                    "fill " + x + " -60 12 " + (x + 1) + " -40 12 minecraft:black_concrete");
        }).get(10, TimeUnit.SECONDS);
        Thread.sleep(3000); // let the new chunk meshes arrive before motion
        game(() -> { motionStartedNs = System.nanoTime(); nextLabelNs = 0; motionActive = true; });
        phase(index, 120, !fixedPolicy.equals("legacy"), true, fixedPolicy, 0);
        game(() -> motionActive = false);
    }

    public void onInitializeClient() {
        Thread.ofPlatform().daemon().start(() -> {
            try {
                Thread.sleep(18000);
                mc = Minecraft.getInstance();
                game(() -> {
                    mc.options.framerateLimit().set(120);
                    check(mc.options.enableVsync().get() == expectedVsync, "VSync fixed in startup options");
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
                if (fullscreenSuite) {
                    var server = mc.getSingleplayerServer();
                    var playerId = mc.submit(() -> mc.player.getUUID()).get(10, TimeUnit.SECONDS);
                    server.submit(() -> {
                        var level = server.overworld();
                        level.getGameRules().set(GameRules.ADVANCE_TIME, false, server);
                        level.getGameRules().set(GameRules.ADVANCE_WEATHER, false, server);
                        level.getGameRules().set(GameRules.SPAWN_MOBS, false, server);
                        server.getCommands().performPrefixedCommand(server.createCommandSourceStack(), "time set day");
                        server.getCommands().performPrefixedCommand(server.createCommandSourceStack(), "weather clear");
                        var player = server.getPlayerList().getPlayer(playerId);
                        check(player != null, "Benchmark player exists");
                        player.teleportTo(level, .5, level.getHeight(Heightmap.Types.MOTION_BLOCKING_NO_LEAVES, 0, 0), .5,
                            java.util.Set.of(), 0, 15, false);
                    }).get(10, TimeUnit.SECONDS);
                }
                game(() -> {
                    check(((SDLVideo.SDL_GetWindowFlags(mc.getWindow().handle()) & SDLVideo.SDL_WINDOW_FULLSCREEN) != 0) == fullscreenSuite, "Requested window mode at startup");
                    SDLVideo.SDL_RaiseWindow(mc.getWindow().handle());
                    mc.player.setXRot(15);
                    mc.player.setYRot(0);
                });
                Thread.sleep(5000);
                game(() -> check((SDLVideo.SDL_GetWindowFlags(mc.getWindow().handle()) & SDLVideo.SDL_WINDOW_INPUT_FOCUS) != 0, "Window must have focus"));
                guarded = true;
                if (fullscreenSuite) {
                    check(fixedPolicy.equals("legacy") || fixedPolicy.equals("ready") || fixedPolicy.equals("precise"), "Known fixed policy");
                    int[] caps = {50, 60, 120, 120};
                    if (!motion.equals("only"))
                        for (int i = 0; i < caps.length; i++) phase(i, caps[i], !fixedPolicy.equals("legacy"), i == 3, fixedPolicy, 0);
                    if (!motion.equals("none")) motionCheck(caps.length);
                } else if (presentationSuite) {
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
