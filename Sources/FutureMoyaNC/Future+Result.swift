import Foundation
#if !COCOAPODS
import MoyaNC
#endif

public typealias FutureResult<Value> = Future<Result<Value>>

extension Future {
    @inlinable
    public func mapSuccess<Success, NewSuccess>(_ transform: @escaping (Success) -> NewSuccess) -> FutureResult<NewSuccess>
        where Response == Result<Success> {
            return map { $0.map(transform) }
    }

    @inlinable
    public func mapError<Success>(_ transform: @escaping (Error) -> Error) -> FutureResult<Success>
        where Response == Result<Success> {
            return map { $0.mapError(transform) }
    }

    @inlinable
    public func flatMapSuccess<Success, NewSuccess>(_ transform: @escaping (Success) -> FutureResult<NewSuccess>?) -> FutureResult<NewSuccess>
        where Response == Result<Success>{
            return flatMap { result in
                FutureResult<NewSuccess> { callback in
                    switch result {
                    case let .success(s):
                        if let transform = transform(s) {
                            transform.run { callback($0) }
                        } else {
                            let error = NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "FutureResult cannot be flatMap to nil"])
                            callback(.failure(error))
                        }
                    case let .failure(error):
                        callback(.failure(error))
                    }
                }
            }
    }

    @inlinable
    public func flatMapError<Success>(_ transform: @escaping (Error) -> FutureResult<Success>?) -> FutureResult<Success>
        where Response == Result<Success> {
            return flatMap { result in
                FutureResult<Success> { callback in
                    switch result {
                    case let .success(s):
                        callback(.success(s))
                    case let .failure(error):
                        if let transform = transform(error) {
                            transform.run { callback($0) }
                        } else {
                            callback(.failure(error))
                        }
                    }
                }
            }
    }

    @inlinable
    public func observeSuccess<Success>(_ callback: @escaping (Success) -> Void) -> Future
        where Response == Result<Success> {
            return mapSuccess {
                callback($0)
                return $0
            }
    }

    @inlinable
    public func observeError<Success>(_ callback: @escaping (Error) -> Void) -> Future
        where Response == Result<Success> {
            return mapError {
                callback($0)
                return $0
            }
    }

    @inlinable
    public func parallel<Success, NewResponse, FinalResponse>(_ fA: FutureResult<NewResponse>,
                                                              completesOn completionQueue: DispatchQueue = .main,
                                                              combine: @escaping (Success, NewResponse) -> FinalResponse)
        -> FutureResult<FinalResponse> where Response == Result<Success> {
            return createParallelWith(self, fA, completesOn: completionQueue) {
                (result: Result<Success>, newResult: Result<NewResponse>) -> Result<FinalResponse> in
                switch (result, newResult) {
                case let (.success(info), .success(newInfo)): return .success(combine(info, newInfo))
                case let (.success, .failure(error)): return .failure(error)
                case let (.failure(error), .success): return .failure(error)
                case let (.failure(error), .failure): return .failure(error)
                }
            }
    }

    @inlinable
    public func parallel<Success, NewResponse>(_ a: FutureResult<NewResponse>, completesOn completionQueue: DispatchQueue = .main)
        -> FutureResult<(Success, NewResponse)>  where Response == Result<Success> {
            return createParallelWith(self, a, completesOn: completionQueue) {
                (result: Result<Success>, newResult: Result<NewResponse>) -> Result<(Success, NewResponse)> in
                switch (result, newResult) {
                case let (.success(info), .success(newInfo)): return .success((info, newInfo))
                case let (.success, .failure(error)): return .failure(error)
                case let (.failure(error), .success): return .failure(error)
                case let (.failure(error), .failure): return .failure(error)
                }
            }
    }
}
