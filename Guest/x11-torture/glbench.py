#!/usr/bin/env python3
"""glbench.py [SIZE] [ITERS] [--heavy N] - separates GPU work from round trips.

Renders a fragment-heavy shader into an offscreen FBO and times it two ways:

  render   glFinish after every frame, no pixels read back. This is what the
           renderer actually costs.
  readback render + glReadPixels of the whole buffer, which is what the
           present path costs today - the frame comes back over the socket
           to the guest, which then pushes it to the Mac again through X11.

Run it under llvmpipe and under virpipe and compare the two columns: if
`render` is much faster on the GPU while `readback` is not, the round trip
is the thing to fix, not the renderer.

    python3 glbench.py 1024 30 --heavy 200
    GALLIUM_DRIVER=virpipe LIBGL_ALWAYS_SOFTWARE=1 python3 glbench.py 1024 30 --heavy 200
"""
import ctypes, sys, time

SIZE = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 512
ITERS = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 20
HEAVY = int(sys.argv[sys.argv.index("--heavy") + 1]) if "--heavy" in sys.argv else 100

egl = ctypes.CDLL("libEGL.so.1")
egl.eglGetProcAddress.restype = ctypes.c_void_p
egl.eglGetProcAddress.argtypes = [ctypes.c_char_p]
vp, i, u, f = ctypes.c_void_p, ctypes.c_int, ctypes.c_uint, ctypes.c_float
P = lambda n, r, *a: ctypes.CFUNCTYPE(r, *a)(egl.eglGetProcAddress(n))

dpy = P(b"eglGetPlatformDisplayEXT", vp, u, vp, vp)(0x31DD, None, None)  # SURFACELESS
egl.eglInitialize.argtypes = [vp, vp, vp]
egl.eglInitialize(dpy, None, None)
egl.eglBindAPI(0x30A2)  # OPENGL
egl.eglCreateContext.restype = vp
egl.eglCreateContext.argtypes = [vp, vp, vp, vp]
ctx = egl.eglCreateContext(dpy, None, None, (i * 1)(0x3038))
egl.eglMakeCurrent.argtypes = [vp] * 4
if not egl.eglMakeCurrent(dpy, None, None, ctx):
    sys.exit("eglMakeCurrent failed 0x%x" % egl.eglGetError())

G = lambda n, r, *a: P(n.encode(), r, *a)
gs = G("glGetString", ctypes.c_char_p, u)
print("renderer: %s   %dx%d, %d iters, %d shader loops"
      % (gs(0x1F01).decode(), SIZE, SIZE, ITERS, HEAVY))

fb, tex = u(), u()
G("glGenFramebuffers", None, i, ctypes.POINTER(u))(1, ctypes.byref(fb))
G("glBindFramebuffer", None, u, u)(0x8D40, fb.value)
G("glGenTextures", None, i, ctypes.POINTER(u))(1, ctypes.byref(tex))
G("glBindTexture", None, u, u)(0x0DE1, tex.value)
G("glTexImage2D", None, u, i, i, i, i, i, u, u, vp)(0x0DE1, 0, 0x8058, SIZE, SIZE, 0, 0x1908, 0x1401, None)
G("glFramebufferTexture2D", None, u, u, u, u, i)(0x8D40, 0x8CE0, 0x0DE1, tex.value, 0)

# A shader with a real per-pixel cost, so this measures shading rather than
# how fast each side can clear a buffer.
vs = b"#version 130\nvoid main(){ vec2 p[3]=vec2[3](vec2(-1,-1),vec2(3,-1),vec2(-1,3)); gl_Position=vec4(p[gl_VertexID],0,1);}"
fs = ("""#version 130
out vec4 c;
uniform int loops;
void main(){
  vec2 z = gl_FragCoord.xy * 0.01;
  float a = 0.0;
  for (int k = 0; k < loops; k++) { z = vec2(z.x*z.x - z.y*z.y, 2.0*z.x*z.y) * 0.99 + 0.01; a += sin(z.x) * cos(z.y); }
  c = vec4(fract(a), fract(a * 0.5), fract(a * 0.25), 1.0);
}""").encode()
prog = G("glCreateProgram", u)()
for kind, src in [(0x8B31, vs), (0x8B30, fs)]:
    sh = G("glCreateShader", u, u)(kind)
    G("glShaderSource", None, u, i, ctypes.POINTER(ctypes.c_char_p), vp)(sh, 1, (ctypes.c_char_p * 1)(src), None)
    G("glCompileShader", None, u)(sh)
    ok = i(); G("glGetShaderiv", None, u, u, ctypes.POINTER(i))(sh, 0x8B81, ctypes.byref(ok))
    if not ok.value: sys.exit("shader failed to compile")
    G("glAttachShader", None, u, u)(prog, sh)
G("glLinkProgram", None, u)(prog)
G("glUseProgram", None, u)(prog)
G("glUniform1i", None, i, i)(G("glGetUniformLocation", i, u, ctypes.c_char_p)(prog, b"loops"), HEAVY)
vao = u(); G("glGenVertexArrays", None, i, ctypes.POINTER(u))(1, ctypes.byref(vao))
G("glBindVertexArray", None, u)(vao.value)
G("glViewport", None, i, i, i, i)(0, 0, SIZE, SIZE)

draw = G("glDrawArrays", None, u, i, i)
finish = G("glFinish", None)
read = G("glReadPixels", None, i, i, i, i, u, u, vp)
buf = (ctypes.c_ubyte * (SIZE * SIZE * 4))()

def timed(label, readback):
    draw(4, 0, 3); finish()                       # warm up, off the clock
    start = time.monotonic()
    for _ in range(ITERS):
        draw(4, 0, 3)
        if readback: read(0, 0, SIZE, SIZE, 0x1908, 0x1401, buf)
        finish()
    ms = (time.monotonic() - start) * 1000 / ITERS
    print("  %-9s %7.1f ms/frame   %5.1f fps" % (label, ms, 1000 / ms if ms else 0))
    return ms

render = timed("render", False)
readback = timed("readback", True)
print("  round trip costs %.1f ms/frame (%.0f%% of the readback total)"
      % (readback - render, 100 * (readback - render) / readback if readback else 0))
