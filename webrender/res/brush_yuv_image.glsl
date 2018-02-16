/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#define VECS_PER_SPECIFIC_BRUSH 0

#include shared,prim_shared,brush

// TODO(gw): Consider whether we should even have separate shader compilations
//           for the various YUV modes. To save on the number of shaders we
//           need to compile, it might be worth just doing this as an
//           uber-shader instead.
// TODO(gw): Regardless of the above, we should remove the separate shader
//           compilations for the different color space matrix below. That
//           can be provided by a branch in the VS and pushed through the
//           interpolators, or even as a uniform that breaks batches, rather
//           that needing to compile / switch to a different shader when
//           there is a different color space.

#ifdef WR_FEATURE_ALPHA_PASS
varying vec2 vLocalPos;
#endif

#if defined (WR_FEATURE_YUV_PLANAR)
    varying vec3 vUv_Y;
    flat varying vec4 vUvBounds_Y;

    varying vec3 vUv_U;
    flat varying vec4 vUvBounds_U;

    varying vec3 vUv_V;
    flat varying vec4 vUvBounds_V;
#elif defined (WR_FEATURE_YUV_NV12)
    varying vec3 vUv_Y;
    flat varying vec4 vUvBounds_Y;

    varying vec3 vUv_UV;
    flat varying vec4 vUvBounds_UV;
#elif defined (WR_FEATURE_YUV_INTERLEAVED)
    varying vec3 vUv_YUV;
    flat varying vec4 vUvBounds_YUV;
#endif

#ifdef WR_VERTEX_SHADER
void write_uv_rect(
    ImageResource res,
    vec2 f,
    vec2 texture_size,
    out vec3 uv,
    out vec4 uv_bounds
) {
    vec2 uv0 = res.uv_rect.p0;
    vec2 uv1 = res.uv_rect.p1;

    uv.xy = mix(uv0, uv1, f);
    uv.z = res.layer;

    uv_bounds = vec4(uv0 + vec2(0.5), uv1 - vec2(0.5));

    #ifndef WR_FEATURE_TEXTURE_RECT
        uv.xy /= texture_size;
        uv_bounds /= texture_size.xyxy;
    #endif
}

void brush_vs(
    VertexInfo vi,
    int prim_address,
    RectWithSize local_rect,
    ivec3 user_data,
    PictureTask pic_task
) {
    vec2 f = (vi.local_pos - local_rect.p0) / local_rect.size;

#ifdef WR_FEATURE_ALPHA_PASS
    vLocalPos = vi.local_pos;
#endif

#if defined (WR_FEATURE_YUV_PLANAR)
    ImageResource y_rect = fetch_image_resource(user_data.x);
    write_uv_rect(y_rect, f, textureSize(sColor0, 0).xy, vUv_Y, vUvBounds_Y);

    ImageResource u_rect = fetch_image_resource(user_data.y);
    write_uv_rect(u_rect, f, textureSize(sColor1, 0).xy, vUv_U, vUvBounds_U);

    ImageResource v_rect = fetch_image_resource(user_data.z);
    write_uv_rect(v_rect, f, textureSize(sColor2, 0).xy, vUv_V, vUvBounds_V);
#elif defined (WR_FEATURE_YUV_NV12)
    ImageResource y_rect = fetch_image_resource(user_data.x);
    write_uv_rect(y_rect, f, textureSize(sColor0, 0).xy, vUv_Y, vUvBounds_Y);

    ImageResource uv_rect = fetch_image_resource(user_data.y);
    write_uv_rect(uv_rect, f, textureSize(sColor1, 0).xy, vUv_UV, vUvBounds_UV);
#elif defined (WR_FEATURE_YUV_INTERLEAVED)
    ImageResource yuv_rect = fetch_image_resource(user_data.x);
    write_uv_rect(yuv_rect, f, textureSize(sColor0, 0).xy, vUv_YUV, vUvBounds_YUV);
#endif
}
#endif

#ifdef WR_FRAGMENT_SHADER

