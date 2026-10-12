#!/usr/bin/env python3
"""glinfo.py [gl|gles] - which GL does this guest really get? (EGL surfaceless, no X needed)

    GALLIUM_DRIVER=virpipe LIBGL_ALWAYS_SOFTWARE=1 python3 glinfo.py   # through the Mac GPU
    python3 glinfo.py                                                   # plain Mesa (llvmpipe)
"""
import ctypes, sys
egl = ctypes.CDLL("libEGL.so.1")
egl.eglGetProcAddress.restype = ctypes.c_void_p
egl.eglGetProcAddress.argtypes = [ctypes.c_char_p]
get_platform_display = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_uint, ctypes.c_void_p, ctypes.c_void_p)(
    egl.eglGetProcAddress(b"eglGetPlatformDisplayEXT"))
EGL_PLATFORM_SURFACELESS_MESA = 0x31DD
dpy = get_platform_display(EGL_PLATFORM_SURFACELESS_MESA, None, None)
major, minor = ctypes.c_int(), ctypes.c_int()
egl.eglInitialize.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]
if not egl.eglInitialize(dpy, ctypes.byref(major), ctypes.byref(minor)):
    sys.exit("eglInitialize failed")
api = sys.argv[1] if len(sys.argv) > 1 else "gl"
egl.eglBindAPI(0x30A2 if api == "gl" else 0x30A0)  # EGL_OPENGL_API / EGL_OPENGL_ES_API
attrs = (ctypes.c_int * 3)(*( [0x3098, 3, 0x3038] if api == "gles" else [0x3038, 0, 0]))  # CONTEXT_MAJOR 3 for GLES
egl.eglCreateContext.restype = ctypes.c_void_p
egl.eglCreateContext.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
ctx = egl.eglCreateContext(dpy, None, None, attrs)
if not ctx:
    sys.exit("eglCreateContext failed: 0x%x" % egl.eglGetError())
egl.eglMakeCurrent.argtypes = [ctypes.c_void_p] * 4
if not egl.eglMakeCurrent(dpy, None, None, ctx):
    sys.exit("eglMakeCurrent failed: 0x%x" % egl.eglGetError())
gl_get_string = ctypes.CFUNCTYPE(ctypes.c_char_p, ctypes.c_uint)(egl.eglGetProcAddress(b"glGetString"))
for name, enum in [("vendor", 0x1F00), ("renderer", 0x1F01), ("version", 0x1F02), ("GLSL", 0x8B8C)]:
    print("%-9s %s" % (name, (gl_get_string(enum) or b"?").decode()))

# --- readback check: clear an FBO to a known colour and glReadPixels it back
if "--readback" in sys.argv:
    def fn(name, restype, *args):
        return ctypes.CFUNCTYPE(restype, *args)(egl.eglGetProcAddress(name))
    u = ctypes.c_uint
    genfb = fn(b"glGenFramebuffers", None, ctypes.c_int, ctypes.POINTER(u))
    bindfb = fn(b"glBindFramebuffer", None, u, u)
    genrb = fn(b"glGenRenderbuffers", None, ctypes.c_int, ctypes.POINTER(u))
    bindrb = fn(b"glBindRenderbuffer", None, u, u)
    rbstore = fn(b"glRenderbufferStorage", None, u, u, ctypes.c_int, ctypes.c_int)
    fbrb = fn(b"glFramebufferRenderbuffer", None, u, u, u, u)
    status = fn(b"glCheckFramebufferStatus", u, u)
    clearc = fn(b"glClearColor", None, ctypes.c_float, ctypes.c_float, ctypes.c_float, ctypes.c_float)
    clear = fn(b"glClear", None, u)
    readpx = fn(b"glReadPixels", None, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, u, u, ctypes.c_void_p)
    fb, rb = u(), u()
    genfb(1, ctypes.byref(fb)); bindfb(0x8D40, fb.value)
    genrb(1, ctypes.byref(rb)); bindrb(0x8D41, rb.value)
    rbstore(0x8D41, 0x8058, 64, 64)  # GL_RGBA8
    fbrb(0x8D40, 0x8CE0, 0x8D41, rb.value)
    print("fbo status 0x%x" % status(0x8D40))
    clearc(0.2, 0.4, 0.6, 1.0); clear(0x4000)
    buf = (ctypes.c_ubyte * (64 * 64 * 4))()
    readpx(0, 0, 64, 64, 0x1908, 0x1401, buf)  # RGBA, UNSIGNED_BYTE
    print("pixel (expect ~51,102,153,255):", tuple(buf[0:4]), "centre:", tuple(buf[(32*64+32)*4:(32*64+32)*4+4]))

