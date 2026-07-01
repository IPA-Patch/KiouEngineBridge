#import "Internal.h"
#import "Settings/Persistence.h"
#import <dlfcn.h>

// ===========================================================================
// Hook_GrpcLogging — log every outbound gRPC HTTP/2 request and its reply.
//
// KIOU uses Grpc.Net.Client (Grpc.Net.Client.dll) which runs over Mono's
// System.Net.Http.HttpClient → MonoWebRequestHandler stack.  Every gRPC
// unary / streaming call eventually passes through
//
//   HttpClient.SendAsyncWorker.MoveNext   RVA: 0x607C994
//
// When the state machine completes (state == -2) we have both the request
// and the response available in the struct:
//
//   HttpClient.<SendAsyncWorker>d__47 (dump.cs line 1540579):
//     0x00  int32   <>1__state
//     0x08  ptr     <>t__builder (AsyncTaskMethodBuilder<HttpResponseMessage>)
//     0x20  ptr     <>4__this    (HttpClient)
//     0x28  ptr     cancellationToken
//     0x30  ptr     request      (HttpRequestMessage)
//     0x40  ptr     <lcts>5__2   (CancellationTokenSource)
//     0x48  ptr     <response>5__3 (HttpResponseMessage)
//
// HttpRequestMessage (dump.cs line 1540968):
//     0x10  ptr     headers
//     0x18  ptr     method   (HttpMethod)
//     0x20  ptr     version
//     0x28  ptr     properties
//     0x30  ptr     uri      (Uri)
//     0x40  ptr     Content  (HttpContent)
//
// HttpMethod (dump.cs line 1540877):
//     0x10  string  method   (il2cpp string: "POST" etc.)
//
// Uri (dump.cs line 743580):
//     0x10  string  m_String (absolute URI string)
//
// HttpResponseMessage (dump.cs line 1541046):
//     0x28  int32   statusCode  (HttpStatusCode)
//     0x40  ptr     Content     (HttpContent)
//
// We do NOT try to read the body content bytes here — the body stream is
// consumed asynchronously and may already be disposed.  The URL + status
// code is sufficient for login / account-creation flow tracing.
// ===========================================================================

// ---------------------------------------------------------------------------
// RVAs
// ---------------------------------------------------------------------------
// HttpClient.<SendAsyncWorker>d__47.MoveNext — outer state machine. Not
// actually invoked on our build (Grpc.Net.Client appears to go through a
// different code path), but we keep the hook in case some flows reach it.
#define RVA_HTTP_SEND_ASYNC_WORKER_MOVENEXT  0x607C994

// MonoWebRequestHandler.SendAsync(HttpRequestMessage, CancellationToken).
// This is the real HTTP entry point used by both regular HttpClient calls
// AND gRPC over HTTP/2 — every outbound request must pass through here.
// Signature: x0=self, x1=HttpRequestMessage*, x2=CancellationToken (struct).
#define RVA_MONO_SEND_ASYNC                  0x60789E4

// HttpClient.SendAsync(HttpRequestMessage, CancellationToken) — outermost
// entry. Hook this in case Grpc.Net.Client bypasses MonoWebRequestHandler
// entirely (e.g. uses its own HttpMessageHandler).
#define RVA_HTTPCLIENT_SEND_ASYNC            0x607C1D0

// HttpClientHandler.SendAsync — likely sits between HttpClient and Mono's
// transport. Grpc.Net.Client builds an HttpClient on top of this handler.
#define RVA_HTTPCLIENT_HANDLER_SEND_ASYNC    0x607695C

// DelegatingHandler.SendAsync — abstract base that gRPC interceptors wrap
// HttpClient calls with. Hooking here also catches any custom handler in
// Grpc.Net.Client's stack that injects request headers.
#define RVA_DELEGATING_HANDLER_SEND_ASYNC    0x607B4F4

// HttpMessageInvoker.SendAsync — base virtual. GrpcChannel.HttpInvoker is
// typed as HttpMessageInvoker, so even if it's a plain instance (not an
// HttpClient subclass), the call lands here.
#define RVA_HTTPMSGINVOKER_SEND_ASYNC        0x607C974

// HttpClient.SendAsync(HttpRequestMessage, HttpCompletionOption, CancellationToken)
// — the 3-arg overload Grpc.Net.Client typically calls with
// HttpCompletionOption.ResponseHeadersRead for streaming reads.
#define RVA_HTTPCLIENT_SEND_ASYNC_OPT        0x607C1DC

