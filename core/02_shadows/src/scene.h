// 02_shadows — the exported scene description.
//
// This is the only scene data the realtime renderer sees. Geometry is already
// baked into world space by scripts/export_scene.py, so there are no model
// transforms here and a mesh draw is just "vertex buffer + index buffer".

#pragma once

#include "math.h"

#include <cstddef>
#include <string>
#include <vector>

namespace nx::shadow {

struct Triangle {
    Vec3 position[3];
    Vec3 normal[3];
};

struct Mesh {
    Vec3 albedo{0.5f, 0.5f, 0.5f};
    std::vector<Triangle> triangles;
};

struct Light {
    enum class Kind { Directional, Area };

    Kind kind = Kind::Directional;

    // Directional: `direction` is the propagation direction (Mitsuba's
    // convention), `irradiance` is the irradiance on a surface perpendicular to
    // it. Shading multiplies by max(dot(n, -direction), 0).
    Vec3 direction{0.0f, -1.0f, 0.0f};
    Vec3 irradiance{1.0f, 1.0f, 1.0f};

    // Area: four world-space corners in order around the polygon and the
    // emitted radiance. The polygon normal is implicit in the corner order.
    Vec3 corners[4]{};
    Vec3 radiance{1.0f, 1.0f, 1.0f};

    Vec3 polygon_normal() const;
    float area() const;
};

struct Camera {
    Vec3 origin{0.0f, 0.0f, 0.0f};
    Vec3 right{1.0f, 0.0f, 0.0f};
    Vec3 up{0.0f, 1.0f, 0.0f};
    Vec3 forward{0.0f, 0.0f, -1.0f};

    float fov_x = 40.0f;  // degrees
    float fov_y = 40.0f;  // degrees
    float near_plane = 0.1f;
    float far_plane = 100.0f;

    int width = 768;
    int height = 768;

    Mat4 view() const;
    Mat4 projection() const;
    Mat4 view_projection() const;

    // Overrides the output resolution and recomputes the vertical field of
    // view so pixels stay square while the horizontal field of view is fixed.
    // The Mitsuba reference must use the same aspect, otherwise a comparison
    // measures the crop rather than the shadow.
    void set_resolution(int width_value, int height_value);
};

struct Scene {
    Camera camera;
    std::vector<Mesh> meshes;
    std::vector<Light> lights;

    Bounds bounds;
    std::string source_path;   // from the export header, may be empty
    long long source_mtime = 0;  // seconds since epoch, from the export header

    std::size_t triangle_count() const;
    const Light* primary_light() const;
};

// Loads a `.nxscene` file. On failure `error` carries "path:line: message" so
// the caller can print it directly.
bool load_nxscene(const std::string& path, Scene* scene, std::string* error);

}  // namespace nx::shadow
