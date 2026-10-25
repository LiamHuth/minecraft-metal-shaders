package mcopt.metal;

/** Experimental input-relative presentation deadline. Startup-only, disabled by default. */
public final class FrameSchedule {
	private static final double MILLIS = Double.parseDouble(System.getProperty("mcopt.metal.presentScheduleMs", "0"));
	private static boolean active;

	private FrameSchedule() {}

	static void initialize(boolean acquire) {
		active = acquire && Double.isFinite(MILLIS) && MILLIS > 0 && MILLIS <= 50;
		Native.presentSchedule(active ? MILLIS / 1000 : 0);
		if (active) System.out.println("[mcopt] metal: experimental input-relative presentation deadline " + MILLIS + " ms");
	}

	public static void afterPoll() {
		if (active) Native.presentFrameStart();
	}
}
