import Combine
import SwiftUI

/// View-local state, equivalent to `@State`.
///
/// In the macOS 27 SDK `@State` is a macro whose compiler plugin ships only with
/// Xcode, so it can't be built with the Command Line Tools alone. This wrapper
/// stores the value in a `@StateObject` box instead, which needs no plugin.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    final class Box: ObservableObject {
        @Published var value: Value
        init(_ value: Value) { self.value = value }
    }

    @StateObject private var box: Box

    init(wrappedValue: Value) {
        _box = StateObject(wrappedValue: Box(wrappedValue))
    }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> { $box.value }
}
