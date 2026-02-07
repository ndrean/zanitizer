#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_LINEAR // Optimization: We don't need linear color space for standard web canvas
#define STBI_NO_HDR    // Optimization: We don't need HDR
#include "stb_image.h"

// #define STB_IMAGE_RESIZE_IMPLEMENTATION
// #include "stb_image_resize2.h"
