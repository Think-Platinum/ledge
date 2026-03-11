#include <metal_stdlib>
using namespace metal;

/// Water ripple distortion shader for the Ledge dashboard.
///
/// Simulates a water droplet hitting the display surface by displacing pixels
/// radially with expanding sinusoidal waves and a Gaussian envelope that
/// tracks the wavefront.
///
/// Parameters (after the automatic `position`):
///   center    — impact point of the water drop (in view coordinates)
///   progress  — animation progress: 0.0 = impact, 1.0 = fully dissipated
///   maxRadius — maximum extent of the ripple in points
///   amplitude — peak pixel displacement
///   ringCount — number of visible concentric wave rings
[[ stitchable ]] float2 waterRipple(
    float2 position,
    float2 center,
    float progress,
    float maxRadius,
    float amplitude,
    float ringCount
) {
    float2 delta = position - center;
    float dist = length(delta);

    // Expanding wavefront radius
    float frontRadius = progress * maxRadius;

    // Skip pixels far ahead of the wavefront (no distortion yet)
    float lookahead = maxRadius * 0.25;
    if (dist > frontRadius + lookahead) return position;
    // Avoid division by zero at the exact center
    if (dist < 0.5) return position;

    // --- Wave pattern ---
    // Sinusoidal rings radiating outward from the center.
    // The phase shifts with progress so rings appear to travel outward.
    float wavelength = maxRadius / max(ringCount, 1.0);
    float phase = (dist / wavelength - progress * ringCount) * 2.0 * M_PI_F;
    float wave = sin(phase);

    // --- Spatial envelope (Gaussian centred on the wavefront) ---
    // The active distortion band follows the expanding front.
    // Bandwidth widens slightly as the ripple expands for a natural look.
    float bandwidth = maxRadius * 0.18;
    float distFromFront = dist - frontRadius;
    float envelope = exp(-(distFromFront * distFromFront) / (2.0 * bandwidth * bandwidth));

    // --- Temporal decay ---
    // Ripple energy dissipates over time (amplitude fades to zero).
    float timeFade = pow(1.0 - progress, 1.5);

    // --- Combined displacement ---
    float disp = wave * amplitude * envelope * timeFade;

    // Displace radially (outward when positive, inward when negative)
    float2 dir = normalize(delta);
    return position + dir * disp;
}
