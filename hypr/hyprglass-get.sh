#!/usr/bin/env bash
# Print the live value of each slider-exposed hyprglass option as KEY=VALUE,
# for the Settings → Glass tab to initialise its sliders. Reads the running
# value via hyprctl (which already reflects hyprland.conf + hyprglass-tuning.conf).
set -u

INT_KEYS=" blur_iterations shimmer:enabled "
for k in refraction_strength fresnel_strength specular_strength lens_distortion \
         edge_thickness chromatic_aberration blur_strength blur_iterations \
           brightness contrast saturation vibrancy \
           shimmer:enabled shimmer:intensity shimmer:depth shimmer:scale \
           shimmer:speed shimmer:agitation shimmer:viscosity shimmer:bed_variation shimmer:refraction; do
    field=float
    case "$INT_KEYS" in *" $k "*) field=int ;; esac
    v=$(hyprctl getoption -j "plugin:hyprglass:$k" 2>/dev/null | jq -r ".$field // empty" 2>/dev/null)
    printf '%s=%s\n' "$k" "$v"
done

# tint_color is a hex ARGB int; expose it to the UI as tint_alpha (0..1 = the
# alpha byte / 255) so the synthetic "Tint" slider reads back correctly.
tc=$(hyprctl getoption -j "plugin:hyprglass:tint_color" 2>/dev/null | jq -r '.int // 0' 2>/dev/null)
printf 'tint_alpha=%s\n' "$(python3 -c "print(round(((int('${tc:-0}') >> 24) & 0xFF)/255.0, 3))" 2>/dev/null || echo 0)"
