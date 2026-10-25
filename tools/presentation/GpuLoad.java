package mcopt.pacingbench;

import java.lang.foreign.*;
import java.lang.invoke.MethodHandle;
import static java.lang.foreign.ValueLayout.*;

/** Test-only: inject repeatable GPU work into each presenting command, equally in A and B. */
public final class GpuLoad {
    private static MethodHandle load;
    private static long frameCommand;
    private static final int[] ROUNDS = {8000, 12000, 18000, 24000};
    private static final double scale = Double.parseDouble(System.getProperty("mcopt.bench.loadScale", "1"));
    private static final long stepNs = Long.getLong("mcopt.bench.loadStepMs", 237L) * 1_000_000L;
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
            int step = (int)((System.nanoTime() - PacingBench.loadStartedNs) / stepNs);
            int rounds = ROUNDS[step % 4];
            if (step % 11 == 0) rounds = 32000;
            rounds = (int)Math.round(rounds * scale);
            load.invokeExact(encoder, frameCommand, rounds);
        } catch (Throwable t) { throw new RuntimeException("Pacing benchmark GPU load failed", t); }
    }
}
