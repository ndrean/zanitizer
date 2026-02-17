#ifndef HPDF_CONFIG_H
#define HPDF_CONFIG_H

/* Tell LibHaru that we have Zlib (which we route to miniz) */
#define LIBHPDF_HAVE_ZLIB 1

/* Explicitly disable LibPNG since we do Alpha separation manually */
/* #undef LIBHPDF_HAVE_LIBPNG */
#define HPDF_NOPNGLIB 1

/* Standard Math Fallback */
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#endif