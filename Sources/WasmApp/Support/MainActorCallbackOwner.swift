/// Re-establishes main-actor isolation for framework callbacks that are
/// declared nonisolated but are synchronously invoked by the main-actor render loop.
/// `assumeIsolated` validates that invariant at runtime. The integer address keeps
/// Swift 6.3 from treating the callback owner as transferred across isolation domains.
nonisolated func withMainActorCallbackOwner<Owner: AnyObject>(
    _ owner: Owner,
    _ body: @MainActor (Owner) -> Void
) {
    let address = UInt(bitPattern: Unmanaged.passUnretained(owner).toOpaque())
    MainActor.assumeIsolated {
        guard let pointer = UnsafeRawPointer(bitPattern: address) else {
            preconditionFailure("Framework callback owner address is invalid")
        }
        body(Unmanaged<Owner>.fromOpaque(pointer).takeUnretainedValue())
    }
}
