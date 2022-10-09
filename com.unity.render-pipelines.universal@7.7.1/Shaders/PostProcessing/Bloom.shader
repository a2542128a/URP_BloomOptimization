Shader "Hidden/Universal Render Pipeline/Bloom"
{
    Properties
    {
        _MainTex("Source", 2D) = "white" {}
    }

    HLSLINCLUDE

        #pragma multi_compile_local _ _USE_RGBM

        #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
        #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Filtering.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/Shaders/PostProcessing/Common.hlsl"

        TEXTURE2D_X(_MainTex);
        TEXTURE2D_X(_MainTexLowMip);

        float4 _MainTex_TexelSize;
        float4 _MainTexLowMip_TexelSize;

        float4 _Params; // x: scatter, y: clamp, z: threshold (linear), w: threshold knee
        half _Offset;

        #define Scatter             _Params.x
        #define ClampMax            _Params.y
        #define Threshold           _Params.z
        #define ThresholdKnee       _Params.w

        half4 EncodeHDR(half3 color)
        {
        #if _USE_RGBM
            half4 outColor = EncodeRGBM(color);
        #else
            half4 outColor = half4(color, 1.0);
        #endif

        #if UNITY_COLORSPACE_GAMMA
            return half4(sqrt(outColor.xyz), outColor.w); // linear to γ
        #else
            return outColor;
        #endif
        }

        half3 DecodeHDR(half4 color)
        {
        #if UNITY_COLORSPACE_GAMMA
            color.xyz *= color.xyz; // γ to linear
        #endif

        #if _USE_RGBM
            return DecodeRGBM(color);
        #else
            return color.xyz;
        #endif
        }

        half4 FragPrefilter(Varyings input) : SV_Target
        {
            UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
            float2 uv = UnityStereoTransformScreenSpaceTex(input.uv);
            half3 color = SAMPLE_TEXTURE2D_X(_MainTex, sampler_LinearClamp, uv).xyz;
            color = min(ClampMax, color);

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

        //升采样
        struct VaryingsBlurH
        {
            float4  positionCS      : SV_POSITION;
            float2  uv              : TEXCOORD0;
            float4  uv01            : TEXCOORD1;
            float4  uv23            : TEXCOORD2;
            float4  uv45            : TEXCOORD3;
            float4  uv67            : TEXCOORD4;
        };

        VaryingsBlurH VertBlurH(Attributes input)
        {
            VaryingsBlurH output;
            UNITY_SETUP_INSTANCE_ID(input);
            UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
            output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
            output.uv = input.uv;

            _MainTex_TexelSize *= 0.5;
            _Offset = float2(1 + _Offset, 1 + _Offset);
            output.uv01.xy = output.uv + float2(-_MainTex_TexelSize.x * 2, 0) * _Offset;
            output.uv01.zw = output.uv + float2(-_MainTex_TexelSize.x, _MainTex_TexelSize.y) * _Offset;
            output.uv23.xy = output.uv + float2(0, _MainTex_TexelSize.y * 2) * _Offset;
            output.uv23.zw = output.uv + _MainTex_TexelSize * _Offset;
            output.uv45.xy = output.uv + float2(_MainTex_TexelSize.x * 2, 0) * _Offset;
            output.uv45.zw = output.uv + float2(_MainTex_TexelSize.x, -_MainTex_TexelSize.y) * _Offset;
            output.uv67.xy = output.uv + float2(0, -_MainTex_TexelSize.y * 2) * _Offset;
            output.uv67.zw = output.uv - _MainTex_TexelSize * _Offset;
            return output;
        }

        half4 FragBlurH(VaryingsBlurH input) : SV_Target
        {
            UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
            half4 color = 0;
            color += SAMPLE_TEXTURE2D_X(_MainTex, sampler_LinearClamp, input.uv01.xy);
            color += SAMPLE_TEXTURE2D_X(_MainTex, sampler_LinearClamp, input.uv01.zw) * 2;
            color += SAMPLE_TEXTURE2D_X(_MainTex, sampler_LinearClamp, input.uv23.xy);
            color += SAMPLE_TEXTURE2D_X(_MainTex, sampler_LinearClamp, input.uv23.zw) * 2;
            color += SAMPLE_TEXTURE2D_X(_MainTex, sampler_LinearClamp, input.uv45.xy);
            color += SAMPLE_TEXTURE2D_X(_MainTex, sampler_LinearClamp, input.uv45.zw) * 2;
            color += SAMPLE_TEXTURE2D_X(_MainTex, sampler_LinearClamp, input.uv67.xy);
            color += SAMPLE_TEXTURE2D_X(_MainTex, sampler_LinearClamp, input.uv67.zw) * 2;
            return color * 0.0833;
        }

        //降采样
        struct VaryingsBlurV
        {
            float4  positionCS      : SV_POSITION;
            float2  uv              : TEXCOORD0;
            float4 uv01: TEXCOORD2;
            float4 uv23: TEXCOORD3;
        };


        VaryingsBlurV VertBlurV(Attributes input)
        {
            VaryingsBlurV output;
            UNITY_SETUP_INSTANCE_ID(input);
            UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
            output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
            output.uv = input.uv;

            _MainTex_TexelSize *= 0.5;
            output.uv01.xy = output.uv - _MainTex_TexelSize * float2(1 + _Offset, 1 + _Offset);
            output.uv01.zw = output.uv + _MainTex_TexelSize * float2(1 + _Offset, 1 + _Offset);
            output.uv23.xy = output.uv - float2(_MainTex_TexelSize.x, -_MainTex_TexelSize.y) * float2(1 + _Offset, 1 + _Offset);
            output.uv23.zw = output.uv + float2(_MainTex_TexelSize.x, -_MainTex_TexelSize.y) * float2(1 + _Offset, 1 + _Offset);
            return output;
        }

        half4 FragBlurV(VaryingsBlurV input) : SV_Target
        {
            //Kawase Filter
            UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
            float2 uv = UnityStereoTransformScreenSpaceTex(input.uv);
            half4 color = SAMPLE_TEXTURE2D_X(_MainTex, sampler_LinearClamp, uv) * 4;
            color += SAMPLE_TEXTURE2D_X(_MainTex, sampler_LinearClamp, input.uv01.xy);
            color += SAMPLE_TEXTURE2D_X(_MainTex, sampler_LinearClamp, input.uv01.zw);
            color += SAMPLE_TEXTURE2D_X(_MainTex, sampler_LinearClamp, input.uv23.xy);
            color += SAMPLE_TEXTURE2D_X(_MainTex, sampler_LinearClamp, input.uv23.zw);
            return color * 0.125;
        }

        half3 Upsample(float2 uv)
        {
            half3 highMip = DecodeHDR(SAMPLE_TEXTURE2D_X(_MainTex, sampler_LinearClamp, uv));

        #if _BLOOM_HQ && !defined(SHADER_API_GLES)
            half3 lowMip = DecodeHDR(SampleTexture2DBicubic(TEXTURE2D_X_ARGS(_MainTexLowMip, sampler_LinearClamp), uv, _MainTexLowMip_TexelSize.zwxy, (1.0).xx, unity_StereoEyeIndex));
        #else
            half3 lowMip = DecodeHDR(SAMPLE_TEXTURE2D_X(_MainTexLowMip, sampler_LinearClamp, uv));
        #endif

            return lerp(highMip, lowMip, Scatter);
        }

        half4 FragUpsample(Varyings input) : SV_Target
        {
            UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
            half3 color = Upsample(UnityStereoTransformScreenSpaceTex(input.uv));
            return EncodeHDR(color);
        }

    ENDHLSL

    SubShader
    {
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline"}
        LOD 100
        ZTest Always ZWrite Off Cull Off

        Pass
        {
            Name "Bloom Prefilter"

            HLSLPROGRAM
                #pragma vertex Vert
                #pragma fragment FragPrefilter
            ENDHLSL
        }
            //升
        Pass
        {
            Name "Bloom Blur Horizontal"

            HLSLPROGRAM
                #pragma vertex VertBlurH
                #pragma fragment FragBlurH
            ENDHLSL
        }
            //降
        Pass
        {
            Name "Bloom Blur Vertical"

            HLSLPROGRAM
                #pragma vertex VertBlurV
                #pragma fragment FragBlurV
            ENDHLSL
        }

        Pass
        {
            Name "Bloom Upsample"

            HLSLPROGRAM
                #pragma vertex Vert
                #pragma fragment FragUpsample
                #pragma multi_compile_local _ _BLOOM_HQ
            ENDHLSL
        }
    }
}
