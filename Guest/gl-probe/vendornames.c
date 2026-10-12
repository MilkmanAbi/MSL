#include <xcb/glx.h>
#include <stdio.h>
int main(void){ xcb_connection_t *c = xcb_connect(NULL, NULL);
  xcb_glx_query_server_string_reply_t *r = xcb_glx_query_server_string_reply(c, xcb_glx_query_server_string(c, 0, 0x20F6), NULL);
  if (!r) { printf("no reply\n"); return 1; }
  printf("vendor names: %.*s\n", xcb_glx_query_server_string_string_length(r), xcb_glx_query_server_string_string(r)); return 0; }
