package mcopt.pacingbench;

import java.lang.foreign.*;
import java.lang.invoke.MethodHandle;
import static java.lang.foreign.ValueLayout.*;

/** Test-only: inject repeatable GPU work into each presenting command, equally in A and B. */
public final class GpuLoad {
    private static MethodHandle load;
    private static long frameCommand;
    public static void append(long encoder) {
        if (!PacingBench.variableLoad) return;
        try {
            if (load == null) {
                var lib = SymbolLookup.libraryLookup(System.getProperty("mcopt.bench.loadLibrary"), Arena.global());
                load = Linker.nativeLinker().downcallHandle(lib.find("bench_load").orElseThrow(),
                    FunctionDescriptor.ofVoid(JAVA_LONG, JAVA_LONG, JAVA_INT));
                // Use the loaded mod's own encoder entry point; never load a second renderer.
                var field = Class.forName("mcopt.metal.Native").getDeclaredField("LIB");
                field.setAccessible(true);
                frameCommand = ((SymbolLookup)field.get(null)).find("mc_frame_cmd").orElseThrow().address();
            }
            // Fullscreen comparisons use the same wall-clock workload across different FPS.
            // Older suites retain their frame-based pattern for reproducibility.
            int n = PacingBench.loadFrame++;
            int step = PacingBench.fullscreenSuite
                ? (int)((System.nanoTime() - PacingBench.loadStartedNs) / (PacingBench.motionActive ? 237_000_000L : 250_000_000L)) : n / 24;
            int rounds = new int[]{8000, 12000, 18000, 24000}[step % 4];
            if ((PacingBench.fullscreenSuite ? step : n) % 11 == 0) rounds = 32000;
            load.invokeExact(encoder, frameCommand, rounds);
        } catch (Throwable t) { throw new RuntimeException("Pacing benchmark GPU load failed", t); }
    }
}
