#define GL_GLEXT_PROTOTYPES
#include <GL/glx.h>
#include <GL/glxext.h>
#include <stdio.h>
#include <string.h>
static int fails = 0;
#define CHECK(c, msg) do { if (!(c)) { printf("FAIL: %s\n", msg); fails++; } else printf("ok: %s\n", msg); } while (0)
int main(void) {
    Display *d = XOpenDisplay(NULL);
    if (!d) { printf("FAIL: no display\n"); return 1; }
    int s = DefaultScreen(d);
    printf("server vendor: %s\n", glXQueryServerString(d, s, GLX_VENDOR));
    const char *ext = glXQueryExtensionsString(d, s);
    CHECK(strstr(ext, "GLX_EXT_texture_from_pixmap"), "TFP advertised to app");
    CHECK(strstr(ext, "GLX_SGIX_pbuffer"), "SGIX_pbuffer advertised to app");
    /* 1. classic glXChooseVisual path: single buffer, no depth */
    int single[] = { GLX_RGBA, GLX_RED_SIZE, 8, None };
    XVisualInfo *vi = glXChooseVisual(d, s, single);
    CHECK(vi != NULL, "glXChooseVisual single-buffered");
    if (vi) {
        int db = -1, depth = -1; glXGetConfig(d, vi, GLX_DOUBLEBUFFER, &db); glXGetConfig(d, vi, GLX_DEPTH_SIZE, &depth);
        printf("   visual 0x%lx db=%d depth=%d\n", vi->visualid, db, depth);
        CHECK(db == 0, "single-buffered visual really is single-buffered");
        GLXContext c = glXCreateContext(d, vi, NULL, True);
        Window w = XCreateWindow(d, RootWindow(d, s), 0, 0, 64, 64, 0, vi->depth, InputOutput, vi->visual,
                                 CWColormap, &(XSetWindowAttributes){ .colormap = XCreateColormap(d, RootWindow(d, s), vi->visual, AllocNone) });
        XMapWindow(d, w); XSync(d, False);
        CHECK(c && glXMakeCurrent(d, w, c), "make current on single-buffered window");
        glClearColor(1, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT); glFinish();
        unsigned char px[4] = {0}; glReadPixels(1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
        CHECK(px[0] == 255 && px[1] == 0, "single-buffered clear reads back red");
        XWindowAttributes wa; XGetWindowAttributes(d, w, &wa);
        CHECK(wa.visual->visualid == vi->visualid, "window reports the visual it was created with");
        glXMakeCurrent(d, None, NULL); glXDestroyContext(d, c); XDestroyWindow(d, w);
    }
    /* 2. double buffer with alpha on a depth-24 visual */
    int alpha[] = { GLX_RGBA, GLX_DOUBLEBUFFER, GLX_ALPHA_SIZE, 8, GLX_DEPTH_SIZE, 24, None };
    vi = glXChooseVisual(d, s, alpha);
    CHECK(vi != NULL, "glXChooseVisual RGBA8 + depth24 + double");
    if (vi) { int a = -1; glXGetConfig(d, vi, GLX_ALPHA_SIZE, &a); printf("   visual 0x%lx depth=%d alpha=%d\n", vi->visualid, vi->depth, a); CHECK(a == 8, "alpha buffer present"); }
    /* 3. fbconfig count */
    int n = 0; GLXFBConfig *cfgs = glXGetFBConfigs(d, s, &n);
    printf("   fbconfigs: %d\n", n); CHECK(n >= 24, "all 24 configs survive driver matching");
    /* 4. SGIX pbuffer via vendor private */
    PFNGLXCREATEGLXPBUFFERSGIXPROC createPB = (void *)glXGetProcAddress((const GLubyte *)"glXCreateGLXPbufferSGIX");
    PFNGLXCREATECONTEXTWITHCONFIGSGIXPROC createCtx = (void *)glXGetProcAddress((const GLubyte *)"glXCreateContextWithConfigSGIX");
    if (createPB && createCtx && n) {
        GLXPbufferSGIX pb = createPB(d, (GLXFBConfigSGIX)cfgs[0], 32, 32, NULL);
        GLXContext c = createCtx(d, (GLXFBConfigSGIX)cfgs[0], GLX_RGBA_TYPE, NULL, True);
        XSync(d, False);
        CHECK(pb && c && glXMakeCurrent(d, pb, c), "SGIX pbuffer + context-with-config");
        glXMakeCurrent(d, None, NULL);
    } else CHECK(0, "SGIX entry points");
    /* 5. GLX 1.3 pbuffer + query drawable */
    int pba[] = { GLX_PBUFFER_WIDTH, 40, GLX_PBUFFER_HEIGHT, 30, None };
    GLXPbuffer pb = glXCreatePbuffer(d, cfgs[0], pba);
    unsigned int wv = 0, hv = 0; glXQueryDrawable(d, pb, GLX_WIDTH, &wv); glXQueryDrawable(d, pb, GLX_HEIGHT, &hv);
    printf("   pbuffer %ux%u\n", wv, hv); CHECK(wv == 40 && hv == 30, "glXQueryDrawable pbuffer size");
    /* 6. texture from pixmap */
    PFNGLXBINDTEXIMAGEEXTPROC bind = (void *)glXGetProcAddress((const GLubyte *)"glXBindTexImageEXT");
    int tfpAttr[] = { GLX_BIND_TO_TEXTURE_RGBA_EXT, True, GLX_DRAWABLE_TYPE, GLX_PIXMAP_BIT, None };
    int tn = 0; GLXFBConfig *tcfg = glXChooseFBConfig(d, s, tfpAttr, &tn);
    CHECK(tn > 0, "fbconfig with BIND_TO_TEXTURE_RGBA");
    if (tn > 0 && bind) {
        XVisualInfo *tv = glXGetVisualFromFBConfig(d, tcfg[0]);
        Pixmap xp = XCreatePixmap(d, RootWindow(d, s), 16, 16, tv ? tv->depth : 24);
        int pattr[] = { GLX_TEXTURE_TARGET_EXT, GLX_TEXTURE_2D_EXT, GLX_TEXTURE_FORMAT_EXT, GLX_TEXTURE_FORMAT_RGBA_EXT, None };
        GLXPixmap gp = glXCreatePixmap(d, tcfg[0], xp, pattr);
        GLXContext c = glXCreateNewContext(d, cfgs[0], GLX_RGBA_TYPE, NULL, True);
        glXMakeCurrent(d, pb, c);
        GLuint tex; glGenTextures(1, &tex); glBindTexture(GL_TEXTURE_2D, tex);
        bind(d, gp, GLX_FRONT_LEFT_EXT, NULL); XSync(d, False);
        CHECK(glGetError() == GL_NO_ERROR, "glXBindTexImageEXT binds without GL error");
        unsigned int target = 0; glXQueryDrawable(d, gp, GLX_TEXTURE_TARGET_EXT, &target);
        CHECK(target == GLX_TEXTURE_2D_EXT, "TFP pixmap reports its texture target");
    }
    /* 7. glvnd vendor */
    const char *vn = glXQueryServerString(d, s, 0x20F6);
    printf("   GLX_VENDOR_NAMES_EXT: %s\n", vn ? vn : "(null)"); CHECK(vn && !strcmp(vn, "mesa"), "libglvnd vendor name");
    printf("RESULT: %d failures\n", fails);
    return fails != 0;
}
