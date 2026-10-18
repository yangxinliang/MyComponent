// The Swift Programming Language
// https://docs.swift.org/swift-book


// Helpers 是实现细节，使用 internal import 隐藏模块依赖，
// 这样打包成 XCFramework 后客户端不需要再提供 Helpers 模块。
internal import Helpers

public class SPMDemo {
    
    public init(){}
    
    public func priteLog() {
        
        print("我是Swift")
        
        HelperDemo.test()
    }
    
}
