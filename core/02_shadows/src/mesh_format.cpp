// 02_shadows — `.nxmesh` reader.
//
// Validation is deliberately strict: a bad sidecar is the first thing to
// suspect when a scene that used to render comes back with missing walls, and
// a clear error is much cheaper than a GPU hang or a silently truncated mesh.

#include "mesh_format.h"

#include <cstring>
#include <fstream>
#include <limits>

namespace nx::shadow {
namespace {

// A 5.7M-triangle Bistro mesh is the intended scale. These caps are well above
// it while still rejecting a mis-read count before allocating gigabytes.
constexpr std::uint32_t kMaxVertices = 64u * 1024u * 1024u;
constexpr std::uint32_t kMaxIndices = 256u * 1024u * 1024u;

std::uint64_t expected_file_size(const MeshFileHeader& header) {
    return static_cast<std::uint64_t>(kMeshHeaderBytes) +
           static_cast<std::uint64_t>(header.vertex_count) * 6u * sizeof(float) +
           static_cast<std::uint64_t>(header.index_count) * sizeof(std::uint32_t);
}

std::string format_path(const std::string& path, const std::string& detail) {
    return path + ": " + detail;
}

}  // namespace

bool read_mesh_header(const std::string& path, MeshFileHeader* header,
                      std::string* error) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) {
        *error = "cannot open mesh sidecar " + path;
        return false;
    }

    const std::streamoff size = file.tellg();
    if (size < static_cast<std::streamoff>(kMeshHeaderBytes)) {
        *error = format_path(path, "file is shorter than the header");
        return false;
    }
    file.seekg(0, std::ios::beg);

    MeshFileHeader result{};
    file.read(reinterpret_cast<char*>(&result), sizeof(result));
    if (!file) {
        *error = format_path(path, "cannot read the header");
        return false;
    }
    if (std::memcmp(result.magic, kMeshMagic, sizeof(kMeshMagic)) != 0) {
        *error = format_path(path, "bad magic (expected NXMSH001)");
        return false;
    }
    if (result.version != kMeshVersion) {
        *error = format_path(path, "unsupported mesh version " +
                                      std::to_string(result.version));
        return false;
    }
    if (result.flags != 0) {
        *error = format_path(path, "unsupported mesh flags " +
                                      std::to_string(result.flags));
        return false;
    }
    if (result.vertex_count == 0 || result.vertex_count > kMaxVertices ||
        result.index_count == 0 || result.index_count > kMaxIndices ||
        (result.index_count % 3u) != 0) {
        *error = format_path(path, "invalid vertex or index count");
        return false;
    }

    const std::uint64_t expected = expected_file_size(result);
    if (static_cast<std::uint64_t>(size) != expected) {
        *error = format_path(path, "file size does not match the header (" +
                                      std::to_string(size) + " vs " +
                                      std::to_string(expected) + " bytes)");
        return false;
    }

    for (int axis = 0; axis < 3; ++axis) {
        if (!(result.bounds_min[axis] <= result.bounds_max[axis])) {
            *error = format_path(path, "invalid bounds in the header");
            return false;
        }
    }

    *header = result;
    return true;
}

bool read_mesh_payload(const std::string& path, const MeshFileHeader& header,
                       std::vector<float>* vertices,
                       std::vector<std::uint32_t>* indices, std::string* error) {
    std::ifstream file(path, std::ios::binary);
    if (!file) {
        *error = "cannot open mesh sidecar " + path;
        return false;
    }
    file.seekg(static_cast<std::streamoff>(kMeshHeaderBytes), std::ios::beg);

    const std::size_t float_count =
        static_cast<std::size_t>(header.vertex_count) * 6u;
    const std::size_t index_count = header.index_count;
    vertices->resize(float_count);
    indices->resize(index_count);

    file.read(reinterpret_cast<char*>(vertices->data()),
              static_cast<std::streamsize>(float_count * sizeof(float)));
    file.read(reinterpret_cast<char*>(indices->data()),
              static_cast<std::streamsize>(index_count * sizeof(std::uint32_t)));
    if (!file) {
        *error = "cannot read the payload of " + path;
        return false;
    }

    for (std::size_t index : *indices) {
        if (index >= header.vertex_count) {
            *error = path + ": index " + std::to_string(index) +
                     " is outside the vertex buffer";
            return false;
        }
    }
    return true;
}

}  // namespace nx::shadow
