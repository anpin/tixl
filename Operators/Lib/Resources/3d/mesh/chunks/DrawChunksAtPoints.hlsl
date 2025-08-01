#include "shared/point.hlsl"
#include "shared/quat-functions.hlsl"
#include "shared/point-light.hlsl"
#include "shared/pbr.hlsl"

cbuffer Transforms : register(b0)
{
    float4x4 CameraToClipSpace;
    float4x4 ClipSpaceToCamera;
    float4x4 WorldToCamera;
    float4x4 CameraToWorld;
    float4x4 WorldToClipSpace;
    float4x4 ClipSpaceToWorld;
    float4x4 ObjectToWorld;
    float4x4 WorldToObject;
    float4x4 ObjectToCamera;
    float4x4 ObjectToClipSpace;
};

cbuffer Params : register(b1)
{
    float4x4 WorldToLightClipSpace;
    float4 Color;

    float Size;
    float AlphaCutOff;
    float ShadowOffset;
    float ShadowBias;

    float4 ShadowColor;
};

cbuffer Params : register(b2)
{
    int SegmentCount;
    int UseWForSize;
    int UseStretch;
    int IsShadowPass;
};

cbuffer FogParams : register(b3)
{
    float4 FogColor;
    float FogDistance;
    float FogBias;
}

cbuffer PointLights : register(b4)
{
    PointLight Lights[8];
    int ActiveLightCount;
}

cbuffer PbrParams : register(b5)
{
    float4 BaseColor;
    float4 EmissiveColor;
    float Roughness;
    float Specular;
    float Metal;
}

struct psInput
{
    float2 texCoord : TEXCOORD;
    float4 pixelPosition : SV_POSITION;
    float4 color : COLOR;
    float3 worldPosition : POSITION;
    float3x3 tbnToWorld : TBASIS;
    float fog : VPOS;
    float4 positionInLightClipSpace : LIGHTCLIPPOS;
};

struct IndicesForDraw
{
    int PointIndex;
    int3 VertexIndices;
};

sampler texSampler : register(s0);
sampler clampedSampler : register(s1);

StructuredBuffer<PbrVertex> PbrVertices : register(t0);
StructuredBuffer<Point> Points : register(t1);
StructuredBuffer<IndicesForDraw> DrawData : register(t2);

Texture2D<float4> BaseColorMap : register(t3);
Texture2D<float4> EmissiveColorMap : register(t4);
Texture2D<float4> RSMOMap : register(t5);
Texture2D<float4> NormalMap : register(t6);
TextureCube<float4> PrefilteredSpecular : register(t7);
Texture2D<float4> BRDFLookup : register(t8);
Texture2D<float> ShadowMap : register(t9);

psInput vsMain(uint id : SV_VertexID)
{
    psInput output;

    uint drawFaceIndex = id / 3;
    uint faceVertexIndex = id % 3;
    uint vertexIndex = DrawData[drawFaceIndex].VertexIndices[faceVertexIndex];
    uint pointIndex = DrawData[drawFaceIndex].PointIndex;

    PbrVertex vertex = PbrVertices[vertexIndex];
    float4 posInObject = float4(vertex.Position, 1);

    float resizeFromW = UseWForSize ? Points[pointIndex].FX1 : 1;
    float3 resizeFromStretch = UseStretch ? Points[pointIndex].Scale : 1;
    posInObject.xyz *= max(0, resizeFromW) * Size * resizeFromStretch;
    float4x4 orientationMatrix = transpose(qToMatrix(normalize(Points[pointIndex].Rotation)));
    posInObject = mul(float4(posInObject.xyz, 1), orientationMatrix);

    posInObject += float4(Points[pointIndex].Position, 0);
    output.color = Points[pointIndex].Color;

    float4 posInClipSpace = mul(posInObject, ObjectToClipSpace);
    output.pixelPosition = posInClipSpace;

    float2 uv = vertex.TexCoord;
    output.texCoord = float2(uv.x, 1 - uv.y);

    // Offset position along normal for shadow mapping
    float4 posInWorld = mul(posInObject, ObjectToWorld);
    output.worldPosition = posInWorld.xyz;

    float3 worldNormal = normalize(mul(float4(vertex.Normal, 0), (float4x4)ObjectToWorld).xyz);
    float4 posInWorldOffset = posInWorld;
    posInWorldOffset.xyz += worldNormal * ShadowOffset;
    output.positionInLightClipSpace = mul(posInWorldOffset, WorldToLightClipSpace);

    // Pass tangent space basis vectors (for normal mapping).
    float3x3 TBN = float3x3(vertex.Tangent, vertex.Bitangent, vertex.Normal);
    TBN = mul(TBN, (float3x3)orientationMatrix);
    TBN = mul(TBN, (float3x3)ObjectToWorld);

    output.tbnToWorld = float3x3(
        normalize(TBN._m00_m01_m02),
        normalize(TBN._m10_m11_m12),
        normalize(TBN._m20_m21_m22));

    // Fog
    if (FogDistance > 0)
    {
        float4 posInCamera = mul(posInObject, ObjectToCamera);
        float fog = pow(saturate(-posInCamera.z / FogDistance), FogBias);
        output.fog = fog;
    }

    return output;
}

