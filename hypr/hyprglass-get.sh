#!/usr/bin/env bash
# Print the live value of each slider-exposed hyprglass option as KEY=VALUE,
# for the Settings → Glass tab to initialise its sliders. Reads the running
# value via hyprctl (which already reflects hyprland.conf + hyprglass-tuning.conf).
set -u

INT_KEYS=" blur_iterations "
for k in refraction_strength fresnel_strength specular_strength lens_distortion \
         edge_thickness chromatic_aberration blur_strength blur_iterations \
         brightness contrast saturation vibrancy; do
    field=float
    case "$INT_KEYS" in *" $k "*) field=int ;; esac
    v=$(hyprctl getoption -j "plugin:hyprglass:$k" 2>/dev/null | jq -r ".$field // empty" 2>/dev/null)
    printf '%s=%s\n' "$k" "$v"
done
