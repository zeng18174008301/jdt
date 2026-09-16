//
//  AuthBackground.metal
//  BlueStoneIM
//
//  登录 / 注册页动态背景:流动极光(方案 B)。
//  仅供 SwiftUI 的 .colorEffect 调用,GPU 渲染,不占主线程。
//  注意:此文件必须加入 target 的 "Compile Sources"(Build Phases)才能被 ShaderLibrary 找到。
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

namespace authbg {
    inline float mod289(float x)  { return x - floor(x * (1.0 / 289.0)) * 289.0; }
    inline float2 mod289(float2 x){ return x - floor(x * (1.0 / 289.0)) * 289.0; }
    inline float3 mod289(float3 x){ return x - floor(x * (1.0 / 289.0)) * 289.0; }
    inline float3 permute(float3 x){ return mod289(((x * 34.0) + 1.0) * x); }

    // 2D simplex noise (Ashima / Stefan Gustavson)
    inline float snoise(float2 v) {
        const float4 C = float4(0.211324865405187, 0.366025403784439,
                                -0.577350269189626, 0.024390243902439);
        float2 i  = floor(v + dot(v, C.yy));
        float2 x0 = v - i + dot(i, C.xx);
        float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
        float4 x12 = x0.xyxy + C.xxzz;
        x12.xy -= i1;
        i = mod289(i);
        float3 p = permute(permute(i.y + float3(0.0, i1.y, 1.0))
                                 + i.x + float3(0.0, i1.x, 1.0));
        float3 m = max(0.5 - float3(dot(x0, x0),
                                    dot(x12.xy, x12.xy),
                                    dot(x12.zw, x12.zw)), 0.0);
        m = m * m; m = m * m;
        float3 x  = 2.0 * fract(p * C.www) - 1.0;
        float3 h  = abs(x) - 0.5;
        float3 ox = floor(x + 0.5);
        float3 a0 = x - ox;
        m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
        float3 g;
        g.x  = a0.x  * x0.x  + h.x  * x0.y;
        g.yz = a0.yz * x12.xz + h.yz * x12.yw;
        return 130.0 * dot(m, g);
    }

    inline float fbm(float2 p) {
        float s = 0.0, a = 0.5;
        for (int i = 0; i < 2; i++) { s += a * snoise(p); p *= 2.0; a *= 0.5; }
        return s;
    }
}

// position: 像素坐标(point);size: 视图尺寸;time: 已乘好的慢速时间(Swift 侧 elapsed*0.04)
[[ stitchable ]]
half4 auroraFlow(float2 position, half4 color, float2 size, float time) {
    using namespace authbg;
    float2 uv = position / size;
    float2 p  = uv * float2(size.x / size.y, 1.0) * 0.82;
    float  t  = time;

    float2 q = float2(fbm(p + t * 0.6),
                      fbm(p + float2(3.1, 1.7) - t * 0.5));
    float  n = fbm(p + 1.0 * q + t * 0.25);

    float3 base = float3(0.910, 0.930, 1.0);
    float3 cA   = float3(0.36, 0.43, 1.0);   // 更深的品牌蓝
    float3 cB   = float3(0.49, 0.42, 1.0);   // 更深的品牌紫
    float3 col  = base;
    col = mix(col, cA, smoothstep(0.18, 0.94, n * 0.5 + 0.5));
    col = mix(col, cB, 0.48 * smoothstep(0.48, 1.0, fbm(p + q) * 0.5 + 0.5));
    col = mix(base, col, 0.66);              // 对比加强

    return half4(half3(col), 1.0h);
}
