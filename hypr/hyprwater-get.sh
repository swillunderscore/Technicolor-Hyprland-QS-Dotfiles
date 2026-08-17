#!/usr/bin/env bash
# Print the live value of each slider-exposed hyprwater option as KEY=VALUE,
# for the Settings → Glass tab to initialise its sliders. Reads the running
# value via hyprctl (which already reflects hyprland.conf + hyprwater-tuning.conf).
set -u

INT_KEYS=" blur_iterations shimmer:enabled shimmer:currents shimmer:currents_resolution adaptive_tint_terminals_only "
for k in refraction_strength fresnel_strength specular_strength lens_distortion \
         edge_thickness chromatic_aberration blur_strength blur_iterations \
           brightness contrast saturation vibrancy \
           adaptive_tint_terminals_only \
           shimmer:enabled shimmer:intensity shimmer:depth shimmer:scale \
           shimmer:speed shimmer:agitation shimmer:viscosity shimmer:murk shimmer:mouse shimmer:absorption shimmer:bed_variation shimmer:currents shimmer:currents_resolution shimmer:window_physics; do
    field=float
    case "$INT_KEYS" in *" $k "*) field=int ;; esac
    v=$(hyprctl getoption -j "plugin:hyprwater:$k" 2>/dev/null | jq -r ".$field // empty" 2>/dev/null)
    printf '%s=%s\n' "$k" "$v"
done

# tint_color is a hex ARGB int; expose it to the UI as tint_alpha (0..1 = the
# alpha byte / 255) so the synthetic "Tint" slider reads back correctly.
tc=$(hyprctl getoption -j "plugin:hyprwater:tint_color" 2>/dev/null | jq -r '.int // 0' 2>/dev/null)
printf 'tint_alpha=%s\n' "$(python3 -c "print(round(((int('${tc:-0}') >> 24) & 0xFF)/255.0, 3))" 2>/dev/null || echo 0)"
