//
//  Observable.swift
//  KinUtil
//
//  Created by Kin Foundation.
//  Copyright © 2018 Kin Foundation. All rights reserved.
//

import Foundation
import Dispatch

public protocol Unlinkable {
    func unlink()
}

private protocol UnlinkableObserver: Unlinkable {
    var observerCount: Int { get }
    var parent: UnlinkableObserver? { get }
    func add(to linkBag: LinkBag)
}

public final class LinkBag {
    private var links = [Unlinkable]()

    public func add(_ unlinkable: Unlinkable) {
        links.append(unlinkable)
    }

    public init() {

    }
    
    deinit {
        links.forEach { $0.unlink() }
    }
}

private struct Observer<Value> {
    private var nextHandler: ((Value) -> Void)?
    private var errorHandler: ((Error) -> Void)?
    private var finishHandler: (() -> Void)?
    private var queue: DispatchQueue?

    func next(_ value: Value) {
        enqueue { self.nextHandler?(value) }
    }

    func error(_ error: Error) {
        enqueue { self.errorHandler?(error) }
    }

    func finish() {
        enqueue { self.finishHandler?() }
    }

    private func enqueue(_ block: @escaping () -> Void) {
        if let queue = queue {
            queue.async(execute: block)
        }
        else {
            block()
        }
    }

    init(next: ((Value) -> Void)? = nil,
         error: ((Error) -> Void)? = nil,
         finish: (() -> Void)? = nil,
         queue: DispatchQueue?) {
        self.nextHandler = next
        self.errorHandler = error
        self.finishHandler = finish
        self.queue = queue
    }
}

public final class PausableObserver<Value>: Observable<Value> {
    private let limit: Int
    private var buffer = [Value]()

    public var paused = false {
        didSet {
            if !paused && oldValue != paused {
                buffer.forEach { super.next($0) }
                buffer.removeAll()
            }
        }
    }

    public init(limit: Int) {
        self.limit = limit
    }

    private func add(_ value: Value) {
        buffer.append(value)

        while buffer.count > limit {
            buffer.remove(at: 0)
        }
    }

    override public func next(_ value: Value) {
        if paused {
            add(value)
        }
        else {
            super.next(value)
        }
    }
}

public final class StatefulObserver<Value>: Observable<Value> {
    public private(set) var value: Value?

    override public func next(_ value: Value) {
        self.value = value

        super.next(value)
    }
}

/**
 An `Observable` is an object which emits events (values) to its observers.  The one who creates the
 observable issues calls to `next(_:)` to emit new values.  Values submitted are not emitted until
 the first observer registers.  Subsequent observers will only see new events.
 ---
 ## Observing
 An interested party begins observing by calling `on(_, next:)`.  This method returns an observable
 which emits the same value received by the next-event handler.  This allows chaining observables.

 ## Operators
 `Observable`s have several operators, which filter or transform the received value,
 as dictated by the operator.  The operator methods return an observable, to allow operators to be chained.

 ## Memory management
 `Observable`s only keep a strong reference to the `Observable` instance they
 are observing.  It is thus necessary to keep a strong reference to the last link in an observation chain.
 */
public class Observable<Value>: UnlinkableObserver {
    private enum State {
        case open
        case complete
        case error
    }

    private var observers = [Observer<Value>]()
    private var buffer = [Value]()
    private var state = State.open
    fileprivate var parent: UnlinkableObserver?

    fileprivate var observerCount: Int {
        return observers.count
    }

    /**
     Register a handler to be called when a new value is to be emitted.

     - parameter queue: The `DispatchQueue` on which to execute the handler.  If not specified, the handler is called, synchronously, on the same queue as the caller.
     - parameter next: The handler which receives the emitted value.
     */
    public func on(queue: DispatchQueue? = nil, next: @escaping (Value) -> Void) -> Observable<Value> {
        observers.append(Observer(next: next, queue: queue))

        if buffer.count > 0 {
            buffer.forEach { value in
                observers.forEach { $0.next(value) }
            }
            buffer.removeAll()
        }

        return self
    }

    public func on(queue: DispatchQueue? = nil, error: @escaping (Error) -> Void) -> Observable<Value> {
        observers.append(Observer(error: error, queue: queue))

        return self
    }

    public func on(queue: DispatchQueue? = nil, finish: @escaping () -> Void) -> Observable<Value> {
        observers.append(Observer(finish: finish, queue: queue))

        return self
    }

