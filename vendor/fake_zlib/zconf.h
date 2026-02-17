#pragma once
/* We use miniz, which doesn't need a zconf.h, but libharu explicitly includes it.
   This empty file intercepts the include and prevents the macOS system zconf.h
   from loading and crashing the compiler. */