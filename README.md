<p align="center">
  <img src="https://raw.githubusercontent.com/light-speak/luxo/main/assets/logo.svg" alt="Luxo" width="200" />
</p>

<h3 align="center">LuxoClient for Swift</h3>

<p align="center">
  Swift SDK for Luxo — build APIs at the speed of light.
</p>

<p align="center">
  <a href="https://github.com/light-speak/luxo-swift"><img src="https://img.shields.io/badge/Swift-6.3+-orange.svg" alt="Swift" /></a>
  <a href="https://github.com/light-speak/luxo-swift"><img src="https://img.shields.io/badge/Platforms-iOS%2015%20%7C%20macOS%2013-blue.svg" alt="Platforms" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache%202.0-blue.svg" alt="License" /></a>
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#quick-start">Quick Start</a> ·
  <a href="#features">Features</a> ·
  <a href="https://github.com/light-speak/luxo/blob/main/README_CN.md">中文文档</a>
</p>

---

## Why Luxo?

**Luxo** /lɑːkèsuǒ/ — the path from database to client should be short. Instead, we turned it into a maze.

JSON repeats every field name on every response — like a memo that prints the letterhead on every line. GraphQL parses queries at runtime that were already hardcoded at compile time. ORMs reflect over structs again and again, doing work the compiler finished long ago. `SELECT *` fetches entire rows, only to throw most of them away by hand.

Every layer re-discovers what the layer before it already knew.

We started with one question: **from storage to screen, what is the minimum number of steps — and the minimum number of bytes at each step?**

**Lux** (Latin, *light*) — not a metaphor, but an engineering constraint. Binary encoding is decided at compile time. Field selection flows from client all the way down to SQL. Data should arrive the way light does: no detours, no waste.

**O** (*origin*) — everything starts from the schema. Database tables, type definitions, codecs, client SDKs — all grown from a single `.luxo` file. No second source of truth.

> **Luxo — One origin. Speed of light.**

## What is Luxo?

Luxo is a **programming language** that compiles to Go — with a built-in API framework, its own protocol, and a complete toolchain from schema to deployment.

Write `.luxo` files. Get: API server, database layer, client SDKs, migrations, monitoring dashboard. No glue code.

```luxo
model User @crud {
  name:     String @filterable
  email:    String @unique
  password: String @hidden @hash
  role:     Role = Role.USER
  posts:    [Post]
}
```

One file. Zero boilerplate. This generates everything — including the Swift client you're about to use.

## What Does This Package Do?

`LuxoClient` is the **Swift/iOS SDK** for Luxo. It connects your iOS/macOS app to a Luxo API server.

```
┌─────────────┐     ┌──────────────┐     ┌──────────────┐
│  Your App   │ ──→ │  LuxoClient  │ ──→ │ Luxo Server  │
│ (SwiftUI)   │     │ URLSession   │     │  (Luvia)     │
└─────────────┘     └──────────────┘     └──────────────┘
                     JSON (dev)
                     Binary (prod, 3x smaller)
```

## Install

Requires Swift 6.3 or later and compiles in Swift 6 language mode. The field
analyzer uses SwiftSyntax 603; deployment minimums remain iOS 15 and macOS 13.

需要 Swift 6.3 或更新版本，使用 Swift 6 语言模式；字段分析器使用 SwiftSyntax 603。
工具链升级不提高设备最低版本，仍为 iOS 15 / macOS 13。

### Swift Package Manager

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/light-speak/luxo-swift.git", from: "0.1.0")
]

// Target
.target(name: "YourApp", dependencies: [
    .product(name: "LuxoClient", package: "luxo-swift"),
]),
```

Or in Xcode: **File → Add Package Dependencies → paste the URL above.**

## Quick Start

```swift
import LuxoClient

let transport = try URLSessionTransport(
    endpoint: "https://api.example.com/luvia",
    token: "your-jwt-token",
    timeout: 30
)
transport.onTokenExpired = {
    // Auto-refresh on 401
    await refreshToken()
}

