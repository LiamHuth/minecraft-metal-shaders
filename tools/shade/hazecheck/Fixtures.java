// Copyright 2026 mcopt-shade contributors. Apache-2.0.
import java.nio.file.*;
import mcopt.metal.shade.vl.VlConfig;

public class Fixtures {
    public static void main(String[] args) throws Exception {
        Files.writeString(Path.of(args[0]), VlConfig.source());
    }
}
