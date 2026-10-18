#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <libusb.h>

int main(int argc, char **argv)
{
    typedef int (LIBUSB_CALL *initialize_fn)(libusb_context **);
    typedef void (LIBUSB_CALL *finish_fn)(libusb_context *);
    libusb_context *context = NULL;
    void *library;
    initialize_fn initialize;
    finish_fn finish;
    int result;

    if (argc != 2) {
        fputs("Usage: libusb-initialization-test library-path\n", stderr);
        return 2;
    }
    unsetenv("LIBUSB_DEBUG");
    library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        fputs("Cannot load the built libusb dependency.\n", stderr);
        return 1;
    }
    initialize = (initialize_fn)dlsym(library, "libusb_init");
    finish = (finish_fn)dlsym(library, "libusb_exit");
    if (!initialize || !finish) {
        fputs("The libusb initialization API is unavailable.\n", stderr);
        dlclose(library);
        return 1;
    }
    result = initialize(&context);
    if (result != LIBUSB_SUCCESS || !context) {
        fprintf(stderr, "libusb initialization failed (status %d).\n", result);
        dlclose(library);
        return 1;
    }
    finish(context);
    if (dlclose(library)) {
        fputs("Cannot unload the tested libusb dependency.\n", stderr);
        return 1;
    }
    puts("PASS: built libusb loaded, initialized, exited and unloaded.");
    return 0;
}