// Every API call is one line
let user = try await transport.call("getUser", params: ["id": 1])
let posts = try await transport.call("listPosts", params: ["page": 1, "pageSize": 20])
```

## Features

### URLSession HTTP/2 Transport

Native `URLSession` with HTTP/2 multiplexing. Works on iOS 15+, macOS 13+:

```swift
let transport = try URLSessionTransport(endpoint: "https://api.example.com/luvia")
```

### WebSocket — Real-time Subscriptions

Connections reconnect with exponential backoff (1s → 2s → 4s → ... → 30s max).
Interrupted subscriptions terminate; callers decide whether to subscribe again:

```swift
let ws = try WebSocketTransport(
    url: "wss://api.example.com/ws",
    token: "jwt-token"
)
ws.connect()
let observer = StreamObserver(
    onComplete: { print("Stream completed") },
    onError: { error in print("Stream failed: \(error)") }
)
let unsubscribe = try await ws.subscribe("postCreated", decoder: { $0 }, observer: observer) { value in
    print("Received: \(value)")
}

// Later: unsubscribe()
```

Each subscription has an independent UInt64 identity, including concurrent
subscriptions to the same API. JSON preserves the exact decimal ID; Binary uses
the `0x10`–`0x16` subscription frames. Cancel the returned `@Sendable` closure,
not an API name. Cancelling setup or waiting past its timeout sends an unsubscribe
for that ID. A disconnect or explicit connection replacement removes all old
subscriptions: established observers receive one `NetworkError`, and pending
subscription setup throws `NetworkError` without also notifying its observer.
Ordinary pending calls retain their existing `ConnectionError` behavior.
An unparseable JSON message, invalid root or malformed Unicode instead closes
the connection with `ParseError` for all pending calls/setup and established
streams. No ID is guessed from a damaged document. A valid envelope with bad
business data still fails only its subscription with `DecodeError`.
Reconnection restores only the connection, never replays subscriptions, and does
not recover missed events. Create a new subscription explicitly after recovery;
old cancellation closures cannot cancel it. This pre-release wire requires
matching server and SDK versions; retired subscription frames are not accepted.

The optional `StreamObserver` receives normal completion (`$end` / `0x15`) or a
post-ACK business error (`$end` / `0x16`), preserving raw JSON numbers in error data.
The transport removes the subscription before notifying; duplicate terminals and
late data do not affect another subscription, and the connection stays usable.
Explicit cancellation and `close()` are silent for established observers; closing
still fails pending calls/setup. Disconnect notifications are queued outside the
socket call stack, so callbacks may reenter `close()` without holding its locks.
A terminal before the initial ACK rejects setup
with `ParseError` rather than notifying an observer for an unestablished stream.
Low-level subscriptions now require a throwing, `@Sendable` typed `decoder` before
`params`. The example uses an explicit identity decoder to receive raw payloads.
Generated subscription methods keep their public call syntax; regenerate clients
and adapt handwritten `Transport` implementations together.

Only decoder errors terminate that subscription with one local `DecodeError`.
Local state is removed before attempting remote cancellation; a failed cancel
write does not restore it, close the shared connection or affect other calls.
Decode-error notifications are queued outside the socket call stack, as disconnect
notifications are. Valid delivery remains synchronous and is not wrapped in a
per-message task. Handlers remain nonthrowing Swift callbacks, outside the decoder
catch; traps and fatal errors are not recoverable protocol failures. No reflection
or serialization round trip is added. Complete generated-model, allocation,
network/device and performance gates remain separate pre-release requirements.

### Per-response Encoding

`Transport.call` returns `TransportPayload`, and subscription decoders receive
the same immutable value: `data` is the original response `Data`, and
`mode` identifies its encoding. Wrapping it does not re-encode or copy the bytes.
HTTP records the mode of the successful attempt, including a retry after token
refresh; WebSocket records the received frame's format. Changing configuration
does not change the decoding mode of an in-flight response or existing stream.

Generated methods keep their typed API and decode using each payload's mode,
without a shared decoding switch or mode lock. Regenerate clients together with
this pre-release SDK. Handwritten transports must return/forward
`TransportPayload(data: bytes, mode: actualMode)` and update their subscription
handler type to `@Sendable (TransportPayload) -> Void`; forwarding transports must
preserve the received mode rather than infer it from current configuration.
JSON/Binary wire bytes and numeric ranges are unchanged.

### Binary Mode — 3x Smaller Than JSON

JSON in dev for easy debugging. Switch to binary in prod — same API, zero code changes:

```swift
transport.setMode(.binary)
transport.setSchema(LUXO_SCHEMA) // from codegen
```

### 401 Auto-Refresh

Token expires? The SDK calls your callback, gets a new token, retries automatically:

```swift
let transport = try URLSessionTransport(endpoint: endpoint)
transport.onTokenExpired = {
    await myAuthService.refresh() // nil = give up
}
```

### Binary Codec

Low-level varint/svarint/fixed64 encoding:

```swift
var encoder = Encoder()
encoder.writeVarint(42)
encoder.writeString("hello")
encoder.writeSvarint(-100)
encoder.writeFixed64(3.14)

