// 02_shadows — small vector and matrix math.
//
// Deliberately dependency-free and header-only: the scene parser and the
// projection self-test must build without Metal, and the same values are fed
// to the GPU as `setBytes` payloads.
//
// Conventions
//   * Column-major matrices, matching Metal's `float4x4` memory layout.
//   * Right-handed world space, Y up.
//   * Cameras look down -Z in view space; clip-space depth is [0, 1] (the Metal
//     convention), not OpenGL's [-1, 1].
//
// The camera basis comes from the Mitsuba scene exporter, which derives it from
// sensor sample rays. Do not replace it with a generic look_at: Mitsuba's sensor
// `to_world` axes are not the film's left/right/forward axes.

#pragma once

#include <cmath>
#include <cstddef>

namespace nx::shadow {

constexpr float kPi = 3.14159265358979323846f;

inline float radians(float degrees) { return degrees * (kPi / 180.0f); }
inline float degrees(float radians_value) { return radians_value * (180.0f / kPi); }
inline float clampf(float value, float low, float high) {
    return value < low ? low : (value > high ? high : value);
}

struct Vec3 {
    float x = 0.0f;
    float y = 0.0f;
    float z = 0.0f;

    Vec3() = default;
    Vec3(float x_value, float y_value, float z_value) : x(x_value), y(y_value), z(z_value) {}

    float*       data() { return &x; }
    const float* data() const { return &x; }
};

inline Vec3 operator+(Vec3 a, Vec3 b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
inline Vec3 operator-(Vec3 a, Vec3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
inline Vec3 operator*(Vec3 a, float s) { return {a.x * s, a.y * s, a.z * s}; }
inline Vec3 operator*(float s, Vec3 a) { return a * s; }
inline Vec3 operator/(Vec3 a, float s) { return {a.x / s, a.y / s, a.z / s}; }
inline Vec3& operator+=(Vec3& a, Vec3 b) { a = a + b; return a; }

inline float dot(Vec3 a, Vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline Vec3 cross(Vec3 a, Vec3 b) {
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
inline float length(Vec3 v) { return std::sqrt(dot(v, v)); }

inline Vec3 normalize(Vec3 v, Vec3 fallback = {0.0f, 0.0f, 1.0f}) {
    const float len = length(v);
    if (!std::isfinite(len) || len < 1e-20f) {
        return fallback;
    }
    return v / len;
}

struct Vec4 {
    float x = 0.0f;
    float y = 0.0f;
    float z = 0.0f;
    float w = 0.0f;

    Vec4() = default;
    Vec4(float x_value, float y_value, float z_value, float w_value)
        : x(x_value), y(y_value), z(z_value), w(w_value) {}
    explicit Vec4(Vec3 v, float w_value = 1.0f) : x(v.x), y(v.y), z(v.z), w(w_value) {}
};

// Column-major 4x4 matrix: m[column * 4 + row].
struct Mat4 {
    float m[16] = {1.0f, 0.0f, 0.0f, 0.0f,
                   0.0f, 1.0f, 0.0f, 0.0f,
                   0.0f, 0.0f, 1.0f, 0.0f,
                   0.0f, 0.0f, 0.0f, 1.0f};

    static Mat4 identity() { return {}; }
    float&       at(int column, int row) { return m[column * 4 + row]; }
    const float& at(int column, int row) const { return m[column * 4 + row]; }
};

inline Mat4 operator*(const Mat4& a, const Mat4& b) {
    Mat4 result;
    for (int column = 0; column < 4; ++column) {
        for (int row = 0; row < 4; ++row) {
            float sum = 0.0f;
            for (int k = 0; k < 4; ++k) {
                sum += a.m[k * 4 + row] * b.m[column * 4 + k];
            }
            result.m[column * 4 + row] = sum;
        }
    }
    return result;
}

inline Vec4 operator*(const Mat4& matrix, const Vec4& vector) {
    return {
        matrix.m[0] * vector.x + matrix.m[4] * vector.y + matrix.m[8] * vector.z + matrix.m[12] * vector.w,
        matrix.m[1] * vector.x + matrix.m[5] * vector.y + matrix.m[9] * vector.z + matrix.m[13] * vector.w,
        matrix.m[2] * vector.x + matrix.m[6] * vector.y + matrix.m[10] * vector.z + matrix.m[14] * vector.w,
        matrix.m[3] * vector.x + matrix.m[7] * vector.y + matrix.m[11] * vector.z + matrix.m[15] * vector.w,
    };
}

// Homogeneous transform with the perspective divide.
inline Vec3 transform_point(const Mat4& matrix, Vec3 point) {
    const Vec4 result = matrix * Vec4(point, 1.0f);
    if (std::fabs(result.w) < 1e-20f) {
        return {result.x, result.y, result.z};
    }
    const float inverse_w = 1.0f / result.w;
    return {result.x * inverse_w, result.y * inverse_w, result.z * inverse_w};
}

inline Vec3 transform_vector(const Mat4& matrix, Vec3 vector) {
    const Vec4 result = matrix * Vec4(vector, 0.0f);
    return {result.x, result.y, result.z};
}

// View matrix from an explicit orthonormal basis. Rows are right, up, -forward
// (the camera looks along -Z in view space).
inline Mat4 view_from_basis(Vec3 origin, Vec3 right, Vec3 up, Vec3 forward) {
    Mat4 view = Mat4::identity();
    view.m[0] = right.x;
    view.m[1] = up.x;
    view.m[2] = -forward.x;
    view.m[4] = right.y;
    view.m[5] = up.y;
    view.m[6] = -forward.y;
    view.m[8] = right.z;
    view.m[9] = up.z;
    view.m[10] = -forward.z;
    view.m[12] = -dot(right, origin);
    view.m[13] = -dot(up, origin);
    view.m[14] = dot(forward, origin);
    view.m[15] = 1.0f;
    return view;
}

inline Mat4 look_at(Vec3 eye, Vec3 target, Vec3 up) {
    const Vec3 forward = normalize(target - eye);
    Vec3 right = cross(forward, up);
    if (length(right) < 1e-6f) {
        // Degenerate up vector: pick another one instead of producing NaNs.
        right = cross(forward, Vec3(0.0f, 0.0f, 1.0f));
        if (length(right) < 1e-6f) {
            right = cross(forward, Vec3(0.0f, 1.0f, 0.0f));
        }
    }
    right = normalize(right);
    const Vec3 true_up = normalize(cross(right, forward));
    return view_from_basis(eye, right, true_up, forward);
}

// Right-handed perspective projection with clip-space depth in [0, 1].
inline Mat4 perspective(float fov_x_degrees, float fov_y_degrees, float near_plane,
                        float far_plane) {
    Mat4 projection = {};
    const float tan_x = std::tan(radians(fov_x_degrees) * 0.5f);
    const float tan_y = std::tan(radians(fov_y_degrees) * 0.5f);
    projection.m[0] = 1.0f / tan_x;
    projection.m[5] = 1.0f / tan_y;
    projection.m[10] = far_plane / (near_plane - far_plane);
    projection.m[11] = -1.0f;
    projection.m[14] = near_plane * far_plane / (near_plane - far_plane);
    projection.m[15] = 0.0f;
    return projection;
}

// Right-handed orthographic projection with clip-space depth in [0, 1].
inline Mat4 ortho(float left, float right, float bottom, float top, float near_plane,
                  float far_plane) {
    Mat4 projection = {};
    projection.m[0] = 2.0f / (right - left);
    projection.m[5] = 2.0f / (top - bottom);
    projection.m[10] = -1.0f / (far_plane - near_plane);
    projection.m[12] = -(right + left) / (right - left);
    projection.m[13] = -(top + bottom) / (top - bottom);
    projection.m[14] = -near_plane / (far_plane - near_plane);
    projection.m[15] = 1.0f;
    return projection;
}

inline Mat4 inverse(const Mat4& matrix) {
    const float* m = matrix.m;
    float inv[16] = {};

    inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] +
             m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
    inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] -
             m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
    inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] +
             m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
    inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] -
              m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
    inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] -
             m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
    inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] +
             m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
    inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] -
             m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
    inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] +
              m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
    inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] +
             m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
    inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] -
             m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
    inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] +
              m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
    inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] -
              m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
    inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] -
             m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
    inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] +
             m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
    inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] -
              m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
    inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] +
              m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];

    const float determinant = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] +
                              m[3] * inv[12];
    if (std::fabs(determinant) < 1e-20f) {
        return Mat4::identity();
    }
    const float scale = 1.0f / determinant;
    Mat4 result;
    for (int i = 0; i < 16; ++i) {
        result.m[i] = inv[i] * scale;
    }
    return result;
}

