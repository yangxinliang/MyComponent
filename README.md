# MyComponent

Swift Package 组件（Swift + ObjC）。

## 生成 XCFramework

```bash
./build-xcframework.sh
```

生成 `build/MyComponent.xcframework`，包含：

- 真机：`ios-arm64`
- 模拟器：`ios-arm64_x86_64-simulator`
- 最低 iOS 版本：自动读取 `Package.swift` 的 `platforms`（未声明时使用 SwiftPM 默认值，目前为 iOS 15.0）

常用参数：

| 参数 | 说明 |
| --- | --- |
| `-o, --output <目录>` | 输出目录，默认 `build` |
| `-c, --configuration <配置>` | `release` / `debug`，默认 `release` |
| `--ios-min <版本>` | 指定最低 iOS 版本，例如 `15.0` |
| `--sim-archs <架构>` | 模拟器架构，默认 `arm64 x86_64` |
| `--clean` | 清理中间产物和旧 XCFramework |
| `--no-verify` | 跳过生成后的客户端导入验证 |

### 接入 Xcode

1. 把 `MyComponent.xcframework` 拖入 Target；
2. 在 **Frameworks, Libraries, and Embedded Content** 中选择 **Do Not Embed**；
3. 客户端代码直接 `import MyComponent`。

> 这是静态 XCFramework。`Helpers` 是内部实现细节，通过 `internal import Helpers` 隐藏，客户端不需要额外引入。
