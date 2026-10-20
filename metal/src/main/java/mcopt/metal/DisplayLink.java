package mcopt.metal;

/** Experimental display-driven pacing, before input polling. All access is on the render thread. */
public final class DisplayLink {
	public enum Status {
		OFF("off"), ACTIVE("active"), SWITCHING("switching"), VSYNC("vsync"), PAUSED("paused"),
		WAITING("waiting"), FALLBACK("fallback"), UNAVAILABLE("unavailable");
		public final String messageKey;
		Status(String suffix) { this.messageKey = "message.mcopt.promotion_" + suffix; }
	}
	public static final String KEY = "mcopt.metal.displayLink";
	// Reserved native ABI argument; CADisplayLink does not impose a presentation-latency budget.
	static final int LATENCY = 0;
	static final boolean LOG = Boolean.parseBoolean(System.getProperty("mcopt.metal.displayLink.log", "true"));
	static MetalSurface surface;
	// This diagnostic build enables the recorder by default; disable for timing comparisons.
	private static final boolean TRACE = Boolean.parseBoolean(System.getProperty("mcopt.metal.displayLink.trace", "true"));
	private static boolean traceInitialized, tracing;
	private static boolean paced;
	private static int pacedCap;
	private static Status loggedStatus;

	private DisplayLink() {}

	public static void initializeTrace(java.nio.file.Path gameDirectory) {
		if (traceInitialized) return;
		traceInitialized = true;
		if (!TRACE) return;
		try {
			var directory = gameDirectory.resolve("logs");
			java.nio.file.Files.createDirectories(directory);
			var path = directory.resolve("mcopt-presentation-" + System.currentTimeMillis() + "-" + ProcessHandle.current().pid() + ".log").toAbsolutePath();
			int result = Native.presentationTraceOpen(path.toString());
			if (result != 0) throw new java.io.IOException("native recorder error " + result);
			tracing = true;
			trace("session version=" + net.fabricmc.loader.api.FabricLoader.getInstance().getModContainer("mcopt-metal")
					.map(mod -> mod.getMetadata().getVersion().getFriendlyString()).orElse("unknown")
				+ " os=" + System.getProperty("os.version") + " java=" + System.getProperty("java.version")
				+ " enabled=" + enabled() + " pacer=CADisplayLink-render-budget");
			System.out.println("[mcopt] presentation diagnostics: " + path);
		} catch (java.io.IOException e) {
			System.err.println("[mcopt] could not open presentation diagnostics: " + e.getMessage());
		}
	}

	public static void trace(String message) { if (tracing) Native.presentationTraceNote(message); }
	static void stage(int stage, long object, long value) { if (tracing) Native.presentationTraceStage(stage, object, value); }

	/** Live preference; a key press takes effect at the next frame boundary. */
	public static boolean enabled() { return Boolean.getBoolean(KEY); }

	/** Actual presentation state, distinct from the saved/requested preference. */
	public static Status status() { return surface == null ? Status.UNAVAILABLE : surface.displayLinkStatus(); }

	public static void beforeInput(int cap) {
		stage(0, 0, cap);
		pacedCap = cap;
		// Also visit the surface when disabled, so it can release the previous link safely.
		paced = surface != null && surface.beginDisplayFrame(cap, enabled());
		stage(1, 0, paced ? 1 : 0);
		Status actual = status();
		if (actual != loggedStatus) {
			trace("presentation.status=" + actual + " requested=" + enabled() + " cap=" + cap);
			loggedStatus = actual;
		}
	}

	/** Keep vanilla's limiter if the cap decreased during this frame (e.g. minimize/AFK). */
	public static boolean paced(int cap) { return paced && cap >= pacedCap; }
}