var decoder = Decoder(encoder.data)
decoder.readVarint()  // 42
decoder.readString()  // "hello"
decoder.readSvarint() // -100
decoder.readFixed64() // 3.14

// Nullable readers
let maybeInt: Int64? = decoder.readIntPtr()
let maybeStr: String? = decoder.readStringPtr()

// Array reading
let items = decoder.readArray { d in d.readString() }
```

### Field Tracking — SwiftSyntax

Compile-time field tracking via SwiftSyntax AST analysis:

```swift
// LuxoAnalyze scans your source code
// Detects: user.name, user.email → generates $select hint
// Nested: user.posts.map { $0.title } → "name, email, posts { title }"
```

### Code Generation

Generate typed client from schema introspection:

```swift
import LuxoClient

let codegen = try LuxoCodegen(
    endpoint: "http://localhost:4000/luvia",
    introspectionKey: "YOUR_KEY"
)
try await codegen.generate(outputDir: "Sources/YourApp/Luxo")
```

Generates:
- `Models.swift` — typed Codable outputs and `LuxoBinaryEncodable` inputs; native binary writers and typed JSON projections avoid intermediate JSON encoding/decoding
- `Decoders.swift` — binary decoders per model
- `Schema.swift` — API schema map
- `Client.swift` — typed client with async/await methods

Generated output fields use `Selected<Value>` to distinguish unselected,
selected `nil`, and selected value without fabricated defaults. Input DTOs are
strict; a schema type used for both input and output generates `Foo` and
`FooInput`. Call `try field.requireValue()` after selecting a field; attempting
to read an unselected field throws `SelectionError`.

Regenerate clients to enforce JSON model/type list projections: every record,
including pagination items and nested lists, must contain at least one schema
field. Empty or unknown-only records fail decoding; selected nullable `null`
and empty lists remain valid. Standalone objects, input DTOs and generic JSON
are unchanged. Invalid list payloads do not reach stream success callbacks.

Generated parameters construct `LuxoValue` directly for supported scalar types,
enums and lists. Input DTOs implement `luxoJSONValue()` with typed fields and
defer nested inputs without round-tripping through JSONEncoder/JSONSerialization.
Optional DTO fields remain omitted when nil; API patch arguments still distinguish
absent, explicit null and a value. Schema Float parameters reject NaN and infinity.
Existing custom `LuxoBinaryEncodable` conformers retain their Encodable-based
default projection; re-generate inputs to use the direct path.

生成参数按已知标量、枚举和列表类型直接构造 `LuxoValue`，输入 DTO 生成强类型
`luxoJSONValue()`，不再先编码 JSON 再解析。可空 DTO 字段为 nil 时仍省略，API patch
参数仍区分未传、显式 null 和值；Float 参数继续拒绝 NaN 和无穷大。已有自定义
`LuxoBinaryEncodable` 保留基于 Encodable 的默认转换，重新生成输入类型即可使用直接路径。

## DateTime precision

Generated DateTime values remain strings in JSON and Binary. They require
timezone-bearing RFC3339, at most nine fractional digits and UTC years 0000–9999.
Binary stores signed floor Unix seconds followed by unsigned nanoseconds; JSON
output uses UTC and retains the exact fractional value. Invalid dates, excess
precision and range overflow are rejected rather than normalized or truncated.
Native `Date` inputs preserve only the precision already present in their Double;
use strings for exact nanoseconds. Regenerate services and SDKs together: this
pre-release wire change has no whole-second fallback, and internal RPC is version
3. Database precision and performance require separate verification.

## Integer input precision

Generic JSON now preserves numeric tokens. Integers fitting Int64 use
`JSONValue.integer`; fractions, exponents, negative zero and larger integers use
`JSONValue.rawNumber(JSONNumber)`. The transport equivalent is `LuxoValue.jsonNumber`.
`1.0`, `1E+03`, `-0`, high-precision fractions and `1e±400` remain unquoted numbers
with their original spelling, including JSON embedded in Binary fields and error data.
Error data retains its existing dictionaries/arrays; raw numeric leaves are `JSONNumber`.

通用 JSON 保留数字原文：Int64 范围内整数使用 `.integer`；小数、指数、负零及更大
整数使用 `.rawNumber(JSONNumber)`。传输值对应 `LuxoValue.jsonNumber`。
JSON/Binary 内嵌 JSON 和错误 data 均不先转成浮点数；错误 data 继续使用原有
字典/数组结构，其中原文数字叶子改为 `JSONNumber`。这不引入任意精度运算库。

```swift
let number = try JSONNumber("0.12345678901234567890123456789")
let value = JSONValue.object(["amount": .rawNumber(number)])
let data = try value.jsonData()  // Numeric token, not a quoted string.
let decoded = try JSONValue.parse(data)
let approximate = try number.toDouble()  // Explicit IEEE-754 rounding.
let exact = try JSONNumber("9223372036854775807").toInt64()
```

Use `LuxoJSONDecoder` / `LuxoJSONEncoder` for Codable values containing generic JSON.
Generated clients use these boundaries automatically; regenerate older clients.
Foundation's generic Decoder interface cannot expose original numeric tokens;
`JSONValue` refuses numeric decoding through that interface instead of silently
rounding. Foundation JSONEncoder also refuses raw-number cases. Hand-created
`.number(Double)` values are already floating point and cannot recover lost precision.

包含通用 JSON 的 Codable 对象使用 `LuxoJSONDecoder` / `LuxoJSONEncoder`；旧客户端
需重新生成。Foundation Decoder 不能暴露数字 token，相关入口对数字报错，不悄悄
舍入；Foundation JSONEncoder 也拒绝原文数字。调用方自己构造的 `.number(Double)`
已是浮点数，无法恢复更早丢失的精度。

Explicit `toInt64()` requires integer syntax and signed 64-bit range. `toDouble()`
allows normal rounding but rejects infinity and nonzero underflow to zero.
Raw-number equality compares tokens; it never coerces a token to Double.
Explicit JSON value parsing/writing does not preserve whitespace or object key
order. Parsing/writing is bounded to 128 nested levels and rejects malformed UTF-8;
no reflection or JSON round trip
is added. Custom Encodable projection now writes a typed tree directly.

`toInt64()` 检查整数语法与范围；`toDouble()` 允许正常舍入，但拒绝溢出和非零下溢
为零。原文数字比较 token，不隐式转成 Double。不保证空白与对象键顺序。
读写限制 128 层嵌套并拒绝非法 UTF-8，不新增反射或 JSON 序列化往返；自定义
Encodable 现在直接投影成类型化值树。

HTTP and WebSocket JSON transports validate the complete envelope and return the
original `data` bytes, including whitespace, escapes, duplicate keys and numeric
tokens. They do not build and re-serialize a success payload before the generated
decoder reads it. Unknown envelope fields are still validated. Error payloads are
materialized once when the HTTP status or preceding `error` field identifies a
failure; if `data` precedes the WebSocket error marker, it is validated before
being decoded. This optimization does not imply a single scan for the entire
typed request or a change to the JSON/Binary value contract.

`LuxoValue.int` stores a signed `Int64`. When converting custom `Encodable`
inputs through `LuxoValue.encode`, unsigned integers above `Int64.max` become raw
JSON numbers instead of wrapping into negative values. Signed boundaries
remain exact in JSON and binary modes; use generated input types for the
schema's field-specific representation. Floating-point and opaque JSON values
are not interchangeable with typed integer fields.

`LuxoValue.int` 使用有符号 `Int64`。自定义 `Encodable` 经 `LuxoValue.encode`
转换时，超过 `Int64.max` 的无符号整数保留为原文 JSON 数字，不绕回负数。
Schema 字段请使用生成的输入类型，不能以浮点数或 opaque JSON 代替整数参数。

With a registered schema, HTTP JSON calls, WebSocket calls and subscriptions
validate supplied `Int`/`Duration` parameters and nested input fields while
building the existing JSON representation. Only `LuxoValue.int` is accepted:
there is no floating-point truncation or boolean/string coercion. Nullable
lists may be null, but their elements must be non-null integers. Errors include
the offending path, such as `input.children[1].id`, and occur before sending.

Integer paths are compiled once per `APISchema`, including recursive model
references without reference cycles. Re-generate older clients whose nested
input schema lacks field types: missing metadata on supplied fields produces
`ConfigError`. This is not full server-side validation; absent parameters and
JSON calls without a registered schema still rely on server validation.
JSON and binary retain the same signed integer range and precision.

Generated clients register `LUXO_SCHEMA` in their initializer for both modes;
`enableBinary()` changes mode without registering again. Regenerate older clients
that only registered when enabling Binary, otherwise JSON bypasses the existing
schema-aware checks. Schema preparation is initialization work, but the now-connected
per-request validation is not free and remains subject to performance acceptance.

注册 Schema 后，HTTP JSON、WebSocket 调用和订阅会在现有 JSON 转换过程中校验
实际传入的 `Int`/`Duration` 参数和嵌套输入字段，只接受 `LuxoValue.int`，不截断
浮点数，也不将布尔值/字符串强转成整数。可空列表允许整体为 null，不允许整数
元素为 null；发送前的错误包含 `input.children[1].id` 这样的字段路径。

每份 `APISchema` 仅编译一次整数路径，递归模型不产生循环引用。旧生成客户端若
缺少嵌套字段类型，需要重新生成；传入字段缺少对应类型元数据会报 `ConfigError`。
这不是完整的服务端校验：未传参数、未注册 Schema 的手工 JSON 调用仍由服务端
校验。JSON 和 Binary 的有符号整数范围、精度要求不变。

生成客户端在初始化时为两种模式注册 `LUXO_SCHEMA`；`enableBinary()` 不再重复注册。
旧客户端若仅开启 Binary 时注册，需要重新生成，否则 JSON 未接上现有 Schema 校验。
Schema 预处理属于初始化，但接通后的每请求校验并非零成本，性能门禁仍保留。

WebSocket request IDs are unsigned transport metadata, separate from signed
schema integers. JSON responses reject boolean, floating-point and overflowing
IDs before looking up a pending request; valid IDs preserve the full UInt64
range. JSON calls also emit full-width IDs without narrowing to Int64, and
caller parameters cannot override `$id` or `$api`. Exhausting the request
counter throws `RequestIDExhausted` instead of wrapping over pending calls.
Binary responses validate the single-byte frame type and ID varint once,
and successful subscription acknowledgements cannot contain a payload.

WebSocket 请求 ID 是无符号传输元数据，不同于 Schema 的有符号整数。JSON 响应在
匹配请求前拒绝布尔值、浮点数和溢出 ID，合法 ID 保留完整 UInt64 范围。JSON
发送端不再窄化到 Int64，调用参数不能覆盖 `$id`/`$api`；计数器耗尽时抛出
`RequestIDExhausted`，不回绕覆盖等待中的请求。Binary
仅校验、解析一次单字节帧类型和 ID varint，成功订阅确认不允许夹带 payload。

ID validation now sees the original numeric syntax: `-0`, fractions and exponents
are rejected, while valid `0` and UInt64.max remain accepted.

编号校验保留原始语法：拒绝 `-0`、小数及指数，继续接受合法的 `0` 和 UInt64.max。

Handwritten JSON parameters reject NaN and infinities with `EncodingError`
during JSON writing, before sending. This
does not replace schema-specific validation of manual integer parameters.

手工 JSON 参数中的 NaN/无穷大在发送前的 JSON 写入阶段以 `EncodingError` 拒绝；
这不能代替手工整数参数的 Schema 专用校验。

HTTP and WebSocket error responses require `error`, an exact integer `code`,
and `message`. Malformed fields produce `ParseError`; optional `traceId` and
`cause` must be strings or null. An absent or invalid code no longer silently
becomes the HTTP status, and a present zero is not overwritten. Malformed 401
responses do not trigger token refresh. Binary errors also reject duplicate
fields. These checks run in error branches, without adding a successful-response
traversal or changing the public `Int` error-code type. The local convenience
helper `LuxoError.from(json:)` keeps defaults for omitted fields and the `name`
alias, but rejects malformed fields that are present.

HTTP/WebSocket 错误响应必须包含 `error`、精确整数 `code` 和 `message`；
字段非法时返回 `ParseError`，可选的 `traceId`/`cause` 只能是字符串或 null。
缺失或非法错误码不再静默替换成 HTTP 状态码，显式的零值也不被覆盖；
非法的 401 响应不会触发刷新令牌。Binary 错误额外拒绝重复字段。
校验仅在错误分支执行，不增加成功响应遍历，不改变公开错误码的 `Int` 类型。
本地便捷函数 `LuxoError.from(json:)` 保留缺省值和 `name` 别名，但拒绝已提供的非法字段。

`Benchmarks/TransportMetadata.swift` compares current parsing against both the
unchecked baseline and the previous strict check. Improved bridging does not
remove the entire validation cost; performance acceptance is still pending.
The `--errors` option separately compares minimal/full JSON and Binary errors
against frozen pre-fix decoders; it excludes network I/O and fixture creation.

`Benchmarks/TransportMetadata.swift` 同时保留未校验基线和上一版严格校验作对照。
桥接优化尚未消除全部校验成本，性能验收仍未通过。
`--errors` 单独对照最小/完整 JSON、Binary 错误响应与修复前冻结实现，
不计网络及 fixture 构造时间。

### Live Go interoperability / 真实 Go 联测

The core repository's `tests/sdk-interop` fixture compiles a real `.luxo` service.
It fetches live introspection, generates an independent SwiftPM consumer and verifies
HTTP/WebSocket × JSON/Binary with full-width integer vectors, Duration, arrays,
nullable/structured input, columnar output, explicit partial selection and native streams.
The consumer uses public SDK interfaces and strict Swift 6 compilation, without a
runtime compiler dependency. Core CI has a cross-repository step for the same check;
compatible Swift changes must be available there before a coordinated core PR passes.

核心仓库的 `tests/sdk-interop` 从真实 `.luxo` 编译服务，并从实时 introspection 生成独立
SwiftPM 消费项目。四种通道验证全宽整数、Duration、数组、nullable/结构化输入、列式、
显式部分选择和 native 流；只使用公开 SDK 接口及严格 Swift 6 编译，不把编译器放入消费者
运行时。核心 CI 有同样的跨仓库步骤，联动修改需要先提供兼容 Swift revision。

Run from the core checkout / 从核心仓库根目录运行：

```sh
LUXO_SWIFT_PATH=/path/to/luxo-swift go run ./tests/sdk-interop -run -- bash tests/sdk-interop/swift/run.sh
```

The owner closes the loopback service and cleans its generated scratch files on
success or failure. These checks do not certify iOS devices, all error/page shapes,
multi-service routing or network performance, and do not waive performance gates.

成功或失败后 owner 都关闭回环服务并清理本次生成文件。这些检查不代表 iOS 设备、全部
错误/分页形状、多服务路由或网络性能验收完成，不放宽性能门禁。

### Generated scalar responses / 生成的标量响应

The external consumer compiles and executes 44 methods covering eleven return kinds,
scalar/list shapes and calls/streams in both JSON and Binary. Enum replies use the
declared enum type, and throwing JSON-list decoding stays inside the stream's guarded
decode path. No-argument calls explicitly pass `params: nil`.

A shared generated boundary rejects decoder errors and trailing bytes after a complete
Binary scalar/list reply; it is not applied to inline row fields. Calls throw
`DecodeError` instead of returning a decoder's zero/empty placeholder. The current
data callback remains success-only: invalid payloads do not invoke it. These decoding
failures do not yet notify `StreamObserver`; server-sent terminal errors do. This
does not certify complete stream-error observability.

The Binary response boundary also normalizes embedded JSON parser failures to
`DecodeError`, retaining the underlying diagnostic. `--decoder-errors-bench` on
the release-mode generated consumer compares this path to the frozen previous
boundary; its cost is separate from WebSocket terminal dispatch.

外部消费测试实际编译并执行 44 个方法，覆盖 11 类返回类型、标量/数组、调用/流的
JSON 与 Binary。枚举保持声明类型，JSON 数组流在可捕获错误的解码边界内执行；
无参数调用显式传入 `params: nil`。

共用的生成边界在完整 Binary 标量/数组响应末尾检查 decoder 错误和剩余字节，不误用于
行内字段。普通调用抛出 `DecodeError`，不返回失败占位的零或空数组。现有流回调仍仅
接收成功值，坏 payload 不触发它；解码失败尚未转发给 StreamObserver，服务端终止错误则已通知，不能据此宣称流错误可观测性完整。

`Tests/Consumer/Fixtures/ScalarResponseBenchmark.swift` measures the actual generated
boundary against valid unchecked decoding. After generating the external consumer,
build it in release mode and run `LuxoGeneratedConsumer --scalar-bench`. Checks are
per response, not initialization, and remain subject to performance acceptance.

`Tests/Consumer/Fixtures/ScalarResponseBenchmark.swift` 对实际生成边界与合法输入的
未校验读取作对照。生成外部消费者后，以 release 模式构建并运行
`LuxoGeneratedConsumer --scalar-bench`。完整性检查是逐响应成本，不属于初始化，
性能门禁仍然保留。

### Structured response boundaries / 结构化响应边界

Generated row and column decoders preserve the distinction between unselected fields,
explicit nulls and empty arrays. Nested objects read their length-prefixed submessage;
nested lists read a complete columnar submessage. Each independent payload propagates
decoder errors and rejects trailing bytes. Rows require an end marker, and pages also
require the complete `total/page/pageSize` signed-int64 trailer before constructing rows.

`StructuredResponses.swift` in the external consumer checks JSON/Binary values through
generated calls and streams, including nested objects/lists, full-width integer array
cells, empty pages and full-width pagination metadata. Malformed fixtures cover truncated
children, array cells and page trailers, overflows and trailing data. Invalid stream data
does not invoke the success callback; typed decoding errors are not yet forwarded
to the terminal observer.

生成的行式/列式解码器区分未选字段、显式 null 和空数组。嵌套对象按带长度前缀的
独立子消息读取，嵌套列表按完整列式子消息读取；各独立边界传播错误并拒绝尾随字节。
行式对象必须包含结束标记，分页还需完整读取 `total/page/pageSize` 三个 signed int64
值后再构造记录。外部消费者实际执行调用与流，验证上述合法值和非法负载，而非仅检查
生成源码片段；坏流数据不触发成功回调，但错误通知能力并未在这里扩展。

Array and column readers reject impossible counts before reserving result capacity.
The row arena limit matches the existing column limit (64 MiB). Run the scoped,
three-process paired comparison with `bash Scripts/benchmark-metadata.sh`; it extracts
the immutable pre-change decoder into an owned `.tmp` directory and removes it on exit.
These are per-decode checks. Local primitive measurements do not waive whole-request,
allocation or device performance gates, nor establish nullable-array parity across SDKs.

数组与列在预分配前检查最小负载，行式 arena 与列式采用相同的 64 MiB 上限。
运行 `bash Scripts/benchmark-metadata.sh` 可与冻结的旧解码器进行三进程交替对照；
基线提取到专用 `.tmp` 目录，退出时自动清理。这些检查是逐次解码成本，局部数据
不替代完整请求、分配和设备性能验收，也不代表四 SDK 的可空数组语义已经统一。

## Products

| Product | Description |
|---------|-------------|
| **LuxoClient** | Transport, codec, types, errors, and code generation |
| **LuxoCompiler** | SwiftSyntax field-selection analyzer |
| **LuxoAnalyze** | CLI tool for field tracking analysis |

## Ecosystem

| Package | Platform | Description |
|---------|----------|-------------|
| [`@luxojs/client`](https://www.npmjs.com/package/@luxojs/client) | npm | TypeScript/JavaScript SDK |
| [`@luxojs/react`](https://www.npmjs.com/package/@luxojs/react) | npm | React hooks |
| [`@luxojs/vite-plugin`](https://www.npmjs.com/package/@luxojs/vite-plugin) | npm | Vite compile-time `$select` |
| [`luxo_client`](https://pub.dev/packages/luxo_client) | pub.dev | Dart/Flutter SDK |
| **[LuxoClient](https://github.com/light-speak/luxo-swift)** | SPM | Swift SDK |

## Links

- [Luxo Framework](https://github.com/light-speak/luxo) · [中文文档](https://github.com/light-speak/luxo/blob/main/README_CN.md)
- [Why "Luxo"?](https://github.com/light-speak/luxo#why-luxo) — *Lux (light) + O (origin)*
- [The Language](https://github.com/light-speak/luxo#the-language) — 32 keywords, compiles to Go

## License

Apache-2.0 · Copyright 2026 [light-speak](https://github.com/light-speak)
