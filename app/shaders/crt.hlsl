// OptiMiyoo full-screen CRT.
// Original, mild post-processing: retain the bold source glyphs and colors.
// Windows Terminal supplies these bindings and constants.
Texture2D shaderTexture;
SamplerState samplerState;

cbuffer PixelShaderSettings
{
    float Time;
    float Scale;
    float2 Resolution;
    float4 Background;
};

static const float TAU = 6.28318530718f;
static const float LOOP_SECONDS = 8.1f;

float3 ContentAt(float2 uv)
{
    float4 pixel = shaderTexture.Sample(samplerState, saturate(uv));
    // The app profile uses an opaque terminal, including otherwise empty cells.
    return lerp(Background.rgb, pixel.rgb, pixel.a);
}

float4 main(float4 pos : SV_POSITION, float2 tex : TEXCOORD) : SV_TARGET
{
    float uiScale = max(Scale, 1.0f);
    float2 delta = 1.25f * uiScale / max(Resolution, float2(1.0f, 1.0f));
    float3 source = ContentAt(tex);

    // A small, normalized glow kernel. Keep the original center sample sharp;
    // only add light where nearby bright pixels would bleed into darker ones.
    float3 soft = source * 0.25f;
    soft += (ContentAt(tex + float2(delta.x, 0.0f))
           + ContentAt(tex - float2(delta.x, 0.0f))
           + ContentAt(tex + float2(0.0f, delta.y))
           + ContentAt(tex - float2(0.0f, delta.y))) * 0.125f;
    soft += (ContentAt(tex + delta)
           + ContentAt(tex - delta)
           + ContentAt(tex + float2(delta.x, -delta.y))
           + ContentAt(tex + float2(-delta.x, delta.y))) * 0.0625f;
    float3 glow = max(soft - source, 0.0f) * 0.18f;

    // Fine scanlines range from 0.88 to 1.00. Compensate their average gain so
    // the full screen stays almost as bright as the unfiltered menu.
    // SV_POSITION is sampled at pixel centers; remove its half-pixel offset
    // so the alternating lines remain visible at 100% Windows display scale.
    float scanline = 0.94f + 0.06f * cos(TAU * (pos.y - 0.5f) / (2.0f * uiScale));
#ifdef OPTIMIYOO_STATIC_TIME
    float phase = 0.0f;
#else
    float phase = frac(Time / LOOP_SECONDS);
#endif

    // A soft moving highlight wraps continuously once every 8.1 seconds.
    // Periodic distance and breathing prevent a visible jump at the loop seam.
    float distance = frac(tex.y - phase + 0.5f) - 0.5f;
    float rollingBand = exp(-distance * distance / (2.0f * 0.055f * 0.055f));
    float breathing = 1.0f + 0.003f * sin(TAU * phase);
    float gain = scanline * 1.055f * breathing * (1.0f + 0.035f * rollingBand);

    // No warping, color separation, displacement, or change to app animation.
    return float4(saturate((source + glow) * gain), 1.0f);
}
