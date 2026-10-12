#!/usr/bin/env python3
"""glsurface.py [W H] - draw into a real EGL pbuffer surface (a window-like backbuffer,
BGRX when no alpha), read it back, print a coarse map. Shows shifts/shears/scatter.
A quad covers the LEFT third and the BOTTOM half (GL y-up): expect '#' there only."""
import ctypes, sys
W = int(sys.argv[1]) if len(sys.argv) > 2 else 300
H = int(sys.argv[2]) if len(sys.argv) > 2 else 300
alpha = 8 if "--alpha" in sys.argv else 0
egl = ctypes.CDLL("libEGL.so.1")
egl.eglGetProcAddress.restype = ctypes.c_void_p; egl.eglGetProcAddress.argtypes = [ctypes.c_char_p]
P = lambda n, r, *a: ctypes.CFUNCTYPE(r, *a)(egl.eglGetProcAddress(n))
vp, i, u, f = ctypes.c_void_p, ctypes.c_int, ctypes.c_uint, ctypes.c_float
dpy = P(b"eglGetPlatformDisplayEXT", vp, u, vp, vp)(0x31DD, None, None)
egl.eglInitialize.argtypes = [vp, vp, vp]; egl.eglInitialize(dpy, None, None)
egl.eglBindAPI(0x30A2)
DEPTH = 16 if "--depth16" in sys.argv else 0
attrs = (i * 15)(0x3033, 0x0001, 0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, alpha, 0x3040, 0x0008, 0x3025, DEPTH, 0x3038)  # PBUFFER_BIT, RGB(A), OPENGL_BIT
# EGL ranks deeper configs first (10-bit), so pick EXACTLY 8/8/8/alpha: the
# window backbuffer format (B8G8R8X8 without alpha).
cfgs, n = (vp * 64)(), i()
egl.eglChooseConfig.argtypes = [vp, vp, ctypes.POINTER(vp), i, ctypes.POINTER(i)]
egl.eglChooseConfig(dpy, attrs, cfgs, 64, ctypes.byref(n))
egl.eglGetConfigAttrib.argtypes = [vp, vp, i, ctypes.POINTER(i)]
def attr(c, a):
    v = i(); egl.eglGetConfigAttrib(dpy, c, a, ctypes.byref(v)); return v.value
cfg = next((cfgs[k] for k in range(n.value)
            if attr(cfgs[k], 0x3024) == 8 and attr(cfgs[k], 0x3021) == alpha
            and (DEPTH == 0 or attr(cfgs[k], 0x3025) == DEPTH)), None)
