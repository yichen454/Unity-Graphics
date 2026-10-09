Shader "Hidden/Universal Render Pipeline/Bloom"
{
    HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
        #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Filtering.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
        #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/DynamicScalingClamping.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/UnityInput.hlsl"
        #include_with_pragmas "Packages/com.unity.render-pipelines.core/ShaderLibrary/FoveatedRenderingKeywords.hlsl"
        #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/FoveatedRendering.hlsl"

        TEXTURE2D_X(_SourceTexLowMip);
        float4 _SourceTexLowMip_TexelSize;

        float4 _Params; // x: scatter, y: clamp, z: threshold (linear), w: threshold knee

        #define Scatter             _Params.x
        #define ClampMax            _Params.y
        #define Threshold           _Params.z
        #define ThresholdKnee       _Params.w

        float4 _Params2; // x: kawaseDistance y: kawaseScatter z: dualScatter w: dualScatter * 0.5
        #define KawaseDistance  _Params2.x
        #define KawaseScatter   _Params2.y
        #define DualScatter     _Params2.z
        #define DualHalfScatter _Params2.w

        half4 EncodeHDR(half4 color)
        {
        #if UNITY_COLORSPACE_GAMMA
            color.xyz = sqrt(color.xyz); // linear to γ
        #endif

            return color;
        }

        half4 DecodeHDR(half4 data)
        {
            half4 color = data;

        #if UNITY_COLORSPACE_GAMMA
            color.xyz *= color.xyz; // γ to linear
        #endif

            return color;
        }

        half4 SampleHDR(float2 uv,  float2 offset)
        {
            float2 texelSize = _BlitTexture_TexelSize.xy;
            return DecodeHDR(SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, ClampUVForBilinear(uv - offset * texelSize, texelSize)));
        }

        half4 SamplePrefilter(float2 uv,  float2 offset)
        {
            float2 texelSize = _BlitTexture_TexelSize.xy;
            half4 color = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, uv + texelSize * offset);
            #if _ENABLE_ALPHA_OUTPUT
                // Premultiply RGB so transparent pixels do not generate bloom. Keep alpha for filtering and final composition.
                color.xyz *= color.w;
            #else
                color.w = 1.0;
            #endif
            return color;
        }

        half4 FragPrefilter(Varyings input) : SV_Target
        {
            UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
            float2 uv = UnityStereoTransformScreenSpaceTex(input.texcoord);

#if defined(SUPPORTS_FOVEATED_RENDERING_NON_UNIFORM_RASTER)
            UNITY_BRANCH if (_FOVEATED_RENDERING_NON_UNIFORM_RASTER)
            {
                uv = RemapFoveatedRenderingLinearToNonUniform(uv);
            }
#endif

        #if _BLOOM_HQ
            half4 A = SamplePrefilter(uv, float2(-1.0, -1.0));
            half4 B = SamplePrefilter(uv, float2( 0.0, -1.0));
            half4 C = SamplePrefilter(uv, float2( 1.0, -1.0));
            half4 D = SamplePrefilter(uv, float2(-0.5, -0.5));
            half4 E = SamplePrefilter(uv, float2( 0.5, -0.5));
            half4 F = SamplePrefilter(uv, float2(-1.0,  0.0));
            half4 G = SamplePrefilter(uv, float2( 0.0,  0.0));
            half4 H = SamplePrefilter(uv, float2( 1.0,  0.0));
            half4 I = SamplePrefilter(uv, float2(-0.5,  0.5));
            half4 J = SamplePrefilter(uv, float2( 0.5,  0.5));
            half4 K = SamplePrefilter(uv, float2(-1.0,  1.0));
            half4 L = SamplePrefilter(uv, float2( 0.0,  1.0));
            half4 M = SamplePrefilter(uv, float2( 1.0,  1.0));

            half2 div = (1.0 / 4.0) * half2(0.5, 0.125);

            half4 color = (D + E + I + J) * div.x;
            color += (A + B + G + F) * div.y;
            color += (B + C + H + G) * div.y;
            color += (F + G + L + K) * div.y;
            color += (G + H + M + L) * div.y;
        #else
            half4 color = SamplePrefilter(uv, float2(0,0));
        #endif

            // User controlled clamp to limit crazy high broken spec
            color.xyz = min(ClampMax, color.xyz);

            // Thresholding
            half brightness = Max3(color.r, color.g, color.b);
            half softness = clamp(brightness - Threshold + ThresholdKnee, 0.0, 2.0 * ThresholdKnee);
            softness = (softness * softness) / (4.0 * ThresholdKnee + 1e-4);
            half multiplier = max(brightness - Threshold, softness) / max(brightness, 1e-4);
            color *= multiplier;

            // Clamp colors to positive once in prefilter. Encode can have a sqrt, and sqrt(-x) == NaN. Up/Downsample passes would then spread the NaN.
            color = max(color, 0);
            return EncodeHDR(color);
        }

        half4 FragBlurH(Varyings input) : SV_Target
        {
            UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
            float2 texelSize = _BlitTexture_TexelSize.xy * 2.0;
            float2 uv = UnityStereoTransformScreenSpaceTex(input.texcoord);

            // 9-tap gaussian blur on the downsampled source
            half4 c0 = DecodeHDR(SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, ClampUVForBilinear(uv - float2(texelSize.x * 4.0, 0.0), texelSize)));
            half4 c1 = DecodeHDR(SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, ClampUVForBilinear(uv - float2(texelSize.x * 3.0, 0.0), texelSize)));
            half4 c2 = DecodeHDR(SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, ClampUVForBilinear(uv - float2(texelSize.x * 2.0, 0.0), texelSize)));
            half4 c3 = DecodeHDR(SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, ClampUVForBilinear(uv - float2(texelSize.x * 1.0, 0.0), texelSize)));
            half4 c4 = DecodeHDR(SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, ClampUVForBilinear(uv                                 , texelSize)));
            half4 c5 = DecodeHDR(SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, ClampUVForBilinear(uv + float2(texelSize.x * 1.0, 0.0), texelSize)));
            half4 c6 = DecodeHDR(SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, ClampUVForBilinear(uv + float2(texelSize.x * 2.0, 0.0), texelSize)));
            half4 c7 = DecodeHDR(SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, ClampUVForBilinear(uv + float2(texelSize.x * 3.0, 0.0), texelSize)));
            half4 c8 = DecodeHDR(SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, ClampUVForBilinear(uv + float2(texelSize.x * 4.0, 0.0), texelSize)));

            half4 color = c0 * 0.01621622 + c1 * 0.05405405 + c2 * 0.12162162 + c3 * 0.19459459
                        + c4 * 0.22702703
                        + c5 * 0.19459459 + c6 * 0.12162162 + c7 * 0.05405405 + c8 * 0.01621622;

            return EncodeHDR(color);
        }

        half4 FragBlurV(Varyings input) : SV_Target
        {
            UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
            float2 texelSize = _BlitTexture_TexelSize.xy;
            float2 uv = UnityStereoTransformScreenSpaceTex(input.texcoord);

            // Optimized bilinear 5-tap gaussian on the same-sized source (9-tap equivalent)
            half4 c0 = SampleHDR(uv, -float2(0.0, 3.23076923));
            half4 c1 = SampleHDR(uv, -float2(0.0, 1.38461538));
            half4 c2 = SampleHDR(uv,  float2(0.0, 0.0));
            half4 c3 = SampleHDR(uv, +float2(0.0, 1.38461538));
            half4 c4 = SampleHDR(uv, +float2(0.0, 3.23076923));

            half4 color = c0 * 0.07027027 + c1 * 0.31621622
                        + c2 * 0.22702703
                        + c3 * 0.31621622 + c4 * 0.07027027;

            return EncodeHDR(color);
        }

        half4 Upsample(float2 uv)
        {
            half4 highMip = DecodeHDR(SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, uv));

        #if _BLOOM_HQ
            half4 lowMip = DecodeHDR(SampleTexture2DBicubic(TEXTURE2D_X_ARGS(_SourceTexLowMip, sampler_LinearClamp), uv, _SourceTexLowMip_TexelSize.zwxy, (1.0).xx, unity_StereoEyeIndex));
        #else
            half4 lowMip = DecodeHDR(SAMPLE_TEXTURE2D_X(_SourceTexLowMip, sampler_LinearClamp, uv));
        #endif

            return lerp(highMip, lowMip, Scatter);
        }

        half4 FragUpsample(Varyings input) : SV_Target
        {
            UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
            half4 color = Upsample(UnityStereoTransformScreenSpaceTex(input.texcoord));
            return EncodeHDR(color);
        }

        half4 FragKawase(Varyings input) : SV_Target
        {
            UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
            float2 uv = UnityStereoTransformScreenSpaceTex(input.texcoord);

            const float d = KawaseDistance;

            half4 c0 = SampleHDR(uv, float2( d,  d));
            half4 c1 = SampleHDR(uv, float2(-d,  d));
            half4 c2 = SampleHDR(uv, float2(-d, -d));
            half4 c3 = SampleHDR(uv, float2( d, -d));

            half4 color = (c0 + c1 + c2 + c3) * 0.25;

            if (KawaseScatter < 0.999)
                color = lerp(SampleHDR(uv, float2( 0,  0)), color, Scatter);

            return EncodeHDR(color);
        }

        half4 FragDualDownsample(Varyings input) : SV_Target
        {
            UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
            float2 uv = UnityStereoTransformScreenSpaceTex(input.texcoord);

            half4 c0 = SampleHDR(uv, float2(0, 0));

            half4 c1 = SampleHDR(uv, float2( 0.5,  0.5));
            half4 c2 = SampleHDR(uv, float2(-0.5,  0.5));
            half4 c3 = SampleHDR(uv, float2(-0.5, -0.5));
            half4 c4 = SampleHDR(uv, float2( 0.5, -0.5));

            half4 color = (1.0 / 8.0) * (c0 * 4.0 + c1 + c2 + c3 + c4);

            return EncodeHDR(color);
        }

        half4 FragDualUpsample(Varyings input) : SV_Target
        {
            UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
            float2 uv = UnityStereoTransformScreenSpaceTex(input.texcoord);

            const float hs = DualHalfScatter;
            half4 c1 = SampleHDR(uv, float2( hs,  hs));
            half4 c2 = SampleHDR(uv, float2(-hs,  hs));
            half4 c3 = SampleHDR(uv, float2(-hs, -hs));
            half4 c4 = SampleHDR(uv, float2( hs, -hs));

            const float s = DualScatter;
            half4 c5 = SampleHDR(uv, float2(-s, 0.0));
            half4 c6 = SampleHDR(uv, float2( s, 0.0));
            half4 c7 = SampleHDR(uv, float2( 0.0,  s));
            half4 c8 = SampleHDR(uv, float2( 0.0, -s));

            half4 color = (1.0 / 12.0) *
                ((c1 + c2 + c3 + c4) * 2.0 +
                  c5 + c6 + c7 + c8);

            return EncodeHDR(color);
        }


    ENDHLSL

    SubShader
    {
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline"}
        LOD 100
        ZTest Always ZWrite Off Cull Off

        Pass // 0
        {
            Name "Bloom Prefilter"

            HLSLPROGRAM
                #pragma vertex Vert
                #pragma fragment FragPrefilter
                #pragma multi_compile_local_fragment _ _BLOOM_HQ
                #pragma multi_compile_fragment _ _ENABLE_ALPHA_OUTPUT
            ENDHLSL
        }

        Pass // 1
        {
            Name "Bloom Blur Horizontal"

            HLSLPROGRAM
                #pragma vertex Vert
                #pragma fragment FragBlurH
            ENDHLSL
        }

        Pass // 2
        {
            Name "Bloom Blur Vertical"

            HLSLPROGRAM
                #pragma vertex Vert
                #pragma fragment FragBlurV
            ENDHLSL
        }

        Pass // 3
        {
            Name "Bloom Upsample"

            HLSLPROGRAM
                #pragma vertex Vert
                #pragma fragment FragUpsample
                #pragma multi_compile_local_fragment _ _BLOOM_HQ
            ENDHLSL
        }

        Pass // 4
        {
            Name "Bloom Kawase"

            HLSLPROGRAM
                #pragma vertex Vert
                #pragma fragment FragKawase
            ENDHLSL
        }

        Pass // 5
        {
            Name "Bloom Dual Downsample"

            HLSLPROGRAM
                #pragma vertex Vert
                #pragma fragment FragDualDownsample
            ENDHLSL
        }

        Pass // 6
        {
            Name "Bloom Dual Upsample"

            HLSLPROGRAM
                #pragma vertex Vert
                #pragma fragment FragDualUpsample
            ENDHLSL
        }
    }
}
