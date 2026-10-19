package mcopt.metal;

/** Experimental display-driven pacing, before input polling. All access is on the render thread. */
public final class DisplayLink {
	public static final boolean ENABLED = Boolean.getBoolean("mcopt.metal.displayLink");
	static final int LATENCY = Integer.getInteger("mcopt.metal.displayLink.latency", 1) == 2 ? 2 : 1;
	static final boolean LOG = Boolean.parseBoolean(System.getProperty("mcopt.metal.displayLink.log", "true"));
	static MetalSurface surface;
	private static boolean paced;
	private static int pacedCap;

	private DisplayLink() {}

	public static void beforeInput(int cap) {
		pacedCap = cap;
		paced = ENABLED && surface != null && surface.beginDisplayFrame(cap);
	}

	/** Keep vanilla's limiter if the cap decreased during this frame (e.g. minimize/AFK). */
	public static boolean paced(int cap) { return paced && cap >= pacedCap; }
}