// Positive view-space distance for a clip-space depth in [0, 1].
inline float linearize_depth(float depth_ndc, float near_plane, float far_plane) {
    return (near_plane * far_plane) /
           (depth_ndc * (near_plane - far_plane) + far_plane);
}

// Screen pixel (x, y), top-left origin, to the NDC used by the projection.
// Metal's render target y grows downward while NDC y grows upward, so the two
// flips in this file are not redundant: one is the viewport, this one is the
// manual reconstruction in a compute shader.
inline Vec3 pixel_to_ndc(float x, float y, float width, float height, float depth) {
    return {(x + 0.5f) / width * 2.0f - 1.0f,
            1.0f - (y + 0.5f) / height * 2.0f,
            depth};
}

struct Bounds {
    Vec3 minimum{1e30f, 1e30f, 1e30f};
    Vec3 maximum{-1e30f, -1e30f, -1e30f};
    bool valid = false;

    void expand(Vec3 point) {
        minimum.x = std::fmin(minimum.x, point.x);
        minimum.y = std::fmin(minimum.y, point.y);
        minimum.z = std::fmin(minimum.z, point.z);
        maximum.x = std::fmax(maximum.x, point.x);
        maximum.y = std::fmax(maximum.y, point.y);
        maximum.z = std::fmax(maximum.z, point.z);
        valid = true;
    }

    Vec3 center() const { return (minimum + maximum) * 0.5f; }
    Vec3 extent() const { return maximum - minimum; }
    float radius() const { return length(extent()) * 0.5f; }
};

}  // namespace nx::shadow