// HttpRequestMessage.ToString() — formats Method/Uri/Version/Headers/Content
// as a multi-line string. We call this directly from our hook to dump
// every outgoing gRPC request's headers.
#define RVA_HTTPREQMSG_TOSTRING              0x607FC8C

// HttpHeaders.TryAddWithoutValidation(string name, string value) — bypasses
// header validation. Used to overwrite x-user-id mid-flight when switching
// accounts (the server keys auth off this header, not LoginArgs.deviceId).
#define RVA_HTTPHEADERS_TRYADD               0x608886C
// HttpHeaders.Remove(string name) — remove the existing entry before re-add.
#define RVA_HTTPHEADERS_REMOVE               0x6088D24

// ---------------------------------------------------------------------------
// State machine field offsets
// ---------------------------------------------------------------------------
#define OFF_SM_STATE        0x00
#define OFF_SM_REQUEST      0x30
#define OFF_SM_RESPONSE     0x48

// ---------------------------------------------------------------------------
// HttpRequestMessage field offsets
// ---------------------------------------------------------------------------
#define OFF_REQ_HEADERS     0x10   // HttpRequestHeaders*
#define OFF_REQ_METHOD      0x18   // HttpMethod*
#define OFF_REQ_URI         0x30   // Uri*

// ---------------------------------------------------------------------------
// HttpMethod field offsets
// ---------------------------------------------------------------------------
#define OFF_METHOD_STRING   0x10   // il2cpp string

// ---------------------------------------------------------------------------
// Uri field offsets
// ---------------------------------------------------------------------------
#define OFF_URI_STRING      0x10   // il2cpp string (m_String)

// ---------------------------------------------------------------------------
// HttpResponseMessage field offsets
// ---------------------------------------------------------------------------
#define OFF_RESP_STATUS     0x28   // int32 (HttpStatusCode)

// ---------------------------------------------------------------------------
// il2cpp string helper (same layout as Hook_AccountObserve.m)
// ---------------------------------------------------------------------------
static NSString *grpcReadIl2CppString(void *strObj) {
    if (!strObj) return nil;
    @try {
        int32_t len = readI32(strObj, 0x10);
        if (len <= 0 || len > 4096) return nil;
        const uint16_t *chars = (const uint16_t *)((uint8_t *)strObj + 0x14);
        return [NSString stringWithCharacters:chars length:(NSUInteger)len];
    } @catch (...) { return nil; }
}

// ---------------------------------------------------------------------------
// Hook: HttpClient.SendAsyncWorker.MoveNext
// ---------------------------------------------------------------------------
typedef void (*MoveNextVoid_t)(void *self);
static MoveNextVoid_t orig_HttpSendAsyncWorkerMoveNext __attribute__((unused)) = NULL;

void HookHttpSendAsyncWorkerMoveNext(void *self) {
    KIOU_CALL_ORIG_VOID(orig_HttpSendAsyncWorkerMoveNext, self);

    if (!self) return;
    int32_t smState = readI32(self, OFF_SM_STATE);

    // Only log on completion (negative states). state==-2 is the normal
    // "completed" value for AsyncTaskMethodBuilder; other negative values may
    // appear depending on the Mono version. Log all negative states so we can
    // confirm the actual completion state on this build.
    if (smState >= 0) return;

    void *request  = readPtr(self, OFF_SM_REQUEST);
    void *response = readPtr(self, OFF_SM_RESPONSE);

    // --- request URL and method ---
    NSString *method = nil;
    NSString *url    = nil;

    if (request) {
        void *methodObj = readPtr(request, OFF_REQ_METHOD);
        if (methodObj)
            method = grpcReadIl2CppString(readPtr(methodObj, OFF_METHOD_STRING));

        void *uriObj = readPtr(request, OFF_REQ_URI);
        if (uriObj)
            url = grpcReadIl2CppString(readPtr(uriObj, OFF_URI_STRING));
    }

    // --- response status ---
    int32_t statusCode = -1;
    if (response)
        statusCode = readI32(response, OFF_RESP_STATUS);

    IPALog([NSString stringWithFormat:
              @"[GRPC] state=%d %@ %@ → HTTP %d",
              (int)smState,
              method ?: @"?",
              url    ?: @"(nil)",
              (int)statusCode]);
}