# --- draw check: one triangle through a real shader, optional depth attachment
if "--draw" in sys.argv:
    def fn(name, restype, *args):
        return ctypes.CFUNCTYPE(restype, *args)(egl.eglGetProcAddress(name))
    u, i, f, vp = ctypes.c_uint, ctypes.c_int, ctypes.c_float, ctypes.c_void_p
    G = {n: fn(n.encode(), r, *a) for n, r, a in [
        ("glGenFramebuffers", None, (i, ctypes.POINTER(u))), ("glBindFramebuffer", None, (u, u)),
        ("glGenRenderbuffers", None, (i, ctypes.POINTER(u))), ("glBindRenderbuffer", None, (u, u)),
        ("glRenderbufferStorage", None, (u, u, i, i)), ("glFramebufferRenderbuffer", None, (u, u, u, u)),
        ("glClearColor", None, (f, f, f, f)), ("glClear", None, (u,)), ("glViewport", None, (i, i, i, i)),
        ("glReadPixels", None, (i, i, i, i, u, u, vp)), ("glCreateShader", u, (u,)),
        ("glShaderSource", None, (u, i, ctypes.POINTER(ctypes.c_char_p), vp)), ("glCompileShader", None, (u,)),
        ("glCreateProgram", u, ()), ("glAttachShader", None, (u, u)), ("glLinkProgram", None, (u,)),
        ("glUseProgram", None, (u,)), ("glGenVertexArrays", None, (i, ctypes.POINTER(u))),
        ("glBindVertexArray", None, (u,)), ("glDrawArrays", None, (u, i, i)), ("glEnable", None, (u,)),
        ("glGetShaderiv", None, (u, u, ctypes.POINTER(i))), ("glGetProgramiv", None, (u, u, ctypes.POINTER(i))),
        ("glFinish", None, ())]}
    depth = "--depth" in sys.argv
    fb, rb, db, vao = u(), u(), u(), u()
    G["glGenFramebuffers"](1, ctypes.byref(fb)); G["glBindFramebuffer"](0x8D40, fb.value)
    G["glGenRenderbuffers"](1, ctypes.byref(rb)); G["glBindRenderbuffer"](0x8D41, rb.value)
    G["glRenderbufferStorage"](0x8D41, 0x8058, 64, 64); G["glFramebufferRenderbuffer"](0x8D40, 0x8CE0, 0x8D41, rb.value)
    if depth:
        G["glGenRenderbuffers"](1, ctypes.byref(db)); G["glBindRenderbuffer"](0x8D41, db.value)
        G["glRenderbufferStorage"](0x8D41, 0x88F0, 64, 64)  # GL_DEPTH24_STENCIL8
        G["glFramebufferRenderbuffer"](0x8D40, 0x821A, 0x8D41, db.value)  # DEPTH_STENCIL_ATTACHMENT
        G["glEnable"](0x0B71)  # GL_DEPTH_TEST
    vs = b"#version 130\nvoid main(){ vec2 p[3]=vec2[3](vec2(-1,-1),vec2(3,-1),vec2(-1,3)); gl_Position=vec4(p[gl_VertexID],0,1);}"
    fs = b"#version 130\nout vec4 c; void main(){ c=vec4(1.0,0.5,0.0,1.0);}"
    prog = G["glCreateProgram"]()
    for kind, src in [(0x8B31, vs), (0x8B30, fs)]:
        sh = G["glCreateShader"](kind); arr = (ctypes.c_char_p * 1)(src)
        G["glShaderSource"](sh, 1, arr, None); G["glCompileShader"](sh)
        ok = i(); G["glGetShaderiv"](sh, 0x8B81, ctypes.byref(ok)); print("shader compiled:", ok.value)
        G["glAttachShader"](prog, sh)
    G["glLinkProgram"](prog); ok = i(); G["glGetProgramiv"](prog, 0x8B82, ctypes.byref(ok)); print("linked:", ok.value)
    G["glGenVertexArrays"](1, ctypes.byref(vao)); G["glBindVertexArray"](vao.value)
    G["glViewport"](0, 0, 64, 64); G["glClearColor"](0, 0, 0, 1); G["glClear"](0x4000 | (0x100 if depth else 0))
    G["glUseProgram"](prog); G["glDrawArrays"](4, 0, 3); G["glFinish"]()
    buf = (ctypes.c_ubyte * (64 * 64 * 4))()
    G["glReadPixels"](0, 0, 64, 64, 0x1908, 0x1401, buf)
    print("draw%s -> centre pixel (expect 255,127,0,255):" % (" +depth" if depth else ""), tuple(buf[(32*64+32)*4:(32*64+32)*4+4]))
