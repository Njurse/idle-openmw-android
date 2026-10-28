/*
 * Redirect OSG's GLES library probes to gl4es (lib/libGL.so).
 *
 * The prebuilt OSG in openmw-android-deps resolves extension entry points itself:
 * isGLExtensionOrVersionSupported() does dlopen("libGLESv2.so") + dlsym("glGetStringi"),
 * and getGLExtensionFuncPtr() does the same for every extension. On Android that is the
 * SYSTEM driver, while every core GL call (glGetIntegerv, glGetString, ...) goes to gl4es.
 * So OSG asks gl4es for GL_NUM_EXTENSIONS, then walks that count with the driver's
 * glGetStringi; the driver returns NULL past its own (shorter) list and std::string(NULL)
 * -> strlen(NULL) -> SIGSEGV in Viewer::realize (seen on SM-S916U1, index 86).
 *
 * libopenmw.so is linked with -Wl,--wrap=dlopen (configure-android.sh), so every dlopen
 * made from inside libopenmw (OSG included, it is static) comes here first. SDL2 and gl4es
 * are separate .so files and keep loading the real driver.
 */
#include <dlfcn.h>
#include <string.h>
#include <android/log.h>

void* __real_dlopen(const char* filename, int flags);

void* __wrap_dlopen(const char* filename, int flags)
{
    if (filename != NULL
        && (strcmp(filename, "libGLESv2.so") == 0 || strcmp(filename, "libGLESv3.so") == 0
            || strcmp(filename, "libGLESv1_CM.so") == 0 || strcmp(filename, "libGLES_CM.so") == 0))
    {
        void* gl4es = __real_dlopen("libGL.so", flags);
        if (gl4es != NULL)
        {
            __android_log_print(ANDROID_LOG_INFO, "idle-openmw", "dlopen(%s) -> gl4es libGL.so", filename);
            return gl4es;
        }
        __android_log_print(ANDROID_LOG_WARN, "idle-openmw", "dlopen(%s): libGL.so not loadable, using driver", filename);
    }
    return __real_dlopen(filename, flags);
}
