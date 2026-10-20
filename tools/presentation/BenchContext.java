package mcopt.pacingbench;

import com.google.gson.Gson;
import com.google.gson.JsonObject;
import java.lang.foreign.*;
import org.lwjgl.sdl.SDLProperties;
import org.lwjgl.sdl.SDLVideo;
import static java.lang.foreign.ValueLayout.*;

/** Read-only native context; called on the render/main thread outside measurement. */
public final class BenchContext {
    public static JsonObject capture(long window, boolean vsync) {
        try (var arena = Arena.ofConfined()) {
            var library = SymbolLookup.libraryLookup(System.getProperty("mcopt.bench.loadLibrary"), Arena.global());
            var capture = Linker.nativeLinker().downcallHandle(library.find("bench_context").orElseThrow(),
                FunctionDescriptor.of(JAVA_INT, JAVA_LONG, ADDRESS, JAVA_INT));
            long cocoa = SDLProperties.SDL_GetPointerProperty(SDLVideo.SDL_GetWindowProperties(window),
                SDLVideo.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, 0L);
            var buffer = arena.allocate(4096);
            int result = (int)capture.invokeExact(cocoa, buffer, 4096);
            PacingBench.check(result == 1, "Native window context available");
            var context = new Gson().fromJson(buffer.getString(0), JsonObject.class);
            PacingBench.note("native context " + context);
            PacingBench.check(context.get("nativeFullscreen").getAsBoolean(), "Native fullscreen Space active");
            PacingBench.check(context.get("vsync").getAsBoolean() == vsync && context.get("hdr").getAsBoolean(), "Fixed native VSync and HDR");
            return context;
        } catch (Throwable t) { throw new RuntimeException("Cannot validate fullscreen benchmark context", t); }
    }
}
