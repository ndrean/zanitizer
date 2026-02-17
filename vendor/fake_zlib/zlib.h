#pragma once
#include "../miniz/miniz.h"

#ifndef ZLIB_VERSION
#define ZLIB_VERSION MZ_VERSION
#endif

/* LibHaru explicitly calls the internal zlib macros (with trailing underscores)
   to pass struct sizes. miniz doesn't map these natively, so we map them here. */
#define deflateInit_(strm, level, version, stream_size) mz_deflateInit(strm, level)
#define inflateInit_(strm, version, stream_size) mz_inflateInit(strm)

/* Also map the advanced versions just in case libharu invokes them */
#define deflateInit2_(strm, level, method, windowBits, memLevel, strategy, version, stream_size) \
  mz_deflateInit2(strm, level, method, windowBits, memLevel, strategy)
#define inflateInit2_(strm, windowBits, version, stream_size) \
  mz_inflateInit2(strm, windowBits)