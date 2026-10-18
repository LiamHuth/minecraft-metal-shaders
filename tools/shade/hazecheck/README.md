# Haze shadow regression

After building `:metal:build`, run `sh tools/shade/hazecheck/run.sh [output-directory]` on a Mac with Metal.

This executes the production HDR volumetric ray march on the GPU, with controlled
shadow maps, and compares its correction to the production final-pass haze
integral at the same depth. The 108 cases cover fully blocked, visible and partially
blocked sunlight, four distances, three view elevations, and three mist densities.
Sky-lit fog remains present; only the sunlight component is compared.

Before the fix, the march's forest extinction weakened the negative sunlight
correction, leaving up to 55% of the sunlight at the default mist density in a
fully shadowed ray. Even without forest mist, the coarse height samples and grey
extinction disagreed with the analytic RGB integral. The test requires full shadow
to leave less than 0.2% of sunlight (allowing half-float storage error), open sun to
retain its original intensity, and partial shadow to stay between those bounds.

This is a controlled renderer test, not a reproduction of a particular Minecraft
world or a test of terrain outside the shadow maps' coverage.
