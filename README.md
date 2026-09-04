<p align="center">
  <img src="https://raw.githubusercontent.com/light-speak/luxo/main/assets/logo.svg" alt="Luxo" width="200" />
</p>

<h3 align="center">LuxoClient for Swift</h3>

<p align="center">
  Swift SDK for Luxo — build APIs at the speed of light.
</p>

<p align="center">
  <a href="https://github.com/light-speak/luxo-swift"><img src="https://img.shields.io/badge/Swift-5.9+-orange.svg" alt="Swift" /></a>
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

Auto-reconnect with exponential backoff (1s → 2s → 4s → ... → 30s max):

```swift
let ws = try WebSocketTransport(
    url: "wss://api.example.com/ws",
    token: "jwt-token"
)
ws.connect()
let unsubscribe = try await ws.subscribe("postCreated") { value in
    print("Received: \(value)")
}

// Later: unsubscribe()
```

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
- `Models.swift` — typed structs with Codable
- `Decoders.swift` — binary decoders per model
- `Schema.swift` — API schema map
- `Client.swift` — typed client with async/await methods

Generated output fields use `Selected<Value>` to distinguish unselected,
selected `nil`, and selected value without fabricated defaults. Input DTOs are
strict; a schema type used for both input and output generates `Foo` and
`FooInput`. Call `try field.requireValue()` after selecting a field; attempting
to read an unselected field throws `SelectionError`.

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