// ---------------------------------------------------------------------------
// Hook: MonoWebRequestHandler.SendAsync(HttpRequestMessage, CancellationToken)
// — the real HTTP entry point. Log URL + method as the request is sent.
// We don't await the response here; success/failure can be inferred from the
// downstream LoginReply / RegisterUserReply logs.
// ---------------------------------------------------------------------------
typedef void *(*MonoSendAsync_t)(void *self, void *request, void *ct);
static MonoSendAsync_t orig_MonoSendAsync __attribute__((unused)) = NULL;

typedef void *(*HttpReqMsgToString_t)(void *self);
static HttpReqMsgToString_t g_HttpReqMsgToString = NULL;

typedef bool (*HttpHeadersTryAdd_t)(void *self, void *name, void *value);
typedef bool (*HttpHeadersRemove_t)(void *self, void *name);
typedef void *(*GrpcIl2CppStringNew_t)(const char *utf8);
static HttpHeadersTryAdd_t   g_HttpHeadersTryAdd  = NULL;
static HttpHeadersRemove_t   g_HttpHeadersRemove  = NULL;
static GrpcIl2CppStringNew_t g_GrpcStringNew      = NULL;

// Resolve target user_id for `pending_device_id`: look up the saved
// account whose `uuid` matches and return its `userId` slot.
static NSString *targetUserIdForPendingDevice(NSString *pendingDevice) {
    if (pendingDevice.length == 0) return nil;
    for (NSDictionary *acc in KEBListAccounts()) {
        NSString *uuid = acc[@"uuid"];
        if ([uuid isKindOfClass:[NSString class]] &&
            [uuid isEqualToString:pendingDevice]) {
            NSString *uid = acc[@"userId"];
            if ([uid isKindOfClass:[NSString class]]) return uid;
        }
    }
    return nil;
}

// Swap the request's x-user-id header to the target account's userId.
// Without this the server rejects logins with -40004 because LoginArgs
// said "deviceId=X" but the auth header still names the previous user.
static void swapUserIdHeader(void *request) {
    if (!request || !g_HttpHeadersTryAdd || !g_HttpHeadersRemove ||
        !g_GrpcStringNew) return;
    NSString *pendingDevice = KEBPendingDeviceId();
    NSString *targetUserId  = targetUserIdForPendingDevice(pendingDevice);
    if (targetUserId.length == 0) return;
    void *headers = readPtr(request, OFF_REQ_HEADERS);
    if (!headers) return;
    void *nameStr  = g_GrpcStringNew("x-user-id");
    void *valueStr = g_GrpcStringNew(targetUserId.UTF8String);
    if (!nameStr || !valueStr) return;
    @try {
        g_HttpHeadersRemove(headers, nameStr);
        g_HttpHeadersTryAdd(headers, nameStr, valueStr);
        IPALog([NSString stringWithFormat:
                  @"[GRPC] x-user-id swapped → %@", targetUserId]);
    } @catch (NSException *e) {
        IPALog([NSString stringWithFormat:@"[GRPC] x-user-id swap threw: %@", e]);
    }
}

static void logRequest(void *request, const char *tag) {
    NSString *method = nil;
    NSString *url    = nil;
    if (request) {
        void *methodObj = readPtr(request, OFF_REQ_METHOD);
        if (methodObj)
            method = grpcReadIl2CppString(readPtr(methodObj, OFF_METHOD_STRING));
        void *uriObj = readPtr(request, OFF_REQ_URI);
        if (uriObj)
            url = grpcReadIl2CppString(readPtr(uriObj, OFF_URI_STRING));
    }
    IPALog([NSString stringWithFormat:@"[GRPC] %s %@ %@",
              tag, method ?: @"?", url ?: @"(nil)"]);

    // Dump headers via HttpRequestMessage.ToString() — its formatter includes
    // Method/Uri/Version/Headers/Content. Only call once we have a resolved
    // entry point AND a non-null request, to avoid faulting on partial state.
    if (request && g_HttpReqMsgToString) {
        @try {
            void *strObj = g_HttpReqMsgToString(request);
            NSString *full = grpcReadIl2CppString(strObj);
            if (full.length > 0) {
                IPALog([NSString stringWithFormat:@"[GRPC] req-dump:\n%@", full]);
            }
        } @catch (NSException *e) {
            IPALog([NSString stringWithFormat:@"[GRPC] req-dump threw: %@", e]);
        }
    }
}

