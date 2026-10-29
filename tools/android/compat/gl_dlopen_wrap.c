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

/*
 * Null-guard for glGetStringi (libopenmw.so is also linked with -Wl,--wrap=dlsym).
 *
 * Even with the dlopen redirect, OSG walks GL_NUM_EXTENSIONS with glGetStringi and builds a
 * std::string from every result. If the implementation returns NULL for an index (or has no
 * glGetStringi at all), that is strlen(NULL) -> SIGSEGV in Viewer::realize. When OSG asks dlsym for
 * glGetStringi we hand it guarded_glGetStringi instead: it calls the real one, and on NULL for
 * GL_EXTENSIONS falls back to splitting glGetString(GL_EXTENSIONS); past the end it returns "".
 */
#include <stdlib.h>

typedef unsigned int GLenum_;
typedef unsigned int GLuint_;
typedef const unsigned char* (*PFN_getStringi)(GLenum_, GLuint_);
typedef const unsigned char* (*PFN_getString)(GLenum_);

#define GL_EXTENSIONS_ 0x1F03

void* __real_dlsym(void* handle, const char* symbol);

static PFN_getStringi s_realGetStringi;
static PFN_getString s_getString;
static char* s_extBuf;
static char** s_extList;
static unsigned s_extCount;
static int s_fallbackLogged;

static void buildExtensionList(void)
{
    if (s_extList != NULL || s_getString == NULL)
        return;
    const char* all = (const char*)s_getString(GL_EXTENSIONS_);
    if (all == NULL)
        return;
    s_extBuf = strdup(all);
    if (s_extBuf == NULL)
        return;
    unsigned cap = 16;
    s_extList = (char**)malloc(cap * sizeof(char*));
    if (s_extList == NULL)
        return;
    for (char* tok = strtok(s_extBuf, " "); tok != NULL; tok = strtok(NULL, " "))
    {
        if (s_extCount == cap)
        {
            char** grown = (char**)realloc(s_extList, (cap *= 2) * sizeof(char*));
            if (grown == NULL)
                break;
            s_extList = grown;
        }
        s_extList[s_extCount++] = tok;
    }
}

static const unsigned char* guarded_glGetStringi(GLenum_ name, GLuint_ index)
{
    const unsigned char* r = s_realGetStringi != NULL ? s_realGetStringi(name, index) : NULL;
    if (r != NULL)
        return r;
    if (name != GL_EXTENSIONS_)
        return (const unsigned char*)"";
    if (!s_fallbackLogged)
    {
        s_fallbackLogged = 1;
        __android_log_print(ANDROID_LOG_WARN, "idle-openmw",
            "glGetStringi(GL_EXTENSIONS, %u) returned NULL -> falling back to glGetString(GL_EXTENSIONS) split",
            index);
    }
    buildExtensionList();
    if (s_extList != NULL && index < s_extCount)
        return (const unsigned char*)s_extList[index];
    return (const unsigned char*)"";
}


/*
 * Soft guard for glLinkProgram (-Wl,--wrap=glLinkProgram, plus OSG's dlsym("glLinkProgram")).
 *
 * When a shader failed to compile under gl4es, gl4es's glLinkProgram dereferences the NULL converted
 * source (strchr(NULL) -> SIGSEGV in Renderer::compile). If any attached shader has
 * GL_COMPILE_STATUS == GL_FALSE we skip the real link and log, so the failure is a visible error
 * (program stays unlinked; OSG reports it) instead of a crash.
 */
typedef void (*PFN_linkProgram)(GLuint_);
typedef void (*PFN_getAttachedShaders)(GLuint_, int, int*, GLuint_*);
typedef void (*PFN_getShaderiv)(GLuint_, GLenum_, int*);
typedef void (*PFN_getShaderInfoLog)(GLuint_, int, int*, char*);

#define GL_COMPILE_STATUS_ 0x8B81

extern void glLinkProgram(GLuint_ program);
extern void glGetAttachedShaders(GLuint_, int, int*, GLuint_*);
extern void glGetShaderiv(GLuint_, GLenum_, int*);
extern void glGetShaderInfoLog(GLuint_, int, int*, char*);
void __real_glLinkProgram(GLuint_ program);

static PFN_linkProgram s_realLinkFromDlsym;
static unsigned s_skippedLinks;

static int anyShaderFailed(GLuint_ program)
{
    GLuint_ shaders[16];
    int count = 0;
    glGetAttachedShaders(program, 16, &count, shaders);
    int failed = 0;
    for (int i = 0; i < count && i < 16; ++i)
    {
        int ok = 1;
        glGetShaderiv(shaders[i], GL_COMPILE_STATUS_, &ok);
        if (!ok)
        {
            char log[512];
            int len = 0;
            log[0] = 0;
            glGetShaderInfoLog(shaders[i], sizeof(log), &len, log);
            __android_log_print(ANDROID_LOG_ERROR, "idle-openmw",
                "program %u: shader %u failed to compile: %s", program, shaders[i], log);
            failed = 1;
        }
    }
    return failed;
}

static void guardedLink(GLuint_ program, PFN_linkProgram real)
{
    if (anyShaderFailed(program))
    {
        ++s_skippedLinks;
        __android_log_print(ANDROID_LOG_ERROR, "idle-openmw",
            "glLinkProgram(%u) SKIPPED: an attached shader failed to compile (skipped %u so far)",
            program, s_skippedLinks);
        return;
    }
    real(program);
}

void __wrap_glLinkProgram(GLuint_ program)
{
    guardedLink(program, __real_glLinkProgram);
}

static void guarded_glLinkProgram_dlsym(GLuint_ program)
{
    guardedLink(program, s_realLinkFromDlsym != NULL ? s_realLinkFromDlsym : __real_glLinkProgram);
}

void* __wrap_dlsym(void* handle, const char* symbol)
{
    void* real = __real_dlsym(handle, symbol);
    if (symbol != NULL && strcmp(symbol, "glGetStringi") == 0)
    {
        if (s_realGetStringi == NULL)
            s_realGetStringi = (PFN_getStringi)real;
        if (s_getString == NULL)
            s_getString = (PFN_getString)__real_dlsym(handle, "glGetString");
        __android_log_print(ANDROID_LOG_INFO, "idle-openmw",
            "dlsym(glGetStringi) -> null-guarded wrapper (real=%p)", real);
        return (void*)guarded_glGetStringi;
    }
    if (symbol != NULL && real != NULL && (strcmp(symbol, "glLinkProgram") == 0 || strcmp(symbol, "glLinkProgramARB") == 0))
    {
        if (s_realLinkFromDlsym == NULL)
            s_realLinkFromDlsym = (PFN_linkProgram)real;
        __android_log_print(ANDROID_LOG_INFO, "idle-openmw", "dlsym(%s) -> compile-status-guarded wrapper", symbol);
        return (void*)guarded_glLinkProgram_dlsym;
    }
    return real;
}