    /**
     Emit a new value to observers.  If no observers are registered, the value is buffered.

     - parameter value: The value to emit.
     */
    public func next(_ value: Value) {
        guard state == .open else {
            return
        }

        if observers.count > 0 {
            observers.forEach { $0.next(value) }
        }
        else {
            buffer.append(value)
        }
    }

    public func error(_ error: Error) {
        guard state == .open else {
            return
        }

        state = .error

        observers.forEach { $0.error(error) }
    }

    public func finish() {
        guard state == .open else {
            return
        }

        state = .complete

        observers.forEach { $0.finish() }
    }

    public init(_ value: Value? = nil) {
        if let value = value {
            next(value)
        }
    }
}

//MARK: - UnlinkableObserver -

extension Observable {
    public func unlink() {
        if parent?.observerCount ?? 0 < 2 {
            parent?.unlink()
        }

        parent = nil
    }

    public func add(to linkBag: LinkBag) {
        linkBag.add(self)
    }
}

//MARK: - Operators -

extension Observable {
    /**
     The `accumulate` operator gathers received values into a buffer, and emits the buffer as a single value.

     - parameter limit: The number of values accumulated is limited to this value.  When the limit is reached,
     the oldest values are discarded as new values are received.
     */
    public func accumulate(limit: Int) -> Observable<[Value]> {
        var buffer = [Value]()

        let observable = Observable<[Value]>()
        observable.parent = on(next: { (value) in
            buffer.append(value)

            while buffer.count > limit {
                buffer.remove(at: 0)
            }

            observable.next(buffer)
        })

        return observable
    }

    /**
     The `combine` operator observes both the receiver and an other observable.  When either emits a
     new value, the `Observable` returned by `combine` emits both values as a tuple.

     - parameter other: The observable whose emitted values will be combined with the receiver's.
     */
    public func combine<OtherValue>(with other: Observable<OtherValue>) -> Observable<(Value?, OtherValue?)> {
        let observable = Observable<(Value?, OtherValue?)>()

        var myLatest: Value?
        var otherLatest: OtherValue?

        let observer = on(next: { value in
            myLatest = value

            observable.next((myLatest, otherLatest))
        })

        let otherObserver = other.on(next: { value in
            otherLatest = value

            observable.next((myLatest, otherLatest))
        })

        otherObserver.parent = observer
        observable.parent = otherObserver

        return observable
    }

    public func debug(_ identifier: String? = nil) -> Observable<Value> {
        let observable = Observable<Value>()
        observable.parent =
            on(next: { (value) -> Void in
                print("\(identifier ?? "Observable"): DEBUG: \(value)")

                observable.next(value)
            })

        return observable
    }

    /**
     The `filter` operator filters observed values, and only emits the value to its observers when
     the filter returns `true`.

     - parameter handler: The closure whose return value determines if the value will be emitted.
     */
    public func filter(_ handler: @escaping (Value) -> Bool) -> Observable<Value> {
        let observable = Observable<Value>()
        observable.parent =
            on(next: { value in
                if handler(value) {
                    observable.next(value)
                }
            })

        return observable
    }

    /**
     The `flatMap` operator transforms the received value into a value of a different type.  Observers
     will receive the transformed value.  Only values which are not `nil` are emitted.

     - parameter handler: The closure whose return value is emitted to observers.
     */
    public func flatMap<NewValue>(_ handler: @escaping (Value) -> NewValue?) -> Observable<NewValue> {
        let observable = Observable<NewValue>()
        observable.parent =
            on(next: { value in
                guard let value = handler(value) else {
                    return
                }

                observable.next(value)
            })

        return observable
    }

    /**
     The `map` operator transforms the received value into a value of a different type.  Observers
     will receive the transformed value.

     - parameter handler: The closure whose return value is emitted to observers.
     */
    public func map<NewValue>(_ handler: @escaping (Value) -> NewValue) -> Observable<NewValue> {
        let observable = Observable<NewValue>()
        observable.parent =
            on(next: { value in
                observable.next(handler(value))
            })

        return observable
    }

    /**
     The `stateful` operator returns an `Observable` which maintains its last value.  The value is
     available via the `value` property of the returned `Observable`.

     - returns: An `Observable` which will retain the value of its parent.
     */
    public func stateful() -> StatefulObserver<Value> {
        let observable = StatefulObserver<Value>()
        observable.parent =
            on(next: { value in
                observable.next(value)
            })

        return observable
    }

    public func pausable(limit: Int) -> PausableObserver<Value> {
        let observer = PausableObserver<Value>(limit: limit)
        observer.parent = self.on(next: { observer.next($0) })

        return observer
    }
}