void *HookMonoSendAsync(void *self, void *request, void *ct) {
    logRequest(request, "→[Mono]");
    return KIOU_CALL_ORIG_RET(void *, orig_MonoSendAsync, self, request, ct);
}

typedef void *(*HttpClientSendAsync_t)(void *self, void *request, void *ct);
static HttpClientSendAsync_t orig_HttpClientSendAsync __attribute__((unused)) = NULL;

void *HookHttpClientSendAsync(void *self, void *request, void *ct) {
    logRequest(request, "→[Client]");
    return KIOU_CALL_ORIG_RET(void *, orig_HttpClientSendAsync, self, request, ct);
}

typedef void *(*GenericSendAsync_t)(void *self, void *request, void *ct);
static GenericSendAsync_t orig_HttpClientHandlerSendAsync __attribute__((unused)) = NULL;
static GenericSendAsync_t orig_DelegatingHandlerSendAsync __attribute__((unused)) = NULL;

void *HookHttpClientHandlerSendAsync(void *self, void *request, void *ct) {
    logRequest(request, "→[ClientHandler]");
    return KIOU_CALL_ORIG_RET(void *, orig_HttpClientHandlerSendAsync, self, request, ct);
}

void *HookDelegatingHandlerSendAsync(void *self, void *request, void *ct) {
    logRequest(request, "→[Delegating]");
    return KIOU_CALL_ORIG_RET(void *, orig_DelegatingHandlerSendAsync, self, request, ct);
}

static GenericSendAsync_t orig_HttpMsgInvokerSendAsync __attribute__((unused)) = NULL;

void *HookHttpMsgInvokerSendAsync(void *self, void *request, void *ct) {
    swapUserIdHeader(request);
    logRequest(request, "→[Invoker]");
    return KIOU_CALL_ORIG_RET(void *, orig_HttpMsgInvokerSendAsync, self, request, ct);
}

typedef void *(*HttpClientSendAsyncOpt_t)(void *self, void *request, int32_t opt, void *ct);
static HttpClientSendAsyncOpt_t orig_HttpClientSendAsyncOpt __attribute__((unused)) = NULL;

void *HookHttpClientSendAsyncOpt(void *self, void *request, int32_t opt, void *ct) {
    logRequest(request, "→[Client3]");
    return KIOU_CALL_ORIG_RET(void *, orig_HttpClientSendAsyncOpt, self, request, opt, ct);
}

// ---------------------------------------------------------------------------
// Installer
// ---------------------------------------------------------------------------
#if IPA_CHINLAN
// ---------------------------------------------------------------------------
// Chinlan entry hook — HttpMessageInvoker.SendAsync(request, ct)
// x0=self, x1=HttpRequestMessage*, x2=CancellationToken
// CAVE_ENTRY: the hook calls bypass to run orig, but first rewrites the
// x-user-id header so account-switch logins are accepted by the server.
// ---------------------------------------------------------------------------
void *HookHttpMsgInvokerSendAsyncEntry(void *self, void *request, void *ct) {
    swapUserIdHeader(request);
    typedef void *(*SendAsync_t)(void *, void *, void *);
    SendAsync_t bypass =
        (SendAsync_t)g_inject_entry[KIOU_BR_HOOK_HTTPMSGINVOKER_SEND_ASYNC];
    return bypass ? bypass(self, request, ct) : NULL;
}

