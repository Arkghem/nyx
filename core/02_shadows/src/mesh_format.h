// 02_shadows — binary mesh sidecar.
//
// The text `.nxscene` format is a debugging format: a human can grep it and a
// malformed line names itself. That stops working at Bistro scale, where a
// single 5.7M-triangle mesh would be hundreds of megabytes of text and tens of
// seconds of parsing. Large meshes therefore live in a `.nxmesh` sidecar next to
// the `.nxscene`, and the scene file only refers to them by name.
//
// Layout (little endian, no padding):
//
//   char     magic[8]       "NXMSH001"
//   uint32   version        1
//   uint32   vertex_count
//   uint32   index_count    multiple of three
//   uint32   flags          0
//   float    bounds_min[3]  world space
//   float    bounds_max[3]
//   float    vertices[vertex_count * 6]   px py pz nx ny nz
//   uint32   indices[index_count]
//
// The vertex layout is exactly the one the Metal shaders consume, so loading a
// mesh is a single read into a buffer with no repacking.

#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace nx::shadow {

inline constexpr char kMeshMagic[8] = {'N', 'X', 'M', 'S', 'H', '0', '0', '1'};
inline constexpr std::uint32_t kMeshVersion = 1;
inline constexpr std::size_t kMeshHeaderBytes = 48;

struct MeshFileHeader {
    char magic[8];
    std::uint32_t version;
    std::uint32_t vertex_count;
    std::uint32_t index_count;
    std::uint32_t flags;
    float bounds_min[3];
    float bounds_max[3];
};

static_assert(sizeof(MeshFileHeader) == kMeshHeaderBytes,
              "the on-disk header must stay 48 bytes");

// Reads and validates the header. `path` is opened as-is; the caller resolves
// it relative to the `.nxscene`.
bool read_mesh_header(const std::string& path, MeshFileHeader* header,
                      std::string* error);

// Reads the payload into tightly packed 6-float vertices and 32-bit indices.
// The caller can hand `vertices.data()` straight to a Metal buffer.
bool read_mesh_payload(const std::string& path, const MeshFileHeader& header,
                       std::vector<float>* vertices,
                       std::vector<std::uint32_t>* indices, std::string* error);

}  // namespace nx::shadow