inline float ComputeShadowFactor(float3 shadowCoord, float2 texelSize, float bias)
{
    float shadow = 0.0;
    int samples = 0;
    for (int y = -1; y <= 1; y++)
    {
        for (int x = -1; x <= 1; x++)
        {
            float2 offset = float2(x, y) * texelSize;
            float2 sampleUV = shadowCoord.xy + offset;

            // Sample only if sampleUV is within [0,1]
            if (sampleUV.x >= 0 && sampleUV.x <= 1 && sampleUV.y >= 0 && sampleUV.y <= 1)
            {
                float sampleDepth = ShadowMap.Sample(clampedSampler, sampleUV);

                // Compare depths with bias
                if (shadowCoord.z > sampleDepth + bias)
                {
                    shadow += 1.0;
                }
            }
            samples++;
        }
    }
    return 1.0 - (shadow / samples);
}

float4 psMain(psInput pin) : SV_TARGET
{
    // Sample input textures to get shading model params.
    float4 albedo = BaseColorMap.Sample(texSampler, pin.texCoord) * pin.color;
    if (AlphaCutOff > 0 && albedo.a < AlphaCutOff)
        discard;

    float4 roughnessMetallicOcclusion = RSMOMap.Sample(texSampler, pin.texCoord);
    float roughness = saturate(roughnessMetallicOcclusion.x + Roughness);
    float metalness = saturate(roughnessMetallicOcclusion.y + Metal);
    float occlusion = roughnessMetallicOcclusion.z;

    // Outgoing light direction (vector from world-space fragment position to the "eye").
    float3 eyePosition = mul(float4(0, 0, 0, 1), CameraToWorld).xyz;
    float3 Lo = normalize(eyePosition - pin.worldPosition);

    // Get current fragment's normal and transform to world space.
    float3 N = normalize(2.0 * NormalMap.Sample(texSampler, pin.texCoord).rgb - 1.0);

    // return float4(pin.tbnToWorld[0],1);
    N = normalize(mul(N, pin.tbnToWorld));

    // Angle between surface normal and outgoing light direction.
    float cosLo = max(0.0, dot(N, Lo));

    // Specular reflection vector.
    float3 Lr = 2.0 * cosLo * N - Lo;

    // Fresnel reflectance at normal incidence (for metals use albedo color).
    float3 F0 = lerp(Fdielectric, albedo.rgb, metalness);

    // Direct lighting calculation for analytical lights.
    // Direct lighting calculation for analytical lights.
    float3 directLighting = 0.0;
    for (int i = 0; i < ActiveLightCount; ++i)
    {
        float3 Li = Lights[i].position - pin.worldPosition; //- Lights[i].direction;
        float distance = length(Li);
        float intensity = Lights[i].intensity / (pow(distance / Lights[i].range, Lights[i].decay) + 1);
        float3 Lradiance = Lights[i].color.rgb * intensity; // Lights[i].radiance;

        // Half-vector between Li and Lo.
        float3 Lh = normalize(Li + Lo);

        // Calculate angles between surface normal and various light vectors.
        float cosLi = max(0.0, dot(N, Li));
        float cosLh = max(0.0, dot(N, Lh));

        // Calculate Fresnel term for direct lighting.
        float3 F = fresnelSchlick(F0, max(0.0, dot(Lh, Lo)));

        // Calculate normal distribution for specular BRDF.
        float D = ndfGGX(cosLh, roughness);
        // Calculate geometric attenuation for specular BRDF.
        float G = gaSchlickGGX(cosLi, cosLo, roughness);

        // Diffuse scattering happens due to light being refracted multiple times by a dielectric medium.
        // Metals on the other hand either reflect or absorb energy, so diffuse contribution is always zero.
        // To be energy conserving we must scale diffuse BRDF contribution based on Fresnel factor & metalness.
        float3 kd = lerp(float3(1, 1, 1), float3(0, 0, 0), metalness);
        // return float4(F, 1);

        // Lambert diffuse BRDF.
        // We don't scale by 1/PI for lighting & material units to be more convenient.
        // See: https://seblagarde.wordpress.com/2012/01/08/pi-or-not-to-pi-in-game-lighting-equation/
        float3 diffuseBRDF = kd * albedo.rgb;

        // Cook-Torrance specular microfacet BRDF.
        float3 specularBRDF = ((F * D * G) / max(Epsilon, 4.0 * cosLi * cosLo)) * Specular;

        // Total contribution for this light.
        directLighting += (diffuseBRDF + specularBRDF) * Lradiance * cosLi;
    }

    // Ambient lighting (IBL).
    float3 ambientLighting = 0;
    {
        // Sample diffuse irradiance at normal direction.
        uint width, height, levels;
        PrefilteredSpecular.GetDimensions(0, width, height, levels);
        float3 irradiance = PrefilteredSpecular.SampleLevel(texSampler, Lr.xyz, 0.8 * levels).rgb;

        // Calculate Fresnel term for ambient lighting.
        // Since we use pre-filtered cubemap(s) and irradiance is coming from many directions
        // use cosLo instead of angle with light's half-vector (cosLh above).
        // See: https://seblagarde.wordpress.com/2011/08/17/hello-world/
        float3 F = fresnelSchlick(F0, cosLo);

        // Get diffuse contribution factor (as with direct lighting).
        float3 kd = lerp(1.0 - F, 0.0, metalness);

        // Irradiance map contains exitant radiance assuming Lambertian BRDF, no need to scale by 1/PI here either.
        float3 diffuseIBL = kd * albedo.rgb * irradiance;

        // Sample pre-filtered specular reflection environment at correct mipmap level.
        float3 specularIrradiance = PrefilteredSpecular.SampleLevel(texSampler, Lr.xyz, roughness * levels).rgb;

        // Split-sum approximation factors for Cook-Torrance specular BRDF.
        float2 specularBRDF = BRDFLookup.SampleLevel(clampedSampler, float2(cosLo, roughness), 0).rg;

        // Total specular IBL contribution.
        float3 specularIBL = (F0 * specularBRDF.x + specularBRDF.y) * specularIrradiance;

        // Total ambient lighting contribution.
        ambientLighting = diffuseIBL + specularIBL;
    }

    float shadowFactor = 1.0;

    if (!IsShadowPass)
    {
        // Compute shadow coordinates
        float3 shadowCoord = pin.positionInLightClipSpace.xyz / pin.positionInLightClipSpace.w;
        shadowCoord.xy = shadowCoord.xy * 0.5 + 0.5;
        shadowCoord.y = 1 - shadowCoord.y;

        // Compute shadow map texel size
        uint shadowMapWidth, shadowMapHeight;
        ShadowMap.GetDimensions(shadowMapWidth, shadowMapHeight);
        float2 shadowMapTexelSize = float2(1.0 / shadowMapWidth, 1.0 / shadowMapHeight);

        // float shadowFactor = 1.0;

        // Check if shadowCoord is within [0,1]
        if (shadowCoord.x >= 0 && shadowCoord.x <= 1 && shadowCoord.y >= 0 && shadowCoord.y <= 1)
        {
            shadowFactor = ComputeShadowFactor(shadowCoord, shadowMapTexelSize, ShadowBias);
        }
    }

    // Final fragment color.
    float4 litColor = float4(directLighting + ambientLighting, 1.0) * BaseColor * Color;
    litColor.rgb = lerp(litColor.rgb, ShadowColor.rgb, (1 - shadowFactor) * ShadowColor.a);

    litColor += float4(EmissiveColorMap.Sample(texSampler, pin.texCoord).rgb * EmissiveColor.rgb, 0);
    litColor.rgb = lerp(litColor.rgb, FogColor.rgb, pin.fog);
    litColor.a *= albedo.a;
    // if (!IsShadowPass)
    //     litColor.r = 0.5;
    return litColor;
}
