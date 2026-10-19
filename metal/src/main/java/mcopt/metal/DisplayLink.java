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
	static final int LATENCY = Integer.getInteger("mcopt.metal.displayLink.latency", 1) == 2 ? 2 : 1;
	static final boolean LOG = Boolean.parseBoolean(System.getProperty("mcopt.metal.displayLink.log", "true"));
	static MetalSurface surface;
	private static boolean paced;
	private static int pacedCap;

	private DisplayLink() {}

	/** Live preference; a key press takes effect at the next frame boundary. */
	public static boolean enabled() { return Boolean.getBoolean(KEY); }

	/** Actual presentation state, distinct from the saved/requested preference. */
	public static Status status() { return surface == null ? Status.UNAVAILABLE : surface.displayLinkStatus(); }

	public static void beforeInput(int cap) {
		pacedCap = cap;
		// Also visit the surface when disabled, so it can release the previous link safely.
		paced = surface != null && surface.beginDisplayFrame(cap, enabled());
	}

	/** Keep vanilla's limiter if the cap decreased during this frame (e.g. minimize/AFK). */
	public static boolean paced(int cap) { return paced && cap >= pacedCap; }
}