void InstallGrpcLoggingHook(uintptr_t unityBase) {
    (void)unityBase;
    // Pointer helpers needed by swapUserIdHeader — resolve once here.
    g_HttpHeadersTryAdd = (HttpHeadersTryAdd_t)(unityBase + RVA_HTTPHEADERS_TRYADD);
    g_HttpHeadersRemove = (HttpHeadersRemove_t)(unityBase + RVA_HTTPHEADERS_REMOVE);
    if (!g_GrpcStringNew)
        g_GrpcStringNew = (GrpcIl2CppStringNew_t)dlsym(RTLD_DEFAULT, "il2cpp_string_new");
    IPALog([NSString stringWithFormat:
              @"[GRPC] chinlan: header-swap helpers resolved tryAdd=%p remove=%p strNew=%p",
              g_HttpHeadersTryAdd, g_HttpHeadersRemove, g_GrpcStringNew]);
}
#else
void InstallGrpcLoggingHook(uintptr_t unityBase) {
    g_HttpReqMsgToString = (HttpReqMsgToString_t)(unityBase + RVA_HTTPREQMSG_TOSTRING);
    g_HttpHeadersTryAdd  = (HttpHeadersTryAdd_t) (unityBase + RVA_HTTPHEADERS_TRYADD);
    g_HttpHeadersRemove  = (HttpHeadersRemove_t) (unityBase + RVA_HTTPHEADERS_REMOVE);
    if (!g_GrpcStringNew) {
        g_GrpcStringNew = (GrpcIl2CppStringNew_t)dlsym(RTLD_DEFAULT,
                                                       "il2cpp_string_new");
    }
    IPALog([NSString stringWithFormat:
              @"[GRPC] resolved headers ops: tryAdd=%p remove=%p strNew=%p",
              g_HttpHeadersTryAdd, g_HttpHeadersRemove, g_GrpcStringNew]);

    uintptr_t addr = unityBase + RVA_HTTP_SEND_ASYNC_WORKER_MOVENEXT;
    MSHookFunction((void *)addr,
                   (void *)HookHttpSendAsyncWorkerMoveNext,
                   (void **)&orig_HttpSendAsyncWorkerMoveNext);
    IPALog([NSString stringWithFormat:
              @"[GRPC] hooked HttpClient.SendAsyncWorker.MoveNext @0x%lx",
              (unsigned long)addr]);

    uintptr_t addr2 = unityBase + RVA_MONO_SEND_ASYNC;
    MSHookFunction((void *)addr2,
                   (void *)HookMonoSendAsync,
                   (void **)&orig_MonoSendAsync);
    IPALog([NSString stringWithFormat:
              @"[GRPC] hooked MonoWebRequestHandler.SendAsync @0x%lx",
              (unsigned long)addr2]);

    uintptr_t addr3 = unityBase + RVA_HTTPCLIENT_SEND_ASYNC;
    MSHookFunction((void *)addr3,
                   (void *)HookHttpClientSendAsync,
                   (void **)&orig_HttpClientSendAsync);
    IPALog([NSString stringWithFormat:
              @"[GRPC] hooked HttpClient.SendAsync @0x%lx",
              (unsigned long)addr3]);

    uintptr_t addr4 = unityBase + RVA_HTTPCLIENT_HANDLER_SEND_ASYNC;
    MSHookFunction((void *)addr4,
                   (void *)HookHttpClientHandlerSendAsync,
                   (void **)&orig_HttpClientHandlerSendAsync);
    IPALog([NSString stringWithFormat:
              @"[GRPC] hooked HttpClientHandler.SendAsync @0x%lx",
              (unsigned long)addr4]);

    uintptr_t addr5 = unityBase + RVA_DELEGATING_HANDLER_SEND_ASYNC;
    MSHookFunction((void *)addr5,
                   (void *)HookDelegatingHandlerSendAsync,
                   (void **)&orig_DelegatingHandlerSendAsync);
    IPALog([NSString stringWithFormat:
              @"[GRPC] hooked DelegatingHandler.SendAsync @0x%lx",
              (unsigned long)addr5]);

    uintptr_t addr6 = unityBase + RVA_HTTPMSGINVOKER_SEND_ASYNC;
    MSHookFunction((void *)addr6,
                   (void *)HookHttpMsgInvokerSendAsync,
                   (void **)&orig_HttpMsgInvokerSendAsync);
    IPALog([NSString stringWithFormat:
              @"[GRPC] hooked HttpMessageInvoker.SendAsync @0x%lx",
              (unsigned long)addr6]);

    uintptr_t addr7 = unityBase + RVA_HTTPCLIENT_SEND_ASYNC_OPT;
    MSHookFunction((void *)addr7,
                   (void *)HookHttpClientSendAsyncOpt,
                   (void **)&orig_HttpClientSendAsyncOpt);
    IPALog([NSString stringWithFormat:
              @"[GRPC] hooked HttpClient.SendAsync(opt) @0x%lx",
              (unsigned long)addr7]);
}
#endif // IPA_CHINLAN / !IPA_CHINLAN