if cfg is None: sys.exit("no 8-bit pbuffer config")
cfg = vp(cfg)
egl.eglCreatePbufferSurface.restype = vp; egl.eglCreatePbufferSurface.argtypes = [vp, vp, vp]
surf = egl.eglCreatePbufferSurface(dpy, cfg, (i * 5)(0x3057, W, 0x3056, H, 0x3038))
egl.eglCreateContext.restype = vp; egl.eglCreateContext.argtypes = [vp, vp, vp, vp]
ctx = egl.eglCreateContext(dpy, cfg, None, (i * 1)(0x3038))
egl.eglMakeCurrent.argtypes = [vp] * 4
if not egl.eglMakeCurrent(dpy, surf, surf, ctx): sys.exit("makecurrent failed 0x%x" % egl.eglGetError())
G = lambda n, r, *a: P(n.encode(), r, *a)
gs = G("glGetString", ctypes.c_char_p, u)
print("renderer:", gs(0x1F01).decode(), " surface %dx%d alpha=%d" % (W, H, alpha))
clearc = G("glClearColor", None, f, f, f, f); clear = G("glClear", None, u)
scissor = G("glScissor", None, i, i, i, i); enable = G("glEnable", None, u); disable = G("glDisable", None, u)
read = G("glReadPixels", None, i, i, i, i, u, u, vp); finish = G("glFinish", None)
clearc(0, 0, 0, 1); clear(0x4000)
if "--tri" in sys.argv:
    cs = G("glCreateShader", u, u); src = G("glShaderSource", None, u, i, ctypes.POINTER(ctypes.c_char_p), vp)
    comp = G("glCompileShader", None, u); cp = G("glCreateProgram", u); att = G("glAttachShader", None, u, u)
    link = G("glLinkProgram", None, u); use = G("glUseProgram", None, u); draw = G("glDrawArrays", None, u, i, i)
    gva = G("glGenVertexArrays", None, i, ctypes.POINTER(u)); bva = G("glBindVertexArray", None, u)
    prog = cp()
    vbo = "--vbo" in sys.argv
    vsrc = (b"#version 130\nin vec3 pos; in vec3 nrm; out vec4 col; void main(){ col=vec4(1.0,0.5,0.0,1.0)*max(nrm.z,1.0); gl_Position=vec4(pos,1);}"
            if vbo else (b"#version 130\nout vec4 col; void main(){ vec2 p[3]=vec2[3](vec2(-1,-1),vec2(3,-1),vec2(-1,3)); col=vec4(1.0,0.5,0.0,1.0); gl_Position=vec4(p[gl_VertexID],0,1);}"
            if "--varying" in sys.argv else b"#version 130\nvoid main(){ vec2 p[3]=vec2[3](vec2(-1,-1),vec2(3,-1),vec2(-1,3)); gl_Position=vec4(p[gl_VertexID],0,1);}"))
    fsrc = (b"#version 130\nin vec4 col; out vec4 c; void main(){ c=col;}" if (vbo or "--varying" in sys.argv)
            else b"#version 130\nout vec4 c; void main(){ c=vec4(1.0,0.5,0.0,1.0);}")
    for kind, code in [(0x8B31, vsrc), (0x8B30, fsrc)]:
        sh = cs(kind); src(sh, 1, (ctypes.c_char_p * 1)(code), None); comp(sh); att(prog, sh)
    if vbo:
        G("glBindAttribLocation", None, u, u, ctypes.c_char_p)(prog, 0, b"pos")
        G("glBindAttribLocation", None, u, u, ctypes.c_char_p)(prog, 1, b"nrm")
    link(prog); use(prog); va = u(); gva(1, ctypes.byref(va)); bva(va.value)
    if vbo:  # es2gears-style: interleaved float xyz + normal xyz, stride 24, a triangle strip
        verts = (ctypes.c_float * 24)(-1,-1,0, 0,0,1,  1,-1,0, 0,0,1,  -1,1,0, 0,0,1,  1,1,0, 0,0,1)
        b = u(); G("glGenBuffers", None, i, ctypes.POINTER(u))(1, ctypes.byref(b))
        G("glBindBuffer", None, u, u)(0x8892, b.value)
        G("glBufferData", None, u, ctypes.c_ssize_t, vp, u)(0x8892, ctypes.sizeof(verts), verts, 0x88E4)
        ptr = G("glVertexAttribPointer", None, u, i, u, ctypes.c_ubyte, i, vp)
        ptr(0, 3, 0x1406, 0, 24, None); ptr(1, 3, 0x1406, 0, 24, ctypes.c_void_p(12))
        G("glEnableVertexAttribArray", None, u)(0); G("glEnableVertexAttribArray", None, u)(1)
    if DEPTH:
        enable(0x0B71); clear(0x0100)  # DEPTH_TEST, clear depth
    if "--cull" in sys.argv:
        enable(0x0B44)  # CULL_FACE
    G("glViewport", None, i, i, i, i)(0, 0, W, H)
    if "--half" in sys.argv:
        enable(0x0C11); scissor(0, 0, W // 3, H // 2)
    if vbo and "--tris" in sys.argv:
        draw(4, 0, 3)  # plain triangles from the same buffer
    else:
        draw(5, 0, 4) if vbo else draw(4, 0, 3)
elif "--full" in sys.argv:
    clearc(1, 0.5, 0, 1); clear(0x4000)
else:
    enable(0x0C11); scissor(0, 0, W // 3, H // 2); clearc(1, 0.5, 0, 1); clear(0x4000); disable(0x0C11)  # scissored clear = "draw"
finish()
buf = (ctypes.c_ubyte * (W * H * 4))()
read(0, 0, W, H, 0x1908, 0x1401, buf)
print("raw first/centre/last pixel:", tuple(buf[0:4]), tuple(buf[(H//2*W+W//2)*4:(H//2*W+W//2)*4+4]), tuple(buf[-4:]))
lit = sum(1 for k in range(0, W * H * 4, 4) if buf[k] > 128)
print("lit pixels: %d (expect %d)" % (lit, (W // 3) * (H // 2)))
for row in range(H - 1, -1, -H // 12):
    print("".join("#" if buf[(row * W + x) * 4] > 128 else "." for x in range(0, W, max(1, W // 40))))