#if !defined(WR_FEATURE_YUV_REC601) && !defined(WR_FEATURE_YUV_REC709)
#define WR_FEATURE_YUV_REC601
#endif

// The constants added to the Y, U and V components are applied in the fragment shader.
#if defined(WR_FEATURE_YUV_REC601)
// From Rec601:
// [R]   [1.1643835616438356,  0.0,                 1.5960267857142858   ]   [Y -  16]
// [G] = [1.1643835616438358, -0.3917622900949137, -0.8129676472377708   ] x [U - 128]
// [B]   [1.1643835616438356,  2.017232142857143,   8.862867620416422e-17]   [V - 128]
//
// For the range [0,1] instead of [0,255].
//
// The matrix is stored in column-major.
const mat3 YuvColorMatrix = mat3(
    1.16438,  1.16438, 1.16438,
    0.0,     -0.39176, 2.01723,
    1.59603, -0.81297, 0.0
);
#elif defined(WR_FEATURE_YUV_REC709)
// From Rec709:
// [R]   [1.1643835616438356,  4.2781193979771426e-17, 1.7927410714285714]   [Y -  16]
// [G] = [1.1643835616438358, -0.21324861427372963,   -0.532909328559444 ] x [U - 128]
// [B]   [1.1643835616438356,  2.1124017857142854,     0.0               ]   [V - 128]
//
// For the range [0,1] instead of [0,255]:
//
// The matrix is stored in column-major.
const mat3 YuvColorMatrix = mat3(
    1.16438,  1.16438,  1.16438,
    0.0    , -0.21325,  2.11240,
    1.79274, -0.53291,  0.0
);
#endif

vec4 brush_fs() {
    vec3 yuv_value;

#if defined (WR_FEATURE_YUV_PLANAR)
    // The yuv_planar format should have this third texture coordinate.
    vec2 uv_y = clamp(vUv_Y.xy, vUvBounds_Y.xy, vUvBounds_Y.zw);
    vec2 uv_u = clamp(vUv_U.xy, vUvBounds_U.xy, vUvBounds_U.zw);
    vec2 uv_v = clamp(vUv_V.xy, vUvBounds_V.xy, vUvBounds_V.zw);
    yuv_value.x = TEX_SAMPLE(sColor0, vec3(uv_y, vUv_Y.z)).r;
    yuv_value.y = TEX_SAMPLE(sColor1, vec3(uv_u, vUv_U.z)).r;
    yuv_value.z = TEX_SAMPLE(sColor2, vec3(uv_v, vUv_V.z)).r;
#elif defined (WR_FEATURE_YUV_NV12)
    vec2 uv_y = clamp(vUv_Y.xy, vUvBounds_Y.xy, vUvBounds_Y.zw);
    vec2 uv_uv = clamp(vUv_UV.xy, vUvBounds_UV.xy, vUvBounds_UV.zw);
    yuv_value.x = TEX_SAMPLE(sColor0, vec3(uv_y, vUv_Y.z)).r;
    yuv_value.yz = TEX_SAMPLE(sColor1, vec3(uv_uv, vUv_UV.z)).rg;
#elif defined (WR_FEATURE_YUV_INTERLEAVED)
    // "The Y, Cb and Cr color channels within the 422 data are mapped into
    // the existing green, blue and red color channels."
    // https://www.khronos.org/registry/OpenGL/extensions/APPLE/APPLE_rgb_422.txt
    vec2 uv_y = clamp(vUv_YUV.xy, vUvBounds_YUV.xy, vUvBounds_YUV.zw);
    yuv_value = TEX_SAMPLE(sColor0, vec3(uv_y, vUv_YUV.z)).gbr;
#else
    yuv_value = vec3(0.0);
#endif

    // See the YuvColorMatrix definition for an explanation of where the constants come from.
    vec3 rgb = YuvColorMatrix * (yuv_value - vec3(0.06275, 0.50196, 0.50196));
    vec4 color = vec4(rgb, 1.0);

#ifdef WR_FEATURE_ALPHA_PASS
    color *= init_transform_fs(vLocalPos);
#endif

    return color;
}
#endif