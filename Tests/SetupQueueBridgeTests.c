#define httpConnect2 setup_test_connect
#define httpSetTimeout setup_test_timeout
#define httpClose setup_test_close
#define cupsDoRequest setup_test_request
#include "../Sources/native-driver/NativeBridge.c"
#include <assert.h>
static int mode, connections, requests, closes;
http_t *setup_test_connect(const char *host, int port, http_addrlist_t *addresses, int family,
                          http_encryption_t encryption, int blocking, int msec, int *cancel) {
    assert(!strcmp(host, "/private/var/run/cupsd") && port == 631 && !addresses && family == AF_UNSPEC);
    assert(encryption == HTTP_ENCRYPTION_IF_REQUESTED && blocking && msec == 2000 && !cancel);
    ++connections;
    return mode == 1 ? NULL : (http_t *)1;
}
void setup_test_timeout(http_t *http, double timeout, http_timeout_cb_t callback, void *data) {
    assert(http == (http_t *)1 && timeout == 2.0 && !callback && !data);
}
void setup_test_close(http_t *http) { assert(http == (http_t *)1); ++closes; }
ipp_t *setup_test_request(http_t *http, ipp_t *request, const char *resource) {
    assert(http == (http_t *)1 && !strcmp(resource, "/printers/Evolis_Avansia"));
    assert(ippGetOperation(request) == IPP_OP_GET_PRINTER_ATTRIBUTES);
    ipp_attribute_t *printer = ippFindAttribute(request, "printer-uri", IPP_TAG_URI);
    ipp_attribute_t *requested = ippFindAttribute(request, "requested-attributes", IPP_TAG_KEYWORD);
    assert(printer && !strcmp(ippGetString(printer, 0, NULL), "ipp://localhost:631/printers/Evolis_Avansia"));
    assert(requested && ippGetCount(requested) == 2 && !strcmp(ippGetString(requested, 0, NULL), "printer-name") && !strcmp(ippGetString(requested, 1, NULL), "device-uri"));
    ++requests;
    ippDelete(request);
    if (mode == 2) return NULL;
    ipp_t *response = ippNew();
    ippSetStatusCode(response, mode == 3 ? IPP_STATUS_ERROR_NOT_FOUND : mode == 4 ? IPP_STATUS_ERROR_NOT_AUTHORIZED : IPP_STATUS_OK);
    if (mode != 10) ippAddString(response, IPP_TAG_PRINTER, mode == 14 ? IPP_TAG_TEXT : IPP_TAG_NAME,
        "printer-name", NULL, mode == 11 ? "Other_Printer" : mode == 15 ? "" : "Evolis_Avansia");
    if (mode == 13) ippAddString(response, IPP_TAG_PRINTER, IPP_TAG_NAME, "printer-name", NULL, "Evolis_Avansia");
    if (mode < 3 || mode >= 6) {
        if (mode == 7) {
            const char *values[] = {"ipp://localhost:18631/ipp/print", "ipp://other.invalid/ipp/print"};
            ippAddStrings(response, IPP_TAG_PRINTER, IPP_TAG_URI, "device-uri", 2, NULL, values);
        } else {
            ippAddString(response, IPP_TAG_PRINTER, mode == 6 ? IPP_TAG_TEXT : IPP_TAG_URI, "device-uri", NULL,
                         mode == 8 ? "" : mode == 9 ? "ipp://other.invalid/ipp/print" : "ipp://localhost:18631/ipp/print");
        }
    }
    if (mode == 12) ippAddString(response, IPP_TAG_PRINTER, IPP_TAG_URI, "device-uri", NULL, "ipp://localhost:18631/ipp/print");
    return response;
}
int main(void) {
    char uri[4096], error[256];
    for (mode = 0; mode <= 15; ++mode) {
        connections = requests = closes = 0;
        memset(uri, 'x', sizeof(uri));
        int result = avansia_queue_uri("Evolis_Avansia", uri, sizeof(uri), error, sizeof(error));
        assert(result == (mode == 0 || mode == 9 ? 1 : mode == 3 ? 0 : -1));
        assert(connections == 1 && requests == (mode == 1 ? 0 : 1) && closes == (mode == 1 ? 0 : 1));
        if (result == 1) assert(!strcmp(uri, mode == 9 ? "ipp://other.invalid/ipp/print" : "ipp://localhost:18631/ipp/print"));
        else assert(uri[0] == '\0');
    }
    mode = 0;
    assert(avansia_queue_uri("Evolis_Avansia", uri, 2, error, sizeof(error)) == -1);
    assert(uri[0] == '\0');
    puts("PASS: Native queue identity uses only bounded local Unix-socket Get-Printer-Attributes; exact/foreign URI, explicit not-found, connection/transport/auth errors, missing/duplicate/wrong-type/multiple/empty attributes and exact printer-name and buffer truncation remain distinct");
    return 0;
}
