/* Layer 0: the RENDER extension - RenderFillRectangles, RenderComposite
 * with a solid-fill source, RenderComposite with a pixmap-backed image
 * source, and RenderComposite through a pixmap-backed alpha mask - checks
 * mslgd's handleRenderFillRectangles/handleRenderCreatePicture/
 * handleRenderComposite/handleRenderCreateSolidFill directly, isolated
 * from cairo's own RENDER usage patterns.
 *
 * Black backdrops precede every translucent composite so the expected
 * blended color is exact (source-over against a zero destination is just
 * the (premultiplied) source contribution - no fractional rounding to
 * account for), same trick as 03_pixmap_putimage.c's alpha test.
 */
#include <X11/Xlib.h>
#include <X11/extensions/Xrender.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(void) {
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "XOpenDisplay failed\n"); return 1; }

    int screen = DefaultScreen(dpy);
    Window root = RootWindow(dpy, screen);
    Window win = XCreateSimpleWindow(dpy, root, 0, 0, 200, 150, 0,
                                      BlackPixel(dpy, screen), WhitePixel(dpy, screen));
    XSelectInput(dpy, win, ExposureMask);
    XMapWindow(dpy, win);

    XEvent ev;
    do { XNextEvent(dpy, &ev); } while (ev.type != Expose);

    GC gc = XCreateGC(dpy, win, 0, NULL);
    XSetForeground(dpy, gc, 0x00FFFFFF);
    XFillRectangle(dpy, win, gc, 0, 0, 200, 150);

    XRenderPictFormat *fmt24 = XRenderFindStandardFormat(dpy, PictStandardRGB24);
    XRenderPictFormat *fmtARGB = XRenderFindStandardFormat(dpy, PictStandardARGB32);
    Picture winPic = XRenderCreatePicture(dpy, win, fmt24, 0, NULL);

    /* --- Part A: RenderFillRectangles (PictOpSrc), solid blue. --- */
    XRenderColor blue = { 0x0000, 0x0000, 0xFFFF, 0xFFFF };
    XRectangle rectA = { 10, 10, 60, 40 };
    XRenderFillRectangles(dpy, PictOpSrc, winPic, &blue, &rectA, 1);

    /* --- Part B: RenderComposite, solid translucent red source, over a
     * known black backdrop. alpha=128/255, expect exact (128,0,0). --- */
    XSetForeground(dpy, gc, 0x00000000);
    XFillRectangle(dpy, win, gc, 80, 10, 60, 40);
    XRenderColor red = { 0xFFFF, 0x0000, 0x0000, 0x8080 }; /* alpha ~128/255 */
    Picture redSrc = XRenderCreateSolidFill(dpy, &red);
    XRenderComposite(dpy, PictOpOver, redSrc, None, winPic, 0, 0, 0, 0, 80, 10, 60, 40);
    XRenderFreePicture(dpy, redSrc);

    /* --- Part C: RenderComposite, pixmap-backed image source (PictOpSrc,
     * no mask) - opaque orange, plain image compositing. --- */
    const int pw = 60, ph = 40;
    Pixmap imgPm = XCreatePixmap(dpy, win, pw, ph, 24);
    GC pmGC = XCreateGC(dpy, imgPm, 0, NULL);
    XSetForeground(dpy, pmGC, 0x00FF7F00); /* orange */
    XFillRectangle(dpy, imgPm, pmGC, 0, 0, pw, ph);
    Picture imgSrc = XRenderCreatePicture(dpy, imgPm, fmt24, 0, NULL);
    XRenderComposite(dpy, PictOpSrc, imgSrc, None, winPic, 0, 0, 0, 0, 10, 60, pw, ph);
    XRenderFreePicture(dpy, imgSrc);
    XFreeGC(dpy, pmGC);
    XFreePixmap(dpy, imgPm);

    /* --- Part D: RenderComposite through a pixmap-backed alpha mask -
     * opaque green source, uniform alpha=128/255 mask, over a black
     * backdrop. Expect exact (0,128,0). --- */
    XSetForeground(dpy, gc, 0x00000000);
    XFillRectangle(dpy, win, gc, 80, 60, pw, ph);

    Pixmap maskPm = XCreatePixmap(dpy, win, pw, ph, 32);
    unsigned char *maskBuf = malloc((size_t)pw * ph * 4);
    for (int i = 0; i < pw * ph; i++) {
        unsigned char *px = maskBuf + i * 4;
        px[0] = 128; px[1] = 128; px[2] = 128; px[3] = 128; /* premultiplied gray @ alpha=128 */
    }
    XImage *maskImg = XCreateImage(dpy, DefaultVisual(dpy, screen), 32, ZPixmap, 0,
                                    (char *)maskBuf, pw, ph, 32, pw * 4);
    XPutImage(dpy, maskPm, gc, maskImg, 0, 0, 0, 0, pw, ph);
    XDestroyImage(maskImg); /* also frees maskBuf */

    Picture maskPic = XRenderCreatePicture(dpy, maskPm, fmtARGB, 0, NULL);
    XRenderColor green = { 0x0000, 0xFFFF, 0x0000, 0xFFFF };
    Picture greenSrc = XRenderCreateSolidFill(dpy, &green);
    XRenderComposite(dpy, PictOpOver, greenSrc, maskPic, winPic, 0, 0, 0, 0, 80, 60, pw, ph);
    XRenderFreePicture(dpy, greenSrc);
    XRenderFreePicture(dpy, maskPic);
    XFreePixmap(dpy, maskPm);

    XRenderFreePicture(dpy, winPic);
    XFlush(dpy);
    usleep(300 * 1000);

    XFreeGC(dpy, gc);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    return 0;
}
